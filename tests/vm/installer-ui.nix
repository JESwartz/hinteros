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

    installer.wait_for_text("HinterOS", timeout=timedelta(seconds=180))
    installer.screenshot("installer-welcome")
    screen = installer.get_screen_text().lower()
    assert "welcome" in screen or "install" in screen, screen

    # The UI exits: the console (getty) takes tty1 back.
    installer.succeed("pkill -u root -f 'hinteros-launcher.*--installer'")
    installer.wait_for_unit("getty@tty1.service")
  '';
}
