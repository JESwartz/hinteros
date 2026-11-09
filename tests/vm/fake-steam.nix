# Fake Steam under the cage session: the stub `steam` records a steam://rungameid launch in
# its log and opens a visible "Fake game <id>" window that OCR can see. Daemon and launcher
# tests use this in place of the real (unfree) Steam.
{ self, pkgs }:
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-fake-steam";
  enableOCR = true;

  nodes.machine = {
    imports = [
      self.nixosModules.session
      self.nixosModules.daemon
      self.nixosModules.fake-steam
      ../../nixos/vm
    ];
    hinteros.fakeSteam.enable = true;
  };

  testScript = ''
    import time

    machine.wait_for_unit("multi-user.target")
    machine.wait_until_succeeds("pgrep -u hinteros-p1 -f '/bin/cage '")
    machine.wait_until_succeeds("pgrep -u hinteros-p1 -f hinteros-launcher")

    # Fake Steam home (3 games, 3 tools) installed for the session user.
    machine.wait_until_succeeds("ls ~hinteros-p1/.local/share/Steam/steamapps/appmanifest_*.acf | wc -l | grep -qx 6")
    machine.succeed("grep -q Fake ~hinteros-p1/.local/share/Steam/steamapps/appmanifest_1000002.acf")

    # Run the stub as the session user, inside the compositor's environment.
    pid = machine.succeed("pgrep -u hinteros-p1 -f 'hinteros-launcher$' | head -1").strip()
    machine.succeed(
        f"tr '\\0' '\\n' < /proc/{pid}/environ "
        "| grep -E '^(XDG_RUNTIME_DIR|WAYLAND_DISPLAY|DISPLAY)=' | sed 's/^/export /' > /tmp/session-env"
    )
    run = "runuser -u hinteros-p1 -- sh -c '. /tmp/session-env; steam %s'"
    machine.succeed(run % "-silent")
    machine.succeed(run % "steam://rungameid/1000002")

    uid = machine.succeed("id -u hinteros-p1").strip()
    steam_log = f"/run/user/{uid}/fake-steam.log"
    machine.succeed(f"grep -q 'argv: steam://rungameid/1000002' {steam_log}")
    machine.succeed(f"grep -q 'launch: 1000002' {steam_log}")
    machine.succeed(f"grep -q 'argv: -silent' {steam_log}")

    # The window comes from a process that may need a moment to map and be raised over the
    # launcher, and one OCR pass can miss text that is on screen. So: wait for the process, then
    # keep taking fresh screenshots (all OCR variants) until "Fake game" is read or the deadline
    # passes. The assertion is the same as before: the text must be on screen.
    machine.wait_until_succeeds("pgrep -u hinteros-p1 -f '/bin/xterm '", timeout=60)
    deadline = time.monotonic() + 240
    texts = []
    while True:
        machine.succeed("pgrep -u hinteros-p1 -f '/bin/xterm '")  # the window's process must stay up
        texts = machine.get_screen_text_variants()
        if any("fake game" in t.lower() for t in texts):
            break
        if time.monotonic() > deadline:
            print("SCREEN:", texts)
            print(machine.execute("pgrep -au hinteros-p1 | cut -c1-150; journalctl _SYSTEMD_USER_UNIT=hinteros-session.service --no-pager | tail -30")[1])
            raise Exception("no 'Fake game' window text on screen before the deadline")
        machine.sleep(3)
    machine.screenshot("fake-game")
  '';
}
