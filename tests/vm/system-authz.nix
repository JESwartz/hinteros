# Who may talk to the privileged service and what each caller gets. The socket is root:hinteros
# 0660; read-only methods work for any member; mutating ones need the seat0 owner, polkit YES
# (the hinteros group rule), and `ssh.set` needs the admin password (auth_admin), so the session
# user gets authentication_required. A rules file returning NO is honored; pkcheck agrees per
# action; every decision is in the system journal.
#
# Two profiles (profiles.md "Authority"), on a second box (schema 2, greeter mode; p1 = James, the
# admin profile, PIN 2468; p2 = Sam, PIN 1357, on screen; p3 = Alex): p2 cannot rename, remove or
# reset the PIN of another profile, change the starter set or the guest with its own PIN or
# another profile's, only with the admin PIN; the admin profile is never removable and its PIN
# needs polkit `profiles.recover`; own settings check the own PIN; apps act on the caller's own
# env only; p1 and p3 (not on screen) are refused by the seat check; the greeter's socket is the
# greeter's; no PIN reaches the journal. Rollback, channel.set, base.set, hardware.redetect and
# update.apply need the admin PIN (system API 0.9; root needs none).
{ self, pkgs }:
let
  profiles = import ./system/profiles.nix { inherit self pkgs; };
  P3_PIN = "86420975";
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

  nodes = {
    machine = import ./system/node.nix { inherit self pkgs; };
    # Started only after `machine` is shut down.
    twoprofiles = profiles.node {
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
          pin = "1357";
        };
        p3 = {
          name = "Alex";
          color = "purple";
          pin = P3_PIN;
        };
      };
      envs.empty.ids = [ ];
      appProfiles = {
        hinteros = "empty";
        hinteros-p2 = "empty";
        hinteros-p3 = "empty";
      };
    };
  };

  testScript = profiles.python + ''
    P3_PIN = "${P3_PIN}"
    # A well-formed revision for update.apply (never checked, so never the verified one).
    UPDATE_REV = "9a8b7c6d5e4f30211a2b3c4d5e6f708192a3b4c5"

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
            ("channel.check", {"channel": "beta"}),
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
        huid = machine.succeed("id -u hinteros").strip()
        guid = machine.succeed("id -u guest").strip()
        assert (guid, "denied_seat") in seen, seen
        assert (huid, "auth_required") in seen, seen
        assert (huid, "denied_polkit") in seen, seen
        assert (huid, "allowed") in seen, seen
        machine.fail("runuser -u hinteros -- journalctl --system HINTEROS_AUDIT=1 -q | grep -q HINTEROS")

    # ---- two profiles (profiles.md "Authority"): a second box, schema 2 with the greeter -------
    machine.shutdown()
    machine = twoprofiles
    boot_box()
    enter("p2", "hinteros-p2")
    jobs_idle("hinteros-p2")

    def held():
        # Everything root keeps per profile: metadata, PINs, app profiles.
        return machine.succeed(
            "cd /var/lib/hinteros && find profiles.json pins -type f ! -name '*.state' | sort | xargs sha256sum; "
            "ls -l /nix/var/nix/profiles/hinteros/apps"
        )

    def admin_refused(user, method, params):
        r = sess(user, "system." + method, params)
        assert "error" in r and r["error"]["code"] == 3016 and r["error"]["data"]["pin"] == "admin", (method, params, r)

    with subtest("two profiles: the active one cannot act on another without the admin PIN"):
        before = held()
        rev = sys_ok("hinteros-p2", "settings.get")["revision"]
        for pin in [None, "1357", P3_PIN]:  # none, its own, the other profile's
            extra = {} if pin is None else {"pin": pin}
            admin_refused("hinteros-p2", "profiles.rename", {"id": "p1", "name": "Mallory", **extra})
            admin_refused("hinteros-p2", "profiles.rename", {"id": "p3", "name": "Mallory", **extra})
            if pin is not None:
                admin_refused("hinteros-p2", "profiles.reset_pin", {"id": "p3", "new_pin": "0000", "admin_pin": pin})
                admin_refused("hinteros-p2", "profiles.remove", {"id": "p3", "confirm_id": "p3", "pin": pin, "revision": rev})
                admin_refused("hinteros-p2", "starter_set.set", {"ids": [], "pin": pin})
                admin_refused("hinteros-p2", "guest.set", {"enabled": False, "admin_pin": pin})
        # The admin profile: never removable; its PIN only with the admin account's password.
        r = sess("hinteros-p2", "system.profiles.remove", {"id": "p1", "confirm_id": "p1", "pin": "2468", "revision": rev})
        assert r["error"]["code"] == -32602 and r["error"]["data"]["reason"] == "admin", r
        r = sysrpc("hinteros-p2", "profiles.reset_pin", {"id": "p1", "new_pin": "0000", "admin_pin": "2468"})
        assert r["error"]["code"] in (3002, 3012), r
        assert r["error"]["data"]["action"] == "org.hinteros.system.profiles.recover", r
        # Own settings check the caller's own PIN, never another's.
        r = sess("hinteros-p2", "system.profiles.set_locked", {"locked": True, "pin": P3_PIN})
        assert r["error"]["code"] == 3016 and r["error"]["data"] == {"pin": "self"}, r
        # Apps: only the caller's own; another profile's revision does not reach its env.
        mine = sys_ok("hinteros-p2", "apps.list")
        assert mine["ids"] == [], mine
        e = sys_err("hinteros-p2", "apps.install", {"ids": ["moonlight"], "revision": "0" * 64}, 3007)
        assert e["data"]["reason"] == "revision", e
        assert [j for j in sys_ok("hinteros-p2", "jobs.list")["jobs"] if j["state"] == "running"] == []
        assert held() == before
        # With the admin PIN it works (from p2's session).
        assert sess_ok("hinteros-p2", "system.profiles.rename", {"id": "p3", "name": "Alexis", "pin": "2468"}) == {}
        assert profiles_file()["profiles"]["p3"]["name"] == "Alexis"

    with subtest("two profiles: the box-wide actions need the admin PIN (system API 0.9)"):
        # rollback, channel.set, base.set, hardware.redetect and update.apply: the PIN is checked
        # before anything else (also before "already on that channel/base", the generation lookup
        # and update.apply's comparison of rev with the last verified check).
        guarded = [
            ("rollback", {}),
            ("channel.set", {"channel": "stable"}),
            ("base.set", {"base": "unstable"}),
            ("hardware.redetect", {}),
            ("update.apply", {"rev": UPDATE_REV}),
        ]
        for method, params in guarded:
            for extra in [{}, {"admin_pin": "1357"}, {"admin_pin": P3_PIN}]:
                e = sys_err("hinteros-p2", method, {**params, **extra}, 3016)
                assert e["data"] == {"pin": "admin"}, (method, extra, e)
            e = sys_err("hinteros-p2", method, {**params, "admin_pin": "12"}, -32602)
            assert e["data"]["field"] == "admin_pin", (method, e)
            # The same through the session daemon's relay.
            r = sess("hinteros-p2", "system." + method, params)
            assert r["error"]["code"] == 3016 and r["error"]["data"] == {"pin": "admin"}, (method, r)
        # With the admin PIN they pass: nothing to do for the current channel and base, no older
        # generation to roll back to.
        assert sys_ok("hinteros-p2", "channel.set", {"channel": "stable", "admin_pin": "2468"}) == {"job_id": None}
        assert sys_ok("hinteros-p2", "base.set", {"base": "unstable", "admin_pin": "2468"}) == {"job_id": None}
        sys_err("hinteros-p2", "rollback", {"admin_pin": "2468"}, 3010)
        # update.apply with the PIN reaches the revision check: nothing was checked, so this rev
        # is not the last verified update.
        e = sys_err("hinteros-p2", "update.apply", {"rev": UPDATE_REV, "admin_pin": "2468"}, 3007)
        assert e["data"] == {"reason": "update_rev"}, e
        # hardware.redetect with the PIN starts its job (held at the build, then cancelled).
        machine.succeed("touch /run/stub/hold")
        j = sys_ok("hinteros-p2", "hardware.redetect", {"admin_pin": "2468"})["job_id"]
        assert j, j
        sys_call("hinteros-p2", "jobs.cancel", {"job_id": j})
        wait_job("hinteros-p2", j)
        machine.succeed("rm -f /run/stub/hold")
        # Root (a terminal) needs no PIN.
        out = json.loads(machine.succeed("python3 /etc/hinteros-test/rpc.py base.set '{\"base\": \"unstable\"}'"))
        assert out["response"].get("result") == {"job_id": None}, out
        # The audit says which PIN was checked, never the PIN.
        machine.succeed("journalctl -o verbose --no-pager HINTEROS_PIN_CHECK=admin | grep -q HINTEROS_PIN_OUTCOME=failed")

    with subtest("two profiles: the others, not on screen, cannot act at all"):
        for user in ["hinteros", "hinteros-p3"]:
            own_rev = sys_ok(user, "apps.list")["revision"]
            for method, params in [
                ("profiles.rename", {"id": "p2", "name": "Mallory", "pin": "2468"}),
                ("profiles.set_appearance", {"color": "red"}),
                ("apps.install", {"ids": ["moonlight"], "revision": own_rev}),
                ("profiles.switch", {"id": "p1"}),
            ]:
                e = sys_err(user, method, params, 3002)
                assert e["data"]["reason"] == "seat", (user, method, e)
        assert profiles_file()["profiles"]["p2"]["name"] == "Sam"

    with subtest("two profiles: the greeter's socket is the greeter's, system.sock the profiles'"):
        machine.fail(
            "runuser -u hinteros-p2 -- python3 -c "
            "'import socket; socket.socket(socket.AF_UNIX).connect(\"/run/hinteros/greeter.sock\")'"
        )
        assert rpc("hinteros-greeter", "system.info") == {"connect_error": "EACCES"}
        assert machine.succeed("stat -c '%a %U:%G' /run/hinteros/greeter.sock").strip() == "660 root:hinteros-greeter"

    with subtest("two profiles: PINs never reach the journal"):
        machine.fail(f"journalctl -o cat --no-pager | grep -q {P3_PIN}")
  '';
}
