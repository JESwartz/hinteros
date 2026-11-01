# `session.restart` against real greetd, logind and systemd: the daemon answers, logind ends the
# greetd session on seat0, greetd (default_session = initial_session) starts a new one with a
# new session id and a new compositor and launcher, and the session daemon (a user unit of the
# session user, which goes down with the user's last session) comes up again. Everything is real;
# nothing is stubbed. (That the restarted daemon runs a *new store path* needs a switch to another
# generation; system-jobs covers the switch, and the daemon's own tests cover the decision.)
{ self, pkgs }:
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-session-restart";
  meta.timeout = 1800;

  nodes.machine = import ./system/node.nix { inherit self pkgs; };

  testScript = ''
    import json

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("greetd.service")

    def session():
        """(session id, launcher pid, session daemon invocation id) of the running session."""
        sid = machine.succeed("loginctl show-seat seat0 -p ActiveSession --value").strip()
        assert sid, "no active session on seat0"
        assert machine.succeed(f"loginctl show-session {sid} -p Name --value").strip() == "hinteros-p1"
        launcher = machine.succeed("pgrep -u hinteros-p1 -o -f hinteros-launcher").strip()
        uid = machine.succeed("id -u hinteros-p1").strip()
        inv = machine.succeed(f"runuser -u hinteros-p1 -- env XDG_RUNTIME_DIR=/run/user/{uid} systemctl --user show -p InvocationID --value hinteros-session.service").strip()
        assert inv, "the session daemon is not running"
        return sid, launcher, inv

    machine.wait_until_succeeds("loginctl list-sessions --no-legend | grep -w hinteros-p1")
    machine.wait_until_succeeds("pgrep -u hinteros-p1 -f hinteros-launcher")
    machine.wait_until_succeeds("test -S /run/user/$(id -u hinteros-p1)/hinteros/session.sock")
    machine.sleep(5)
    before = session()
    print("before", before)

    with subtest("session.restart answers and the session is replaced"):
        out = machine.succeed("runuser -u hinteros-p1 -- python3 /etc/hinteros-test/session.py session.restart")
        assert json.loads(out)["response"].get("result") == {}, out
        machine.wait_until_fails(f"loginctl show-session {before[0]} -p State --value | grep -qx active", timeout=60)
        machine.wait_until_succeeds("loginctl list-sessions --no-legend | grep -w hinteros-p1", timeout=120)
        machine.wait_until_succeeds(f"test \"$(loginctl show-seat seat0 -p ActiveSession --value)\" != '{before[0]}' -a -n \"$(loginctl show-seat seat0 -p ActiveSession --value)\"", timeout=120)
        machine.wait_until_succeeds("pgrep -u hinteros-p1 -f '/bin/cage '", timeout=120)
        machine.wait_until_succeeds("pgrep -u hinteros-p1 -f hinteros-launcher", timeout=120)
        machine.wait_until_succeeds("test -S /run/user/$(id -u hinteros-p1)/hinteros/session.sock", timeout=120)
        machine.sleep(5)
        after = session()
        print("after", after)
        assert after[0] != before[0], "same session id"
        assert after[1] != before[1], "the launcher process was not restarted"
        assert after[2] != before[2], "the session daemon was not restarted"
        machine.succeed("systemctl is-active greetd.service")

    with subtest("the new daemon serves the launcher again, and a second restart works too"):
        out = machine.succeed("runuser -u hinteros-p1 -- python3 /etc/hinteros-test/session.py ping '{\"nonce\":\"x\"}'")
        assert json.loads(out)["response"]["result"] == {"nonce": "x"}, out
        out = machine.succeed("runuser -u hinteros-p1 -- python3 /etc/hinteros-test/session.py session.restart")
        assert json.loads(out)["response"].get("result") == {}, out
        machine.wait_until_succeeds(f"test \"$(loginctl show-seat seat0 -p ActiveSession --value)\" != '{after[0]}' -a -n \"$(loginctl show-seat seat0 -p ActiveSession --value)\"", timeout=120)
        machine.wait_until_succeeds("pgrep -u hinteros-p1 -f hinteros-launcher", timeout=120)
        machine.wait_until_succeeds("test -S /run/user/$(id -u hinteros-p1)/hinteros/session.sock", timeout=120)
  '';
}
