# The ISO's installer UI: the installer environment with `hinteros.installer.ui.command` set
# (what iso.nix sets) boots into the launcher in installer mode under cage on tty1, as root, and
# shows the welcome screen (OCR). It reads the real catalog index from the system profile and
# starts nothing else; when the UI exits, tty1 is the console again.
{ self, pkgs }:
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-installer-ui";
  enableOCR = true;

  nodes.installer =
    { lib, pkgs, ... }:
    {
      imports = [ (import ./install/installer-node.nix { inherit self pkgs; }) ];
      hinteros.installer.ui.command = [
        (lib.getExe' pkgs.hinteros-launcher "hinteros-launcher")
        "--installer"
      ];
      # No GPU in the VM: software rendering, like the other cage tests.
      services.cage.environment = {
        WLR_RENDERER = "pixman";
        WLR_NO_HARDWARE_CURSORS = "1";
        LIBGL_ALWAYS_SOFTWARE = "1";
        GALLIUM_DRIVER = "llvmpipe";
      };
      virtualisation.memorySize = lib.mkForce 4096;
    };

  testScript = ''
    from datetime import timedelta

    installer.start()
    installer.wait_for_unit("multi-user.target")
    installer.wait_for_unit("cage-tty1.service")
    installer.wait_until_succeeds("pgrep -u root -f 'hinteros-launcher.*--installer'", timeout=120)
    # The Store index and the vendor terms the installer reads.
    installer.succeed("test -s /run/current-system/sw/share/hinteros/catalog.json")
    installer.succeed("ls /run/current-system/sw/share/hinteros/terms | grep -q steam")
    installer.succeed("command -v hinteros-install lsblk nmcli")
    # Wired DHCP without any UI action: a profile for every Ethernet device, no second DHCP client.
    installer.succeed("nmcli -t -f NAME,TYPE connection show | grep -qx 'Wired:802-3-ethernet'")
    installer.fail("systemctl is-active dhcpcd.service")
    # Firmware is on the installer (NICs, Wi-Fi), and a root console is offered on tty2.
    installer.succeed("ls /run/current-system/firmware | grep -q rtl_nic")
    installer.succeed("systemctl cat getty@tty2.service | grep -q -- '--autologin root'")
    installer.succeed("grep -q 'Ctrl+Alt+F2' $(grep -o '/nix/store/[^ ]*-motd' /etc/pam.d/login | head -1) && command -v hinteros-save-log")

    installer.wait_for_text("HinterOS", timeout=timedelta(seconds=180))
    installer.screenshot("installer-welcome")
    screen = installer.get_screen_text().lower()
    assert "welcome" in screen or "install" in screen, screen

    # Keyboard input reaches the app (cage -> the launcher): Enter on Welcome goes to the next
    # step, Tab + Enter activates the next button. (The launcher's own key map is its repo's.)
    installer.send_key("ret")
    installer.wait_for_text("Internet", timeout=timedelta(seconds=60))
    installer.send_key("tab")
    installer.send_key("ret")
    installer.wait_for_text("Choose the disk", timeout=timedelta(seconds=60))

    # VT switching works while cage runs on tty1 (cage has a logind session on seat0): Ctrl+Alt+F2
    # gives the root console, which takes keystrokes; Ctrl+Alt+F1 brings the UI back.
    installer.send_key("ctrl-alt-f2")
    installer.wait_until_succeeds("grep -qx tty2 /sys/class/tty/tty0/active", timeout=30)
    installer.wait_for_unit("getty@tty2.service")
    installer.sleep(3)
    installer.send_chars("echo from-tty2 > /tmp/tty2-proof; id -un > /tmp/tty2-user\n")
    installer.wait_until_succeeds("grep -q from-tty2 /tmp/tty2-proof", timeout=30)
    assert installer.succeed("cat /tmp/tty2-user").strip() == "root"
    installer.send_key("ctrl-alt-f1")
    installer.wait_until_succeeds("grep -qx tty1 /sys/class/tty/tty0/active", timeout=30)
    installer.wait_for_text("Choose the disk", timeout=timedelta(seconds=60))

    # The UI exits: the console (getty) takes tty1 back.
    installer.succeed("pkill -u root -f 'hinteros-launcher.*--installer'")
    installer.wait_for_unit("getty@tty1.service")
  '';
}
