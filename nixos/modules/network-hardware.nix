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
# saving is off globally.
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

      networking.networkmanager = {
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
