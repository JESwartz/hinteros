# Wi-Fi after the update from wpa_supplicant to iwd (network-hardware.nix), on simulated radios
# (mac80211_hwsim): phy0 is the access point (hostapd in netns "ap", WPA2-PSK), NetworkManager
# uses the other. The profile is a keyfile with the PSK in it, as the boxes have it.
#   - Boot on wpa_supplicant: it connects, so NetworkManager records the profile's last use.
#   - Switch at runtime to iwd (as an update does): it connects again. Without
#     hinteros-nm-iwd-migrate NetworkManager asks a secret agent for a new passphrase (there is
#     none) and never connects.
#   - iwd keeps the passphrase; after a restart of iwd and NetworkManager it connects without
#     the migration (which ran once: its marker is there and the last-use times come back).
{ pkgs, ... }:
pkgs.testers.runNixOSTest {
  name = "hinteros-wifi-iwd-migration";
  nodes.machine =
    { lib, pkgs, ... }:
    {
      imports = [ ../../nixos/modules/network-hardware.nix ];
      boot.kernelModules = [ "mac80211_hwsim" ];
      boot.extraModprobeConfig = "options mac80211_hwsim radios=2";
      networking.networkmanager = {
        enable = true;
        # The box before the update. qemu-vm.nix turns Wi-Fi off (mkVMOverride); NetworkManager's
        # wpa_supplicant needs it.
        wifi.backend = lib.mkForce "wpa_supplicant";
        unmanaged = [ "interface-name:eth*" ];
      };
      networking.wireless.enable = lib.mkOverride 1 true;
      # After the update: the module's default (iwd).
      specialisation.iwd.configuration = {
        networking.networkmanager.wifi.backend = lib.mkOverride 40 "iwd";
        networking.wireless.enable = lib.mkOverride 0 false;
      };

      # The access point's radio leaves the root namespace before NetworkManager starts.
      systemd.services.ap-netns = {
        wantedBy = [ "multi-user.target" ];
        before = [
          "NetworkManager.service"
          "iwd.service"
        ];
        after = [ "systemd-modules-load.service" ];
        path = [
          pkgs.iproute2
          pkgs.iw
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ip netns add ap
          iw phy phy0 set netns name ap
        '';
      };
      systemd.services.hostapd-ap = {
        wantedBy = [ "multi-user.target" ];
        requires = [ "ap-netns.service" ];
        after = [ "ap-netns.service" ];
        path = [
          pkgs.iproute2
          pkgs.hostapd
        ];
        script = ''
          ip netns exec ap ip link set wlan0 up
          ip netns exec ap ip addr add 192.168.77.1/24 dev wlan0
          exec ip netns exec ap hostapd ${pkgs.writeText "hostapd.conf" ''
            interface=wlan0
            driver=nl80211
            ssid=testnet
            hw_mode=g
            channel=6
            wpa=2
            wpa_passphrase=correcthorse
            wpa_key_mgmt=WPA-PSK
            rsn_pairwise=CCMP
          ''}
        '';
      };

      environment.etc."NetworkManager/system-connections/testnet.nmconnection" = {
        mode = "0600";
        text = ''
          [connection]
          id=testnet
          uuid=4616e7c8-fdb6-4c51-b112-763f816c11b8
          type=wifi

          [wifi]
          mode=infrastructure
          ssid=testnet

          [wifi-security]
          key-mgmt=wpa-psk
          psk=correcthorse

          [ipv4]
          method=manual
          address1=192.168.77.2/24

          [ipv6]
          method=disabled
        '';
      };
    };

  testScript = ''
    def connected():
        machine.wait_until_succeeds(
            "ping -c1 -W1 192.168.77.1 && nmcli -t -f DEVICE,STATE device | grep -q '^wlan.*:connected$'",
            timeout=90,
        )

    machine.wait_for_unit("hostapd-ap.service")
    machine.wait_for_unit("NetworkManager.service")

    with subtest("wpa_supplicant: connects, and NetworkManager records the last use"):
        connected()
        machine.succeed("systemctl is-active wpa_supplicant.service")
        machine.wait_until_succeeds("grep -q 4616e7c8-fdb6-4c51-b112-763f816c11b8 /var/lib/NetworkManager/timestamps")

    with subtest("the update to iwd at runtime: it connects again"):
        machine.succeed("/run/booted-system/specialisation/iwd/bin/switch-to-configuration test")
        machine.succeed("systemctl is-active iwd.service")
        machine.fail("systemctl is-active wpa_supplicant.service")
        connected()
        machine.succeed("test -e /var/lib/NetworkManager/hinteros-iwd-migrated")
        machine.succeed("test -e /var/lib/iwd/testnet.psk")
        machine.fail("journalctl -u NetworkManager | grep -q 'No agents were available'")

    with subtest("iwd keeps the passphrase: a restart connects, the migration ran once"):
        machine.succeed("systemctl restart iwd.service NetworkManager.service")
        connected()
        machine.wait_until_succeeds("grep -q 4616e7c8-fdb6-4c51-b112-763f816c11b8 /var/lib/NetworkManager/timestamps")
        machine.succeed("systemctl stop hinteros-nm-iwd-migrate.service NetworkManager.service")
        machine.succeed("systemctl start NetworkManager.service")
        connected()
        runs = machine.succeed("journalctl -u hinteros-nm-iwd-migrate.service -o cat | grep -c '^Starting HinterOS: prepare' || true").strip()
        assert runs == "1", runs
  '';
}
