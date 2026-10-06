# Boots the HinterOS test system and checks that the console session is up.
# The test pkgs are read-only, so the overlay is applied to them here rather than
# through the overlay module.
{ self, pkgs }:
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-boot";
  enableOCR = true;

  nodes.machine = {
    imports = [
      self.nixosModules.session
      ../../nixos/vm
    ];
  };

  testScript = ''
    from datetime import timedelta

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("greetd.service")

    # Autologin: a login session for the session user exists.
    machine.wait_until_succeeds("loginctl list-sessions --no-legend | grep -w hinteros")

    # The compositor (cage in the VM, see nixos/vm/default.nix) runs as that user
    # and the home app (an xterm, via Xwayland) is up inside it.
    machine.wait_until_succeeds("pgrep -u hinteros -f '/bin/cage '")
    machine.wait_until_succeeds("pgrep -u hinteros -f '/bin/xterm '")

    # Still up a few seconds later, i.e. not crash-looping.
    machine.sleep(duration=timedelta(seconds=5))
    machine.succeed("pgrep -u hinteros -f '/bin/cage '")
    machine.succeed("pgrep -u hinteros -f '/bin/xterm '")

    # Screenshot: informational only until spike 2 decides the policy.
    machine.screenshot("session")
    try:
        text = machine.get_screen_text()
        print("OCR text:", repr(text))
        print("OCR found 'placeholder':", "placeholder" in text.lower())
    except Exception as e:
        print("OCR unavailable:", e)
  '';
}
