# Network hardware robustness, for devices and the installer ISO.
#
# Drivers: every NIC driver a mini PC is likely to have is in-tree and built as a module in the
# kernel (r8169 covers RTL8125/8126, igc, e1000e, igb, and the USB adapters r8152, ax88179_178a,
# cdc_ncm, cdc_ether), loaded by udev from the PCI/USB ids; their firmware (rtl_nic/*, intel)
# is in linux-firmware, which the redistributable firmware option installs. No out-of-tree
# drivers. The installer-ui test checks that they are there.
#
# Link flakiness: Energy Efficient Ethernet (EEE) is a known cause of links that never come up
# or drop on Realtek and Intel I225/I226 NICs, and Wi-Fi power saving drops packets on some
# cards. NetworkManager has no global default for EEE, only a per-profile `ethtool.eee-enabled`,
# so the wired profile below (it matches every Ethernet device, DHCP) turns it off; Wi-Fi power
# saving is off globally (NetworkManager and iwd).
{ config, lib, ... }:
{
  config = lib.mkMerge [
    { hardware.enableRedistributableFirmware = lib.mkDefault true; }

    (lib.mkIf config.networking.networkmanager.enable {
      # NetworkManager owns all networking. nixos-facter's networking module (nixpkgs
      # hardware/facter/networking) would otherwise set `networking.useDHCP = true` and
      # `networking.interfaces.<detected>.useDHCP = true`, which starts dhcpcd (and per-interface
      # network-link/network-addresses units) next to NetworkManager: two DHCP clients on one
      # interface. Its own switch, `hardware.facter.detected.dhcp.enable`, drops both; the
      # globals are forced off too, so nothing else can bring a second client back.
      hardware.facter.detected.dhcp.enable = lib.mkForce false;
      networking = {
        useDHCP = lib.mkForce false;
        dhcpcd.enable = lib.mkForce false;
      };

      # iwd, not wpa_supplicant, under NetworkManager: much less code (no Wi-Fi Direct, WPS or
      # the long tail of EAP methods). NetworkManager still owns the connections; iwd does not
      # set up IP. NetworkManager's wifi.powersave does not reach iwd, so iwd turns power saving
      # off itself, on every driver.
      networking.wireless.iwd.settings =
        lib.mkIf (config.networking.networkmanager.wifi.backend == "iwd")
          {
            DriverQuirks.PowerSaveDisable = "*";
          };
      # NetworkManager starts the connections, not iwd. With iwd's autoconnect (the default)
      # NetworkManager never connects by itself, and it copies a profile to iwd only when the
      # profile is new or changed: a box updated from wpa_supplicant kept its Wi-Fi profile but
      # never connected (seen on the dev box). This also keeps autoconnect-priority working.
      networking.networkmanager.settings.device."wifi.iwd.autoconnect" = lib.mkIf (
        config.networking.networkmanager.wifi.backend == "iwd"
      ) false;

      # Once, on the first start with iwd: NetworkManager forgets when each profile last
      # connected. For a profile that connected before (under wpa_supplicant) NetworkManager
      # takes iwd's request for the passphrase as "the stored one is wrong" and asks a secret
      # agent for a new one; there is none, so the box never connects (dev box, and the
      # wifi-iwd-migration test). Without the time it sends the stored passphrase; iwd keeps it
      # (/var/lib/iwd) and asks no more. The times only order autoconnect between profiles.
      systemd.services.hinteros-nm-iwd-migrate =
        lib.mkIf (config.networking.networkmanager.wifi.backend == "iwd")
          {
            description = "HinterOS: prepare NetworkManager's state for iwd (once)";
            wantedBy = [ "NetworkManager.service" ];
            before = [ "NetworkManager.service" ];
            unitConfig.ConditionPathExists = "!/var/lib/NetworkManager/hinteros-iwd-migrated";
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = ''
              mkdir -p /var/lib/NetworkManager
              rm -f /var/lib/NetworkManager/timestamps
              touch /var/lib/NetworkManager/hinteros-iwd-migrated
            '';
          };

      networking.networkmanager = {
        wifi.backend = lib.mkDefault "iwd";
        wifi.powersave = lib.mkDefault false;
        ensureProfiles.profiles.hinteros-wired = {
          connection = {
            id = "Wired";
            type = "ethernet";
            autoconnect = "true";
            autoconnect-priority = "-10";
          };
          # EEE off (see above). 0 = false in NetworkManager's ternary keyfile values.
          ethtool.eee-enabled = "0";
          ipv4.method = "auto";
          ipv6.method = "auto";
        };
      };
    })
  ];
}
