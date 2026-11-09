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
    installer.succeed("command -v hinteros-save-log hinteros-diagnose lspci lsusb ethtool iw lshw nixos-facter")
    motd = installer.succeed("cat $(grep -o '/nix/store/[^ ]*-motd' /etc/pam.d/login | head -1)")
    for want in ["Ctrl+Alt+F2", "Ctrl+Alt+F1", "back", "hinteros-diagnose", "hinteros-save-log", "tty1"]:
        assert want in motd, (want, motd)
    for stale in ["empty passwords", "No installer screen is running yet", "set a password"]:
        assert stale not in motd, (stale, motd)
    installer.fail("grep -q 'empty passwords' /etc/issue")
    # sshd is off (the ISO's installation-device profile turns it on, the installer module turns
    # it off again; tests/eval/installer-iso.nix checks the real ISO configuration).
    installer.fail("systemctl is-active sshd.service")
    # The NIC drivers a mini PC is likely to have, and the filesystems of a log stick, exist.
    for drv in ["r8169", "igc", "e1000e", "igb", "r8152", "ax88179_178a", "cdc_ncm", "cdc_ether", "exfat", "ntfs3", "vfat"]:
        installer.succeed(f"modinfo {drv}")
    # The wired profile turns EEE off; Wi-Fi power saving is off.
    installer.succeed("grep -rq 'eee-enabled=0' /etc/NetworkManager/system-connections/ /run/NetworkManager/system-connections/")
    installer.succeed("grep -q 'wifi.powersave=2' /etc/NetworkManager/NetworkManager.conf")
    # The report runs and fits two screens.
    report = installer.succeed("hinteros-diagnose")
    for want in ["== Links", "== NetworkManager ==", "== Wi-Fi and rfkill ==", "PCI network devices"]:
        assert want in report, (want, report)
    assert len(report.splitlines()) < 110, len(report.splitlines())
    # No visible pointer in the UI session: cage runs with the blank cursor theme.
    installer.succeed("tr '\\0' '\\n' < /proc/$(pgrep -u root -f 'hinteros-launcher.*--installer' | head -1)/environ | grep -qx XCURSOR_THEME=hinteros-blank")

    installer.wait_for_text("HinterOS", timeout=timedelta(seconds=180))
    installer.screenshot("installer-welcome")
    screen = installer.get_screen_text().lower()
    assert "welcome" in screen or "install" in screen, screen

    # Keyboard input reaches the app (cage -> the launcher): Enter on Welcome goes to the next
    # step, Tab + Enter activates the next button. (The launcher's own key map is its repo's.) The
    # VM's disk holds no install, so the admin account comes after the internet.
    installer.send_key("ret")
    installer.wait_for_text("Internet", timeout=timedelta(seconds=60))
    installer.send_key("tab")
    installer.send_key("ret")
    installer.wait_for_text("Admin account", timeout=timedelta(seconds=60))

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
    installer.wait_for_text("Admin account", timeout=timedelta(seconds=60))

    # `back` (and its alias `installer`) from the tty2 console returns to the UI; the console shows
    # the reminder above its prompt.
    installer.send_key("ctrl-alt-f2")
    installer.wait_until_succeeds("grep -qx tty2 /sys/class/tty/tty0/active", timeout=30)
    installer.sleep(3)
    installer.succeed("grep -rq 'return to the installer' /etc/bashrc /etc/profile /etc/set-environment")
    installer.send_chars("echo reminder-check\n")
    installer.sleep(3)
    installer.wait_for_text("return to the installer", timeout=timedelta(seconds=30))
    installer.send_chars("back\n")
    installer.wait_until_succeeds("grep -qx tty1 /sys/class/tty/tty0/active", timeout=30)
    installer.wait_for_text("Admin account", timeout=timedelta(seconds=60))
    installer.succeed("command -v back installer")

    # The UI exits: the console (getty) takes tty1 back.
    installer.succeed("pkill -u root -f 'hinteros-launcher.*--installer'")
    installer.wait_for_unit("getty@tty1.service")

    # With the UI gone, `back` starts it again and brings tty1 to the front.
    installer.send_key("ctrl-alt-f2")
    installer.wait_until_succeeds("grep -qx tty2 /sys/class/tty/tty0/active", timeout=30)
    installer.sleep(3)
    installer.send_chars("installer\n")
    installer.wait_until_succeeds("pgrep -u root -f 'hinteros-launcher.*--installer'", timeout=120)
    installer.wait_until_succeeds("grep -qx tty1 /sys/class/tty/tty0/active", timeout=60)
    installer.wait_for_text("HinterOS", timeout=timedelta(seconds=180))
    installer.screenshot("installer-after-back")
  '';
}
