# Wi-Fi on iwd (network-hardware.nix), on simulated radios (mac80211_hwsim): phy0 is the access
# point (hostapd in netns "ap", WPA2-PSK), NetworkManager uses the other. The profile is a keyfile
# with the PSK in it, as an install writes it.
#   - It connects at boot, and iwd keeps the passphrase.
#   - After a restart of iwd and NetworkManager it connects again, with the last-use time known.
{ pkgs, ... }:
pkgs.testers.runNixOSTest {
  name = "hinteros-wifi-iwd";
  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ ../../nixos/modules/network-hardware.nix ];
      boot.kernelModules = [ "mac80211_hwsim" ];
      boot.extraModprobeConfig = "options mac80211_hwsim radios=2";
      networking.networkmanager = {
        enable = true;
        unmanaged = [ "interface-name:eth*" ];
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

    with subtest("iwd: connects, and keeps the passphrase"):
        connected()
        machine.succeed("systemctl is-active iwd.service")
        machine.fail("systemctl is-active wpa_supplicant.service")
        machine.succeed("test -e /var/lib/iwd/testnet.psk")
        machine.fail("journalctl -u NetworkManager | grep -q 'No agents were available'")
        machine.wait_until_succeeds("grep -q 4616e7c8-fdb6-4c51-b112-763f816c11b8 /var/lib/NetworkManager/timestamps")

    with subtest("a restart connects, with the last use recorded"):
        machine.succeed("systemctl restart iwd.service NetworkManager.service")
        connected()
        machine.fail("journalctl -u NetworkManager | grep -q 'No agents were available'")
  '';
}
