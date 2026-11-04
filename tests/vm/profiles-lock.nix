# Locked profiles at the picker and after sleep (profiles.md "PINs and locking", "Boot, sleep and
# other entries"; VM `profiles-lock`). Greeter mode; p1 = `hinteros-p1` (James, admin, unlocked, PIN
# 2468), p2 = `hinteros-p2` (Sam, locked, PIN 1357), p3 = `hinteros-p3` (Alex, unlocked, PIN 3690).
#   - The picker asks a locked profile for its PIN (a wrong one is refused) and opens an unlocked
#     one without asking.
#   - Sleep: the session daemon holds a logind sleep delay inhibitor. On logind's
#     PrepareForSleep(true) a locked profile's session locks (`lock_changed {locked: true}`,
#     `profile.current.screen_locked`), and stays locked after resume (PrepareForSleep(false)),
#     with the inhibitor taken again for the next sleep. A wrong PIN is refused (the shared
#     backoff applies: the fourth failure waits), the right one unlocks. An unlocked profile is
#     not locked by a sleep. The same signal from another bus client (`busctl emit` as root)
#     changes nothing.
# SIMULATED: the sleep itself. `systemctl suspend` goes through logind (its PrepareForSleep
# signals and the delay inhibitors), but systemd-suspend.service only waits a few seconds instead
# of suspending the VM. On hardware: the lock screen drawn before the TV goes dark, InputPlumber in
# ALL mode behind it, and the wake-up itself (couch checklist).
{ self, pkgs }:
let
  profiles = import ./system/profiles.nix { inherit self pkgs; };
in
profiles.mkTest {
  name = "profiles-lock";
  timeout = 1800;
  state = profiles.mkState {
    accounts = [
      "p1"
      "p2"
      "p3"
    ];
    guest = false;
  };
  profiles = {
    p1 = {
      name = "James";
      admin = true;
      pin = "2468";
    };
    p2 = {
      name = "Sam";
      color = "orange";
      locked = true;
      pin = "1357";
    };
    p3 = {
      name = "Alex";
      color = "purple";
      pin = "3690";
    };
  };

  # The VM never sleeps: what logind's Suspend starts waits until the test touches
  # /run/stub-resume (a minute at most), then logind sends PrepareForSleep(false).
  extraModule =
    { pkgs, ... }:
    {
      systemd.services.systemd-suspend.serviceConfig.ExecStart = [
        ""
        (pkgs.writeShellScript "stub-suspend" ''
          for _ in $(${pkgs.coreutils}/bin/seq 300); do
            [ -e /run/stub-resume ] && break
            ${pkgs.coreutils}/bin/sleep 0.2
          done
          ${pkgs.coreutils}/bin/rm -f /run/stub-resume
        '')
      ];
    };

  testScript = ''
    boot_box()

    def suspend():
        # logind sends PrepareForSleep(true) and waits for the delay inhibitors.
        machine.succeed("systemctl suspend")

    def resume():
        # The stub suspend ends; logind sends PrepareForSleep(false).
        machine.succeed("touch /run/stub-resume")

    def fake_sleep_signal():
        # Anyone on the system bus can emit a signal of that name; not from logind, it is ignored.
        machine.succeed("busctl emit /org/freedesktop/login1 org.freedesktop.login1.Manager PrepareForSleep b true")
        # A unicast signal gets past the bus's sender match: send one to each connection of
        # the session daemon too.
        conns = [
            l.split()[0]
            for l in machine.succeed("busctl list --unique --no-legend --no-pager").splitlines()
            if "hinteros-p2" in l.split()
        ]
        assert conns, machine.succeed("busctl list --unique --no-pager")
        for c in conns:
            machine.succeed(
                f"busctl emit --destination={c} /org/freedesktop/login1 org.freedesktop.login1.Manager PrepareForSleep b true"
            )

    def inhibitor_of(user):
        out = machine.succeed("systemd-inhibit --list --no-legend --no-pager || true")
        return [l for l in out.splitlines() if "HinterOS" in l and user in l.split() and "sleep" in l and "delay" in l]

    def start_watch(user, path):
        # The launcher's connection: lock_changed events, appended to `path`.
        machine.succeed(f"runuser -u {user} -- touch {path}")
        machine.succeed(
            f"(runuser -u {user} -- env {ENV} HINTEROS_SESSION_SOCK={sock(user)} python3 -c '"
            "import json, sys; from session import Session; s = Session(); s.s.settimeout(None); "
            "s.call(\"subscribe\", {\"events\": [\"lock_changed\"]}); out = open(sys.argv[1], \"a\", buffering=1); "
            "out.write(\"subscribed\\n\")\n"
            "while True: out.write(json.dumps(s.event(\"lock_changed\", timeout=100000)) + \"\\n\")' "
            f"{path} >/dev/null 2>&1 &)"
        )
        machine.wait_until_succeeds(f"grep -q subscribed {path}", timeout=60)

    def lock_events(path):
        return [json.loads(l) for l in machine.succeed(f"cat {path}").splitlines() if l.startswith("{")]

    with subtest("the picker: a locked profile asks for its PIN, an unlocked one does not"):
        picker_up()
        listed = {p["id"]: p for p in greeter_call("greeter.list")["result"]["profiles"]}
        assert listed["p2"]["locked"] and not listed["p3"]["locked"] and not listed["p1"]["locked"], listed
        g = greeter("p2", "0000", "1357")
        assert [o["ok"] for o in g["outcomes"]] == [False, True], g
        session_of("hinteros-p2")
        cur = sess_ok("hinteros-p2", "profile.current")
        assert cur["id"] == "p2" and cur["locked"] and not cur["screen_locked"], cur

    with subtest("sleep locks a locked profile; resume keeps the lock until its PIN"):
        machine.wait_until_succeeds("systemd-inhibit --list --no-legend --no-pager | grep HinterOS | grep -q hinteros-p2", timeout=60)
        assert inhibitor_of("hinteros-p2"), machine.succeed("systemd-inhibit --list --no-pager")
        W = "/tmp/lock-p2.log"
        start_watch("hinteros-p2", W)
        fake_sleep_signal()
        machine.sleep(3)
        assert lock_events(W) == [], lock_events(W)
        assert sess_ok("hinteros-p2", "session.lock_state") == {"locked": False}
        assert inhibitor_of("hinteros-p2"), machine.succeed("systemd-inhibit --list --no-pager")
        suspend()
        machine.wait_until_succeeds(f"grep -q '\"locked\": true' {W}", timeout=30)
        assert sess_ok("hinteros-p2", "profile.current")["screen_locked"] is True
        assert sess_ok("hinteros-p2", "session.lock_state") == {"locked": True}
        # The delay inhibitor was let go so the box can sleep...
        machine.wait_until_fails("systemd-inhibit --list --no-legend --no-pager | grep HinterOS | grep -q hinteros-p2", timeout=30)
        resume()
        # ...and is taken again on resume; the lock stays up.
        machine.wait_until_succeeds("systemd-inhibit --list --no-legend --no-pager | grep HinterOS | grep -q hinteros-p2", timeout=30)
        assert sess_ok("hinteros-p2", "session.lock_state") == {"locked": True}
        # The session (and what runs in it) is still there: a sleep is not a switch.
        machine.succeed("pgrep -u hinteros-p2 -f '/bin/cage '")
        # Wrong PINs: refused, with the shared backoff from the fourth.
        for n in range(4):
            r = sess("hinteros-p2", "session.unlock", {"pin": "0000"})
            assert r["error"]["code"] == 3016 and r["error"]["data"]["pin"] == "self", r
        assert r["error"]["data"].get("retry_after_ms") == 1000, r
        assert sess_ok("hinteros-p2", "session.lock_state") == {"locked": True}
        # Another profile's PIN does not unlock it.
        machine.sleep(2)
        r = sess("hinteros-p2", "session.unlock", {"pin": "2468"})
        assert r["error"]["code"] == 3016, r
        assert sess_ok("hinteros-p2", "session.lock_state") == {"locked": True}
        state = json.loads(machine.succeed("cat /var/lib/hinteros/pins/p2.state"))["data"]
        while int(machine.succeed("date +%s").strip()) <= state["locked_until"]:
            machine.sleep(1)
        assert sess_ok("hinteros-p2", "session.unlock", {"pin": "1357"}) == {}
        machine.wait_until_succeeds(f"grep -q '\"locked\": false' {W}", timeout=30)
        assert [e["locked"] for e in lock_events(W)] == [True, False], lock_events(W)
        cur = sess_ok("hinteros-p2", "profile.current")
        assert not cur["screen_locked"], cur
        assert json.loads(machine.succeed("cat /var/lib/hinteros/pins/p2.state"))["data"]["failures"] == 0

    with subtest("an unlocked profile is not locked by a sleep"):
        switch("hinteros-p2", "p3", "hinteros-p3")
        machine.wait_until_succeeds("systemd-inhibit --list --no-legend --no-pager | grep HinterOS | grep -q hinteros-p3", timeout=60)
        W = "/tmp/lock-p3.log"
        start_watch("hinteros-p3", W)
        suspend()
        machine.wait_until_fails("systemd-inhibit --list --no-legend --no-pager | grep HinterOS | grep -q hinteros-p3", timeout=30)
        resume()
        machine.wait_until_succeeds("systemd-inhibit --list --no-legend --no-pager | grep HinterOS | grep -q hinteros-p3", timeout=30)
        machine.sleep(2)
        assert lock_events(W) == [], lock_events(W)
        assert sess_ok("hinteros-p3", "session.lock_state") == {"locked": False}
        assert not sess_ok("hinteros-p3", "profile.current")["screen_locked"]

    with subtest("after the locked profile is left, the picker asks for its PIN again"):
        switch("hinteros-p3", "p1", "hinteros-p1")
        r = sess("hinteros-p1", "session.switch_profile", {"id": "p2"})
        assert r["error"]["code"] == 3016 and r["error"]["data"]["pin"] == "target", r
  '';
}
