# Input layer (M0 spike 4): InputPlumber, configured only by hinteros.input, grabs a fake
# physical pad, exposes one virtual pad, and an unprivileged session user can switch the
# intercept mode and receive semantic ui_* events over DBus.
#
# The fake pad (tests/vm/input-layer/fakepad.py) is a uinput device with the Xbox 360 USB id
# (045e:028e). InputPlumber ignores uinput devices (/devices/virtual) unless their name is on
# a whitelist, so it is named "Sunshine X-Box One (virtual) pad". Rename it and the pad is
# silently not managed.
{ self, pkgs }:
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-input-layer";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [
        self.nixosModules.session
        self.nixosModules.input
      ];
      # Only the user and groups of the session are needed, not a running compositor, so the
      # test node enables the input layer on its own.
      hinteros.session.user = "hinteros";
      hinteros.input.enable = true;
      users.users.hinteros.isNormalUser = true;

      environment = {
        systemPackages = [
          (pkgs.python3.withPackages (p: [ p.evdev ]))
          pkgs.glib
          pkgs.systemd
        ];
        etc."fakepad.py".source = ./input-layer/fakepad.py;
        etc."reader.py".source = ./input-layer/reader.py;
      };
      system.stateVersion = "25.11";
      virtualisation.memorySize = 1024;
    };

  testScript = ''
    import shlex

    IP = "org.shadowblip.InputPlumber"
    MGR = "/org/shadowblip/InputPlumber/Manager"
    MGRI = "org.shadowblip.InputManager"
    CD = "/org/shadowblip/InputPlumber/CompositeDevice0"
    CDI = "org.shadowblip.Input.CompositeDevice"
    USER = "hinteros"

    def bc(args):
        """busctl as the unprivileged session user (goes through polkit)."""
        return machine.succeed(f"su {USER} -s /bin/sh -c {shlex.quote('busctl ' + args)}")

    def pad(cmd):
        machine.succeed(f"echo '{cmd}' > /tmp/fakepad.fifo")

    def window(name, actions):
        """Read all evdev nodes matching `name` and DBus InputEvent signals while driving the pad."""
        machine.execute("rm -f /tmp/r.txt /tmp/m.txt")
        machine.execute(f"(python3 /etc/reader.py '{name}' 60 > /tmp/r.txt 2>&1 &)")
        machine.execute(f"(su {USER} -s /bin/sh -c 'timeout 60 gdbus monitor --system --dest {IP}' > /tmp/m.txt 2>&1 &)")
        machine.sleep(2)
        for a in actions:
            if callable(a):
                a()
            else:
                pad(a)
            machine.sleep(1)
        machine.sleep(3)
        evdev_out = machine.succeed("cat /tmp/r.txt; pkill -f '[r]eader.py'; pkill -f '[g]dbus monitor'; true")
        signals = machine.succeed("grep 'DBusDevice.InputEvent' /tmp/m.txt | sed 's/^.*InputEvent//' || true")
        return evdev_out, signals

    machine.wait_for_unit("inputplumber.service")
    machine.wait_until_succeeds(f"busctl tree {IP}")

    # InputPlumber ignores pads until ManageAllDevices is set; the session daemon owns that in
    # the real system (hinteros.daemon), so this test does it itself, as the session user.
    def manage():
        bc(f"set-property {IP} {MGR} {MGRI} ManageAllDevices b true")
        assert "true" in bc(f"get-property {IP} {MGR} {MGRI} ManageAllDevices")

    manage()

    # A hotplugged pad becomes a composite device without any manual step.
    machine.execute("systemd-run --unit=fakepad python3 /etc/fakepad.py")
    machine.wait_until_succeeds(f"busctl tree {IP} | grep -q CompositeDevice0", timeout=60)
    machine.sleep(3)
    assert "gamepad" in bc(f"get-property {IP} {CD} {CDI} TargetDevices")

    # Mode NONE: events come out of the virtual target only; no DBus signals.
    bc(f"set-property {IP} {CD} {CDI} InterceptMode u 0")
    r, sig = window("X-Box", ["press BTN_SOUTH", "release BTN_SOUTH"])
    assert "Microsoft X-Box 360 pad | BTN_SOUTH 1" in r, r
    assert "EVENT Sunshine" not in r, "physical pad leaked as a second stream: " + r
    assert sig.strip() == "", sig

    # Mode ALL: nothing reaches the target, everything becomes ui_* signals.
    bc(f"set-property {IP} {CD} {CDI} InterceptMode u 2")
    r, sig = window("Microsoft X-Box 360", ["press BTN_SOUTH", "release BTN_SOUTH", "press BTN_MODE", "release BTN_MODE"])
    assert "EVENT" not in r, r
    assert "ui_accept" in sig and "ui_guide" in sig, sig

    # Mode PASS: games get input, Guide is captured and flips the device to ALL.
    bc(f"set-property {IP} {CD} {CDI} InterceptMode u 1")
    r, sig = window("Microsoft X-Box 360", ["press BTN_SOUTH", "release BTN_SOUTH", "press BTN_MODE", "release BTN_MODE", "press BTN_EAST", "release BTN_EAST"])
    assert "BTN_SOUTH 1" in r and "BTN_EAST" not in r, r
    assert "ui_guide" in sig and "ui_back" in sig, sig
    assert bc(f"get-property {IP} {CD} {CDI} InterceptMode").split()[-1] == "2"

    # Back to PASS while Guide is still held (the session daemon does this to tap Guide for
    # Steam on a long press): the release goes to the gamepad, and the next Guide press must
    # still reach D-Bus (dbus-clear-on-pass.patch; unpatched, the DBus target keeps Guide
    # "pressed" and drops the press as a duplicate).
    bc(f"set-property {IP} {CD} {CDI} InterceptMode u 1")
    to_pass = lambda: bc(f"set-property {IP} {CD} {CDI} InterceptMode u 1")
    r, sig = window("Microsoft X-Box 360", ["press BTN_MODE", to_pass, "release BTN_MODE", "press BTN_MODE", "release BTN_MODE"])
    assert sig.count("'ui_guide', 1.0") == 2, sig

    # The whole long press as the session daemon does it: Guide held, PASS, a Guide tap for Steam
    # through SendEvent, then the physical release. The tap reaches the virtual pad and the next
    # Guide press still reaches D-Bus (send-event-keep-active-inputs.patch; unpatched, the tap's
    # release makes InputPlumber drop the physical release and then the next press).
    bc(f"set-property {IP} {CD} {CDI} InterceptMode u 1")
    def tap():
        bc(f"set-property {IP} {CD} {CDI} InterceptMode u 1")
        bc(f"--timeout=5 call {IP} {CD} {CDI} SendEvent sv Gamepad:Button:Guide b true")
        bc(f"--timeout=5 call {IP} {CD} {CDI} SendEvent sv Gamepad:Button:Guide b false")
    r, sig = window("Microsoft X-Box 360", ["press BTN_MODE", tap, "release BTN_MODE", "press BTN_MODE", "release BTN_MODE"])
    assert "BTN_MODE 1" in r, r
    assert sig.count("'ui_guide', 1.0") == 2, sig

    # Xbox X/Y (real-hardware report: Y acted as "action", X as "context"). xpad sends BTN_Y for
    # the top Y button and BTN_X for the left X button; the kernel defines BTN_Y = BTN_WEST (0x134)
    # and BTN_X = BTN_NORTH (0x133). InputPlumber 0.81 (and upstream main) reads the codes
    # positionally: Y -> West -> ui_action, X -> North -> ui_context. Its virtual Xbox pad writes
    # the same codes back, so games see Y as BTN_Y and X as BTN_X: no swap for games. Swapping in
    # InputPlumber (capability map) would fix the ui_* names but swap X/Y in every game, so the
    # session daemon has to read ui_action as Y and ui_context as X for Xbox-convention pads.
    # This pins the behaviour it relies on.
    bc(f"set-property {IP} {CD} {CDI} InterceptMode u 0")
    r, sig = window("Microsoft X-Box 360", ["press BTN_Y", "release BTN_Y", "press BTN_X", "release BTN_X"])
    assert "| BTN_Y 1" in r and "| BTN_X 1" in r and r.index("| BTN_Y 1") < r.index("| BTN_X 1"), r
    bc(f"set-property {IP} {CD} {CDI} InterceptMode u 2")
    r, sig = window("Microsoft X-Box 360", ["press BTN_Y", "release BTN_Y", "press BTN_X", "release BTN_X"])
    assert "ui_action" in sig and "ui_context" in sig and sig.index("ui_action") < sig.index("ui_context"), sig

    # The keyboard-profile pointer, as the session daemon drives it: a profile loaded at runtime,
    # GAMEPAD_ONLY, and RT clicks through SendEvent. Unpatched, InputPlumber 0.81 panics in
    # SendEvent ("Cannot block the current thread from within a runtime",
    # composite_device/client.rs:463) and never answers: busctl times out. nixos/overlay.nix
    # patches it; the click must answer at once and reach the virtual mouse.
    yaml = "version: 1\nkind: DeviceProfile\nname: HinterOS pointer\nmapping: []\n"
    bc(f"--timeout=5 call {IP} {CD} {CDI} LoadProfileFromYaml s {shlex.quote(yaml)}")
    assert "HinterOS pointer" in bc(f"get-property {IP} {CD} {CDI} ProfileName")
    bc(f"set-property {IP} {CD} {CDI} InterceptMode u 3")
    machine.execute("rm -f /tmp/r.txt")
    machine.execute("(python3 /etc/reader.py 'InputPlumber Mouse' 30 > /tmp/r.txt 2>&1 &)")
    machine.sleep(2)
    bc(f"--timeout=5 call {IP} {CD} {CDI} SendEvent sv Mouse:Button:Left b true")
    bc(f"--timeout=5 call {IP} {CD} {CDI} SendEvent sv Mouse:Button:Left b false")
    machine.sleep(2)
    r = machine.succeed("cat /tmp/r.txt; pkill -f '[r]eader.py'; true")
    assert "InputPlumber Mouse" in r.splitlines()[0], r
    assert "BTN_MOUSE 1" in r and "BTN_MOUSE 0" in r, r

    # The right stick as the pointer: the response curve applies only where the profile's mouse
    # motion sets `curve` (pointer-response-curve.patch); without it, upstream's linear mapping
    # (any other profile, so never a game). Half deflection for 2 s at 1000 px/s: linear moves
    # about 1000 px, curve 2.5 about (0.3/0.8)^2.5 = 9 % of that.
    def pointer_px(curve):
        target = "speed_pps: 1000" + (f"\n            curve: {curve}" if curve else "")
        profile = (
            "version: 1\nkind: DeviceProfile\nname: HinterOS pointer\nmapping:\n"
            "  - name: Right stick pointer\n    source_event:\n      gamepad:\n        axis:\n"
            "          name: RightStick\n    target_events:\n      - mouse:\n          motion:\n"
            f"            {target}\n"
        )
        bc(f"--timeout=5 call {IP} {CD} {CDI} LoadProfileFromYaml s {shlex.quote(profile)}")
        machine.execute("rm -f /tmp/r.txt")
        machine.execute("(python3 /etc/reader.py 'InputPlumber Mouse' 10 > /tmp/r.txt 2>&1 &)")
        machine.sleep(2)
        pad("axis ABS_RX 16384")
        machine.sleep(2)
        pad("axis ABS_RX 0")
        machine.sleep(1)
        r = machine.succeed("cat /tmp/r.txt; pkill -f '[r]eader.py'; true")
        return sum(int(l.split()[-1]) for l in r.splitlines() if "| REL_X " in l)
    linear, curved = pointer_px(None), pointer_px(2.5)
    print(f"pointer: linear {linear} px, curve 2.5 {curved} px")
    assert 500 < linear < 1500, linear
    assert 0 < curved < linear / 4, (linear, curved)

    # Still alive and answering: the profile goes back, ALL again, Guide still a signal.
    bc(f"--timeout=5 call {IP} {CD} {CDI} LoadProfileFromYaml s {shlex.quote(yaml.replace('HinterOS pointer', 'Default'))}")
    bc(f"set-property {IP} {CD} {CDI} InterceptMode u 2")
    r, sig = window("Microsoft X-Box 360", ["press BTN_MODE", "release BTN_MODE"])
    assert "ui_guide" in sig, sig
    machine.fail("journalctl -u inputplumber.service | grep -q panicked")

    # InputPlumber restarts reset ManageAllDevices (the daemon re-applies it; see its tests).
    machine.succeed("systemctl restart inputplumber.service")
    machine.wait_until_succeeds(f"busctl tree {IP}")
    assert "false" in bc(f"get-property {IP} {MGR} {MGRI} ManageAllDevices")
    manage()
  '';
}
