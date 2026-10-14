# Switching profiles without a reboot (profiles.md "A switch, step by step", "PAM: where the PIN
# and the kill are enforced", "Device access per seat"; VM `profiles-switch` and
# `profiles-blocked-app`). Greeter mode; p1 = `hinteros` (admin, unlocked, PIN 1357), whose apps
# are one stubborn "Moonlight" (an app that ignores SIGTERM, like a hung game); p2 =
# `hinteros-p2` (locked, PIN 2468, no apps).
#   - p1 opens from the picker without a PIN. Beside the stubborn app it leaves things the
#     session daemon never started: a transient user service, a `setsid` process and a process
#     holding /dev/uinput open (which only works through uaccess).
#   - No silent force-close: switching to p2 SIGTERMs the app, which keeps running; after 10 s
#     `switch_blocked` names it, and nothing is killed while the pop-up waits (Keep waiting asks
#     again after another 10 s). Cancel switch: p1's session and the app stay, the hint is gone.
#   - A wrong PIN for the locked p2 is refused in p1's session before anything closes.
#   - Force close: the switch completes straight into p2 (its PIN given in p1's session), and
#     end-others leaves no process of p1 at all.
#   - Devices (uinput, DRM) follow the active session (uaccess ACLs name p2, not p1); no
#     profile has any ACL on a keyboard or can read one (the hinteros-keyboard unit reads them
#     for Ctrl+Super+D); no account is in a static device group;
#     InputPlumber's polkit actions are the active session's only (a system service running as
#     a profile user is refused).
#   - The box never rebooted and hinteros-system kept running; switching back to the unlocked p1
#     needs no PIN, and p2's leftovers (a system-level unit of its uid) are gone too.
# Not covered in a VM: gamescope's DRM master handover and real controllers on a switch (cage
# here; the couch checklist times a switch on the box).
{ self, pkgs }:
let
  profiles = import ./system/profiles.nix { inherit self pkgs; };
in
profiles.mkTest {
  name = "profiles-switch";
  timeout = 1800;
  state = profiles.mkState {
    accounts = [
      "p1"
      "p2"
    ];
    guest = false;
  };
  profiles = {
    p1 = {
      name = "James";
      admin = true;
      pin = "1357";
    };
    p2 = {
      name = "Sam";
      color = "orange";
      locked = true;
      pin = "2468";
    };
  };
  # "Moonlight" is the stubborn app in every env that has it.
  overrides.moonlight.package = profiles.stubbornApp;
  envs = {
    moon.ids = [ "moonlight" ];
    empty.ids = [ ];
  };
  appProfiles = {
    hinteros = "moon";
    hinteros-p2 = "empty";
  };

  testScript = ''
    systems = boot_box()
    boot_id = machine.succeed("cat /proc/sys/kernel/random/boot_id").strip()
    def service_pid():
        return machine.succeed("systemctl show -p MainPID --value hinteros-system.service").strip()
    system_pid = service_pid()

    def read_log(path):
        out = machine.succeed(f"cat {path} 2>/dev/null || true")
        return [json.loads(l) for l in out.splitlines() if l.strip()]

    def events(path, name):
        return [m["params"] for m in read_log(path) if m.get("method") == name]

    def start_switch(path, target, pin=None):
        machine.succeed("runuser -u hinteros -- mkdir -p /tmp/sw")
        machine.succeed(
            f"(runuser -u hinteros -- env {ENV} HINTEROS_SESSION_SOCK={sock('hinteros')} "
            f"python3 /etc/hinteros-test/switcher.py {path} {target} {pin or '''} >/dev/null 2>&1 &)"
        )
        machine.wait_until_succeeds(f"grep -q response {path}", timeout=60)
        r = read_log(path)[0]["response"]
        assert r.get("result") == {}, r

    def press(path, command):
        # The pop-up's button (switcher.py reads it as the session user).
        machine.succeed(f"runuser -u hinteros -- sh -c 'echo {command} > {path}.cmd'")
        machine.wait_until_fails(f"test -e {path}.cmd", timeout=30)

    def wait_blocked(path, n):
        for _ in range(90):
            if len(events(path, "switch_blocked")) >= n:
                return events(path, "switch_blocked")
            machine.sleep(1)
        raise AssertionError(f"no switch_blocked #{n}: {read_log(path)}")

    with subtest("boot: the picker; the unlocked p1 opens without a PIN"):
        picker_up()
        g = greeter("p1")
        assert len(g["outcomes"]) == 1 and g["outcomes"][0]["ok"] is True, g
        session_of("hinteros")
        for _ in range(60):
            if "moonlight" in [a["id"] for a in sess_ok("hinteros", "apps.list")["apps"]]:
                break
            machine.sleep(1)
        assert "moonlight" in [a["id"] for a in sess_ok("hinteros", "apps.list")["apps"]]

    with subtest("p1 leaves processes the session daemon never started"):
        u1 = uid("hinteros")
        user_env = f"XDG_RUNTIME_DIR=/run/user/{u1} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{u1}/bus"
        machine.succeed(f"runuser -u hinteros -- env {user_env} systemd-run --user --unit=leftover sleep 1000")
        machine.succeed("runuser -u hinteros -- setsid -f sleep 1001 </dev/null >/dev/null 2>&1")
        # Opening /dev/uinput works only through the active session's uaccess ACL.
        print(machine.succeed("ls -l /dev/uinput; getfacl -p /dev/uinput; loginctl list-sessions --no-legend"))
        machine.succeed("runuser -u hinteros -- python3 -c 'open(\"/dev/uinput\", \"wb\")'")
        machine.succeed(
            "runuser -u hinteros -- setsid -f python3 -c "
            "'import time; f = open(\"/dev/uinput\", \"wb\"); time.sleep(100000)' </dev/null >/dev/null 2>&1"
        )
        machine.wait_until_succeeds("pgrep -u hinteros -f 'sleep 1000'")
        machine.wait_until_succeeds("pgrep -u hinteros -f 'sleep 1001'")
        holder = machine.wait_until_succeeds("pgrep -u hinteros -f 'dev/uinput'", timeout=30).split()[0]
        machine.succeed(f"ls -l /proc/{holder}/fd | grep -q /dev/uinput")

    with subtest("a stubborn app: no silent force-close; Cancel switch keeps the profile"):
        r = sess("hinteros", "apps.launch", {"id": "moonlight"})
        assert "result" in r, r
        app = machine.wait_until_succeeds("pgrep -u hinteros -f stubborn-app").split()[0]
        L = "/tmp/sw/cancel.log"
        start_switch(L, "p2", "2468")
        # The hint with p2's one-time token is written; the app got SIGTERM and ignored it.
        machine.succeed("test -e /run/hinteros/switch.json")
        b = wait_blocked(L, 1)
        assert b[0]["app"]["id"] == "moonlight" and b[0]["waited_s"] >= 10, b
        stages = [p["stage"] for p in events(L, "switch_progress")]
        assert stages[0] == "closing_apps" and "ending" not in stages, stages
        # Nothing is killed while the pop-up waits for an answer.
        machine.sleep(15)
        machine.succeed(f"kill -0 {app}")
        machine.succeed("pgrep -u hinteros -f '/bin/cage '")
        machine.fail("pgrep -u hinteros-p2")
        assert len(events(L, "switch_blocked")) == 1, read_log(L)
        # Keep waiting: asked again after another 10 s.
        press(L, "wait")
        b = wait_blocked(L, 2)
        assert b[1]["app"]["id"] == "moonlight", b
        machine.succeed(f"kill -0 {app}")
        # Cancel switch: the session stays, with the app; the hint is dropped.
        press(L, "cancel")
        machine.wait_until_succeeds(f"grep -q '\"done\": \"cancelled\"' {L}", timeout=30)
        machine.fail("test -e /run/hinteros/switch.json")
        machine.succeed(f"kill -0 {app}")
        machine.succeed("pgrep -u hinteros -f '/bin/cage '")
        machine.sleep(5)
        machine.fail("pgrep -u hinteros-p2")
        assert sess_ok("hinteros", "profile.current")["id"] == "p1"

    with subtest("the locked p2: a wrong PIN is refused in p1's session, nothing closes"):
        r = sess("hinteros", "session.switch_profile", {"id": "p2", "pin": "0000"})
        assert r["error"]["code"] == 3016 and r["error"]["data"]["pin"] == "target", r
        r = sess("hinteros", "session.switch_profile", {"id": "p2"})
        assert r["error"]["code"] == 3016 and r["error"]["data"]["pin"] == "target", r
        machine.succeed(f"kill -0 {app}")
        machine.fail("test -e /run/hinteros/switch.json")

    with subtest("Force close: the switch completes into p2; nothing of p1 is left"):
        L = "/tmp/sw/force.log"
        start_switch(L, "p2", "2468")
        wait_blocked(L, 1)
        machine.succeed(f"kill -0 {app}")
        press(L, "force_close moonlight")
        session_of("hinteros-p2")
        stages = [p["stage"] for p in events(L, "switch_progress")]
        assert stages[0] == "closing_apps" and stages[-1] == "ending", stages
        # end-others: the app, the user service, the setsid process, the uinput holder, the
        # session: every process of the uid.
        machine.wait_until_fails("pgrep -u hinteros", timeout=30)
        machine.fail(f"kill -0 {app}")
        cur = sess_ok("hinteros-p2", "profile.current")
        assert cur["id"] == "p2" and cur["locked"] and not cur["admin"], cur
        # The token was used up.
        machine.fail("test -e /run/hinteros/switch.json")

    with subtest("devices follow the active session; no static device groups"):
        # Keyboards never: no profile has an ACL on one or can read it (a game could log the admin
        # password). Only the hinteros-keyboard unit reads them (Ctrl+Super+D).
        keyboards = machine.succeed(
            "for d in /dev/input/event*; do udevadm info -q property $d | grep -qx ID_INPUT_KEYBOARD=1 && echo $d; done; true"
        ).split()
        assert keyboards, machine.succeed("ls -l /dev/input")
        machine.wait_until_succeeds("journalctl -b -u hinteros-keyboard | grep -q 'keyboard found'", timeout=30)
        for dev in keyboards:
            acl = machine.succeed(f"getfacl -p {dev}")
            assert "user:hinteros" not in acl, (dev, acl)
            for u in ["hinteros", "hinteros-p2"]:
                machine.fail(f"runuser -u {u} -- test -r {dev}")
        for dev in ["/dev/uinput"] + machine.succeed("ls /dev/dri/card* /dev/dri/renderD* 2>/dev/null || true").split():
            acl = machine.succeed(f"getfacl -p {dev}")
            assert "user:hinteros-p2:" in acl, (dev, acl)
            assert "user:hinteros:" not in acl, (dev, acl)
        for u in ["hinteros", "hinteros-p2", "hinteros-greeter"]:
            groups = set(machine.succeed(f"id -nG {u}").split())
            assert not groups & {"video", "input", "uinput", "inputplumber", "wheel"}, (u, groups)

    with subtest("InputPlumber: the active session's processes only"):
        # An InputPlumber action that is not open to everyone by its own defaults (implicit any
        # is not "yes"): only our rule can grant it.
        action = None
        for a in machine.succeed("pkaction | grep '^org.shadowblip'").split():
            v = machine.succeed(f"pkaction --action-id {a} --verbose")
            anyv = [l.split(":", 1)[1].strip() for l in v.splitlines() if l.strip().startswith("implicit any:")]
            if anyv and anyv[0] != "yes":
                action = a
                break
        assert action, machine.succeed("pkaction --verbose | grep -A6 shadowblip")
        cage = machine.succeed("pgrep -u hinteros-p2 -o -f '/bin/cage '").strip()
        machine.succeed(f"pkcheck --action-id {action} --process {cage}")
        # A system service running as the active profile's user is not in its session.
        machine.succeed("systemd-run --uid=hinteros-p2 --unit=p2-system sleep 1000")
        pid = machine.succeed("systemctl show -p MainPID --value p2-system.service").strip()
        machine.fail(f"pkcheck --action-id {action} --process {pid}")
        machine.succeed("systemd-run --uid=hinteros --unit=p1-system sleep 1000")
        pid = machine.succeed("systemctl show -p MainPID --value p1-system.service").strip()
        machine.fail(f"pkcheck --action-id {action} --process {pid}")
        machine.succeed("systemctl stop p1-system.service")

    with subtest("no reboot: the box kept running"):
        assert machine.succeed("cat /proc/sys/kernel/random/boot_id").strip() == boot_id
        assert service_pid() == system_pid
        assert current_system() == systems[""]

    with subtest("back to the unlocked p1: no PIN; nothing of p2 is left"):
        switch("hinteros-p2", "p1", "hinteros")
        machine.wait_until_fails("pgrep -u hinteros-p2", timeout=30)
        machine.fail("systemctl is-active p2-system.service")
        acl = machine.succeed("getfacl -p /dev/uinput")
        assert "user:hinteros:" in acl and "user:hinteros-p2:" not in acl, acl
        assert machine.succeed("cat /proc/sys/kernel/random/boot_id").strip() == boot_id
  '';
}
