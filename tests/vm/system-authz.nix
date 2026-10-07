# Who may talk to the privileged service and what each caller gets. The socket is root:hinteros
# 0660; read-only methods work for any member; mutating ones need the seat0 owner, polkit YES
# (the hinteros group rule), and `ssh.set` needs the admin password (auth_admin), so the session
# user gets authentication_required. A rules file returning NO is honored; pkcheck agrees per
# action; every decision is in the system journal.
{ self, pkgs }:
let
  denyRule = pkgs.writeText "deny.rules" ''
    polkit.addRule(function (action, subject) {
      if (action.id === "org.hinteros.system.settings" && subject.user === "hinteros") {
        return polkit.Result.NO;
      }
    });
  '';
in
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-system-authz";

  nodes.machine = import ./system/node.nix { inherit self pkgs; };

  testScript = ''
    import json

    ACTIONS = ["settings", "rebuild", "update.check", "update.apply", "rollback", "channel", "jobs.cancel"]

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("hinteros-system.service")
    machine.wait_for_unit("greetd.service")
    machine.wait_until_succeeds("loginctl list-sessions --no-legend | grep -w hinteros")
    machine.wait_until_succeeds("test -S /run/hinteros/system.sock")
    # seat0's active session belongs to the session user (and to nobody else).
    machine.wait_until_succeeds("loginctl show-seat seat0 -p ActiveSession --value | grep -q .")
    sid = machine.succeed("loginctl show-seat seat0 -p ActiveSession --value").strip()
    assert machine.succeed(f"loginctl show-session {sid} -p Name --value").strip() == "hinteros"
    machine.fail("loginctl list-sessions --no-legend | grep -w guest")
    # The launcher may start its own job at startup (an update check); let it settle.
    def rpc(user, method, params=None):
        out = machine.succeed(f"runuser -u {user} -- python3 /etc/hinteros-test/rpc.py {method} '{json.dumps(params or {})}'")
        return json.loads(out)
    for _ in range(60):
        if not [j for j in rpc("hinteros", "jobs.list")["response"]["result"]["jobs"] if j["state"] == "running"]:
            break
        machine.sleep(1)
    machine.sleep(3)

    def err(r):
        assert "response" in r and r["response"] and "error" in r["response"], r
        return r["response"]["error"]

    with subtest("the policy files"):
        assert machine.succeed("stat -c '%a %U:%G' /run/hinteros/system.sock").strip() == "660 root:hinteros"
        pol = machine.succeed("cat /run/current-system/sw/share/polkit-1/actions/org.hinteros.system.policy")
        for a in ACTIONS:
            assert f'org.hinteros.system.{a}"' in pol, a
        machine.succeed("grep -q 'isInGroup(\"hinteros\")' /etc/polkit-1/rules.d/50-hinteros.rules")
        assert "org.hinteros.system.ssh.admin" not in pol
        for a in ACTIONS:
            v = machine.succeed(f"pkaction --action-id org.hinteros.system.{a} --verbose")
            assert "implicit any:\n    no" in v.replace("  implicit any:     ", "  implicit any:\n    ") or "no" in v, v
        v = machine.succeed("pkaction --action-id org.hinteros.system.ssh --verbose")
        assert v.count("auth_admin") >= 3, v

    with subtest("a user outside the group cannot even connect"):
        assert rpc("stranger", "system.info") == {"connect_error": "EACCES"}

    with subtest("read-only methods: the session user and a member that does not own the seat"):
        for user in ("hinteros", "guest"):
            info = rpc(user, "system.info")["response"]["result"]
            assert info["dev"] is False and info["version"] == "0.1.0-dev", info
            assert info["channel"] == "stable" and info["base"] == "unstable", info
            assert "revision" in rpc(user, "settings.get")["response"]["result"]
            assert "generations" in rpc(user, "generations.list")["response"]["result"]
            assert "jobs" in rpc(user, "jobs.list")["response"]["result"]

    rev = rpc("hinteros", "settings.get")["response"]["result"]["revision"]

    with subtest("mutating: refused for a member that does not own seat0 (guest)"):
        for method, params in [
            ("settings.set", {"revision": rev, "changes": {}}),
            ("rebuild", {}),
            ("rollback", {}),
            ("update.check", {}),
            ("channel.set", {"channel": "beta"}),
            ("base.set", {"base": "stable", "acknowledge_downgrade": True}),
            ("jobs.cancel", {"job_id": "0123456789abcdef"}),
            ("ssh.set", {"enabled": True}),
        ]:
            e = err(rpc("guest", method, params))
            assert e["code"] == 3002 and e["data"]["reason"] == "seat", (method, e)

    with subtest("mutating: the session user passes the seat and polkit checks"):
        r = rpc("hinteros", "settings.set", {"revision": rev, "changes": {}})["response"]
        assert r["result"] == {"job_id": None}, r  # nothing to change, so no job
        e = err(rpc("hinteros", "settings.set", {"revision": "f" * 64, "changes": {}}))
        assert e["code"] == 3007 and e["data"]["reason"] == "revision", e
        e = err(rpc("hinteros", "jobs.cancel", {"job_id": "0123456789abcdef"}))
        assert e["code"] == 3010, e  # allowed through, then not found

    with subtest("ssh.set from the session user: authentication_required"):
        for enabled in (True, False):
            e = err(rpc("hinteros", "ssh.set", {"enabled": enabled}))
            assert e["code"] == 3012 and e["data"] == {"action": "org.hinteros.system.ssh"}, e
        # And nothing changed: no sshd, no state change.
        machine.fail("systemctl is-active sshd.service")
        assert json.loads(machine.succeed("cat /etc/hinteros/state.json"))["settings"]["ssh"]["enable"] is False

    with subtest("pkcheck per action"):
        def proc_of(user):
            unit = f"probe-{user}"
            machine.succeed(f"systemd-run --uid={user} --unit={unit} sleep 3600")
            return machine.succeed(f"systemctl show -p MainPID --value {unit}.service").strip()

        def pk(action, pid):
            return machine.execute(f"pkcheck --action-id org.hinteros.system.{action} --process {pid}")[0]

        mine = proc_of("hinteros")
        for a in ACTIONS:
            assert pk(a, mine) == 0, ("session user", a)
        print("pkcheck ssh (session user):", pk("ssh", mine))
        assert pk("ssh", mine) in (2, 3), "ssh needs authentication for the session user (a challenge, not a plain no)"
        member = proc_of("guest")
        for a in ACTIONS:
            assert pk(a, member) == 0, ("member without the seat is allowed by polkit; the seat check is the service's", a)
        assert pk("ssh", member) in (2, 3)
        other = proc_of("stranger")
        for a in ACTIONS + ["ssh"]:
            assert pk(a, other) != 0, ("non-member", a)
        for u in ("hinteros", "guest", "stranger"):
            machine.succeed(f"systemctl stop probe-{u}.service")

    with subtest("a rules file returning NO is honored"):
        machine.copy_from_host("${denyRule}", "/etc/polkit-1/rules.d/20-test-deny.rules")
        mine = machine.succeed("pgrep -u hinteros -f hinteros-launcher | head -n1").strip()
        machine.wait_until_fails(f"pkcheck --action-id org.hinteros.system.settings --process {mine}")
        machine.succeed(f"pkcheck --action-id org.hinteros.system.rollback --process {mine}")
        e = err(rpc("hinteros", "settings.set", {"revision": rev, "changes": {}}))
        assert e["code"] == 3002 and e["data"] == {"action": "org.hinteros.system.settings", "reason": "polkit"}, e
        # Other actions of the same user are unaffected (not_found: past the polkit gate).
        assert err(rpc("hinteros", "jobs.cancel", {"job_id": "0123456789abcdef"}))["code"] == 3010
        machine.succeed("rm /etc/polkit-1/rules.d/20-test-deny.rules")
        machine.wait_until_succeeds(f"pkcheck --action-id org.hinteros.system.settings --process {mine}")
        assert rpc("hinteros", "settings.set", {"revision": rev, "changes": {}})["response"]["result"] == {"job_id": None}

    with subtest("every decision is in the system journal"):
        out = machine.succeed("journalctl -o json --no-pager HINTEROS_AUDIT=1")
        entries = [json.loads(l) for l in out.splitlines() if l.strip()]
        seen = {(e.get("HINTEROS_UID"), e.get("HINTEROS_DECISION")) for e in entries}
        print(sorted(seen, key=str))
        uid = machine.succeed("id -u hinteros").strip()
        guid = machine.succeed("id -u guest").strip()
        assert (guid, "denied_seat") in seen, seen
        assert (uid, "auth_required") in seen, seen
        assert (uid, "denied_polkit") in seen, seen
        assert (uid, "allowed") in seen, seen
        machine.fail("runuser -u hinteros -- journalctl --system HINTEROS_AUDIT=1 -q | grep -q HINTEROS")
  '';
}
