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

    # InputPlumber restarts reset ManageAllDevices (the daemon re-applies it; see its tests).
    machine.succeed("systemctl restart inputplumber.service")
    machine.wait_until_succeeds(f"busctl tree {IP}")
    assert "false" in bc(f"get-property {IP} {MGR} {MGRI} ManageAllDevices")
    manage()
  '';
}
