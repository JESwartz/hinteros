# Controller input and the app sandbox (design/sandbox.md, step 4): while HinterOS UI is in front
# (a PIN, a password), no sandboxed app may read the controller. An app with the `gamepad`
# permission gets /dev/input; there it can open InputPlumber's virtual pads (uaccess), and the
# physical pads are grabbed and hidden by InputPlumber. The session daemon puts every pad in
# InputPlumber's ALL mode while the launcher has focus: the events go only to the daemon (D-Bus),
# never to the virtual pad. With an app in front (PASS) the virtual pad gets them.
#
# A reader app (gamepad = required) logs every event it can read from /dev/input from inside its
# sandbox. Fake pads (tests/vm/input-layer/fakepad.py, uinput, Xbox 360 id) are pressed with the
# app in front (it reads them), after Guide (Home: it reads nothing, the launcher gets input_nav),
# with a pad plugged in while the launcher is in front, and with the app in front again.
{ self, pkgs }:
let
  # Inside the sandbox: opens every /dev/input/event* it may read (tries again every 0.2 s: new
  # pads, ACLs set late) and logs "open <name>" and "EVENT <name> | <code> <value>" to $HOME/events.txt.
  reader =
    pkgs.writers.writePython3Bin "hinteros-pad-reader"
      {
        libraries = [ pkgs.python3Packages.evdev ];
        flakeIgnore = [ "E501" ];
      }
      ''
        import glob
        import os
        import select

        import evdev
        from evdev import ecodes as e

        out = open(os.path.join(os.environ["HOME"], "events.txt"), "a", buffering=1)
        devs = {}


        def scan():
            for path in glob.glob("/dev/input/event*"):
                if devs.get(path) is not None:
                    continue
                try:
                    d = evdev.InputDevice(path)
                except OSError:
                    continue
                devs[path] = d
                out.write(f"open {d.name}\n")


        def name(t, c):
            n = e.bytype[t].get(c, c)
            return n[-1] if isinstance(n, (list, tuple)) else n


        while True:
            scan()
            live = [d for d in devs.values() if d is not None]
            r, _, _ = select.select(live, [], [], 0.2)
            for d in r:
                try:
                    for ev in d.read():
                        if ev.type in (e.EV_KEY, e.EV_ABS):
                            out.write(f"EVENT {d.name} | {name(ev.type, ev.code)} {ev.value}\n")
                except OSError:
                    devs[d.path] = None
      '';
in
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-sandbox-pad";

  nodes.machine = _: {
    imports = [
      self.nixosModules.session
      self.nixosModules.daemon
      self.nixosModules.apps
      self.nixosModules.input
      ../../nixos/vm
    ];

    hinteros.apps = {
      jellyfin.enable = false;
      youtube.enable = false;
      firefox.enable = false;
      padreader = {
        enable = true;
        name = "Pad reader";
        package = reader;
        permissions.gamepad = "required";
      };
    };

    environment = {
      systemPackages = [
        (pkgs.python3.withPackages (p: [ p.evdev ]))
        pkgs.socat
      ];
      etc."fakepad.py".source = ./input-layer/fakepad.py;
    };
  };

  testScript = ''
    import json
    import shlex
    import time

    IP = "org.shadowblip.InputPlumber"
    CDI = "org.shadowblip.Input.CompositeDevice"

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("inputplumber.service")
    machine.wait_for_unit("hinteros-session.service", "hinteros")
    uid = machine.succeed("id -u hinteros").strip()
    sock = f"/run/user/{uid}/hinteros/session.sock"
    machine.wait_until_succeeds(f"test -S {sock}")
    events = "/home/hinteros/.local/share/hinteros/sandbox/padreader/events.txt"

    def hello():
        return {"jsonrpc": "2.0", "id": 0, "method": "hello",
                "params": {"api_version": "0.18", "client": {"name": "pad-test", "version": "0"}}}

    def ok(method, params=None):
        msgs = [hello(), {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}]
        payload = "".join(json.dumps(m) + "\n" for m in msgs)
        cmd = f"(printf %s {shlex.quote(payload)}; sleep 2) | socat -t2 - UNIX-CONNECT:{sock}"
        out = machine.succeed(f"runuser -u hinteros -- sh -c {shlex.quote(cmd)}")
        reply = next(json.loads(l) for l in out.splitlines() if l.strip() and json.loads(l).get("id") == 1)
        assert "error" not in reply, reply
        return reply["result"]

    def plug(n):
        """Fake pad n (FIFO /tmp/pad<n>); returns its composite device path once it is managed."""
        machine.succeed(f"systemd-run --unit=fakepad{n} python3 /etc/fakepad.py /tmp/pad{n}")
        machine.wait_until_succeeds(f"test -p /tmp/pad{n}", timeout=30)
        path = f"/org/shadowblip/InputPlumber/CompositeDevice{n}"
        machine.wait_until_succeeds(f"busctl tree {IP} | grep -q {path}$", timeout=60)
        return path

    def mode(path, want):
        machine.wait_until_succeeds(
            f"busctl get-property {IP} {path} {CDI} InterceptMode | grep -qx 'u {want}'", timeout=30)

    def tap(n, button):
        machine.succeed(f"echo 'press {button}' > /tmp/pad{n}")
        time.sleep(0.3)
        machine.succeed(f"echo 'release {button}' > /tmp/pad{n}")
        time.sleep(0.3)

    def hat(n):
        """D-pad right and back on pad n."""
        machine.succeed(f"echo 'axis ABS_HAT0X 1' > /tmp/pad{n}")
        time.sleep(0.3)
        machine.succeed(f"echo 'axis ABS_HAT0X 0' > /tmp/pad{n}")
        time.sleep(0.3)

    def read_events():
        return [l for l in machine.succeed(f"cat {events}").splitlines() if l.startswith("EVENT")]

    # The launcher in front: the daemon puts the pad in ALL (2).
    pad0 = plug(0)
    mode(pad0, 2)

    # Every input_nav the launcher would get, from a subscribed client.
    sub = [hello(), {"jsonrpc": "2.0", "id": 1, "method": "subscribe", "params": {"events": ["input_nav"]}}]
    payload = "".join(json.dumps(m) + "\n" for m in sub)
    cmd = f"(printf %s {shlex.quote(payload)}; sleep 600) | socat -t600 - UNIX-CONNECT:{sock} > /tmp/nav.txt"
    machine.succeed(f"systemd-run --uid=hinteros --unit=navlog -E PATH=/run/current-system/sw/bin sh -c {shlex.quote(cmd)}")

    with subtest("the app in front reads the pad"):
        ok("apps.launch", {"id": "padreader"})
        mode(pad0, 1)
        machine.wait_until_succeeds(f"grep -q '^open Microsoft X-Box 360 pad' {events}", timeout=60)
        tap(0, "BTN_SOUTH")
        machine.wait_until_succeeds(f"grep -q 'EVENT Microsoft X-Box 360 pad | BTN_SOUTH 1' {events}", timeout=10)

    with subtest("the launcher in front: the app reads nothing, the launcher gets the input"):
        tap(0, "BTN_MODE")  # Guide: Home
        mode(pad0, 2)
        machine.sleep(1)
        before = read_events()
        # Nothing that activates a tile (A would start the app again, with the pad).
        for b in ["BTN_EAST", "BTN_TL", "BTN_TR"]:
            tap(0, b)
        hat(0)
        machine.wait_until_succeeds("grep -q '\"action\":\"page_right\"' /tmp/nav.txt", timeout=10)
        machine.wait_until_succeeds("grep -q '\"action\":\"right\"' /tmp/nav.txt", timeout=10)
        machine.sleep(2)
        after = read_events()
        assert after == before, after[len(before):]

    with subtest("a pad plugged in while the launcher is in front: the app reads nothing"):
        pad1 = plug(1)
        mode(pad1, 2)
        machine.wait_until_succeeds(f"test \"$(grep -c '^open Microsoft X-Box 360 pad' {events})\" -ge 2", timeout=30)
        before = read_events()
        nav_lines = int(machine.succeed("wc -l < /tmp/nav.txt"))
        tap(1, "BTN_EAST")
        hat(1)
        machine.wait_until_succeeds(f"tail -n +{nav_lines + 1} /tmp/nav.txt | grep -q '\"action\":\"back\"'", timeout=10)
        machine.sleep(2)
        after = read_events()
        assert after == before, after[len(before):]
        mode(pad0, 2)

    with subtest("the app in front again reads both pads"):
        ok("apps.focus", {"id": "padreader"})
        mode(pad0, 1)
        mode(pad1, 1)
        before = int(machine.succeed(f"wc -l < {events}"))
        tap(0, "BTN_EAST")
        tap(1, "BTN_TR")
        machine.wait_until_succeeds(f"tail -n +{before + 1} {events} | grep -q 'BTN_EAST 1'", timeout=10)
        machine.wait_until_succeeds(f"tail -n +{before + 1} {events} | grep -q 'BTN_TR 1'", timeout=10)

    # The physical (fake) pads were never a readable second stream.
    machine.fail(f"grep -q 'EVENT Sunshine' {events}")
    print(machine.succeed(f"grep '^open' {events}"))
    ok("apps.close", {"id": "padreader"})
  '';
}
