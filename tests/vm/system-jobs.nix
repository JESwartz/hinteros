# Jobs in their own units: the machinery behind rebuild and rollback, against the real
# daemon, polkit, logind, systemd, `nix-env` and `switch-to-configuration`.
#
# STUBBED: evaluating and building the new system. The job unit's PATH starts with a stub `nix`
# whose `build` (the only nix command these jobs run) waits for a hold file and then prints the
# store path of a prebuilt system. That system is a *specialisation* of the VM itself (it
# differs in the hinteros-system unit and a marker file, and carries another config snapshot), so
# everything after the build is real: the profile generation, the real switch (which restarts
# hinteros-system while its own job runs), the /etc/hinteros replacement and the rollback.
# An in-VM `nix build` of the whole device flake is not offline-feasible here (the installer
# test covers an offline evaluation and build, in a much bigger VM).
{ self, pkgs }:
let
  stubNix = nix: import ./system/stub-nix.nix { inherit pkgs nix; };
in
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-system-jobs";
  meta.timeout = 1800;

  nodes.machine =
    { config, lib, ... }:
    {
      imports = [ (import ./system/node.nix { inherit self pkgs; }) ];

      systemd.services."hinteros-job@".path = lib.mkBefore [ (stubNix config.nix.package) ];

      # The VM boots its kernel directly; there is no boot loader for the switch to install.
      boot.loader.grub.enable = lib.mkForce false;

      # The "new system": a different hinteros-system unit (so the switch restarts the service in
      # the middle of its own job), a marker, and another config snapshot.
      specialisation.variant.configuration = {
        environment.etc."hinteros-variant".text = "variant\n";
        systemd.services.hinteros-system.environment.HINTEROS_TEST_VARIANT = "1";
        hinteros.deviceConfig.configDir = lib.mkForce ./fixtures/system-b;
      };
    };

  testScript = ''
    import json
    import time

    FIXTURE_A = "${./fixtures/system-a}"
    REV_A = "a" * 40

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("hinteros-system.service")
    machine.wait_for_unit("greetd.service")
    machine.wait_until_succeeds("loginctl list-sessions --no-legend | grep -w hinteros-p1")
    machine.wait_until_succeeds("test -S /run/hinteros/system.sock")

    def rpc(method, params=None, user="hinteros-p1"):
        rc, out = machine.execute(f"runuser -u {user} -- python3 /etc/hinteros-test/rpc.py {method} '{json.dumps(params or {})}'")
        try:
            return json.loads(out)
        except ValueError:
            return {"failed": out}

    def call(method, params=None, user="hinteros-p1"):
        r = rpc(method, params, user)
        assert "response" in r and r["response"], r
        return r["response"]

    def ok(method, params=None, user="hinteros-p1"):
        r = call(method, params, user)
        assert "result" in r, (method, params, r)
        return r["result"]

    def fails(method, params, code, user="hinteros-p1"):
        r = call(method, params, user)
        assert "error" in r and r["error"]["code"] == code, (method, params, r)
        return r["error"]

    def jobs():
        return ok("jobs.list")["jobs"]

    def wait_job(jid, timeout=240):
        """Poll until the job leaves `running`; the service may be restarted meanwhile."""
        for _ in range(timeout):
            r = rpc("jobs.get", {"job_id": jid})
            resp = r.get("response")
            if resp and "result" in resp and resp["result"]["job"]["state"] != "running":
                return resp["result"]["job"]
            time.sleep(1)
        raise AssertionError(f"job {jid} did not finish: {rpc('jobs.get', {'job_id': jid})}")

    def pid():
        return machine.succeed("systemctl show -p MainPID --value hinteros-system.service").strip()

    def gens():
        return ok("generations.list")["generations"]

    def current_gen():
        cur = [g for g in gens() if g["current"]]
        assert len(cur) == 1, gens()
        return cur[0]

    def tree_hash():
        return machine.succeed("cd /etc/hinteros && find . -type f | sort | xargs sha256sum | sha256sum").strip()

    def current_system():
        return machine.succeed("readlink -f /run/current-system").strip()

    # The launcher may start a job of its own at startup (an update check); let it finish.
    for _ in range(60):
        if not [j for j in jobs() if j["state"] == "running"]:
            break
        machine.sleep(1)
    machine.sleep(3)

    # ---- set up: generation 1 is the running system; the stub builds the variant ------------
    orig = current_system()
    variant = machine.succeed("readlink -f /run/current-system/specialisation/variant").strip()
    assert variant != orig
    machine.succeed("mkdir -p /run/stub")
    machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {orig}")
    machine.succeed(f"echo {variant} > /run/stub/toplevel")
    machine.succeed("(runuser -u hinteros-p1 -- python3 /etc/hinteros-test/events.py /tmp/events.ndjson >/dev/null 2>&1 &)")
    machine.wait_until_succeeds("grep -q subscribed /tmp/events.ndjson")

    with subtest("generations and the settings round trip"):
        g = gens()
        assert len(g) == 1 and g[0]["current"] and g[0]["booted"], g
        assert g[0]["rev"] == REV_A, g
        gen1 = g[0]["generation"]
        rev = ok("settings.get")["revision"]
        assert ok("settings.get")["settings"] == {"base": "unstable", "ssh": {"enabled": False}, "requirements": []}
        # No settable fields: an empty change is "nothing to do" (no job), a stale
        # revision is a conflict, any field is invalid.
        assert ok("settings.set", {"revision": rev, "changes": {}}) == {"job_id": None}
        assert fails("settings.set", {"revision": "f" * 64, "changes": {}}, 3007)["data"]["reason"] == "revision"
        assert fails("settings.set", {"revision": rev, "changes": {"ssh": {"enabled": True}}}, -32602)
        # Requesting the state the box already has is not a job either.
        assert ok("base.set", {"base": "unstable"}, user="root") == {"job_id": None}
        assert jobs() == [] or all(j["state"] != "running" for j in jobs())

    base_tree = tree_hash()

    with subtest("job_busy while one runs; cancel before activation leaves the box unchanged"):
        machine.succeed("touch /run/stub/hold")
        j1 = ok("rebuild")["job_id"]
        machine.wait_until_succeeds("grep -q build /run/stub/nix.log")
        job = ok("jobs.get", {"job_id": j1})["job"]
        assert job["state"] == "running" and job["kind"] == "rebuild", job
        assert machine.succeed(f"systemctl is-active hinteros-job@{j1}.service").strip() == "active"
        assert fails("rebuild", {}, 3005)["data"]["job_id"] == j1
        assert ok("jobs.cancel", {"job_id": j1}) == {"job_id": j1}
        done = wait_job(j1)
        assert done["state"] == "cancelled", done
        assert done["error"]["code"] == 3003 and done["error"]["message"] == "cancelled", done
        machine.wait_until_fails(f"systemctl is-active hinteros-job@{j1}.service")
        machine.fail("pgrep -f 'sleep 0.1'")  # the stub build was killed with its unit
        assert tree_hash() == base_tree and current_system() == orig and len(gens()) == 1
        machine.fail("test -e /var/lib/hinteros/staging")
        machine.succeed("rm /run/stub/hold")

    with subtest("a failing build fails the job and leaves the box unchanged"):
        machine.succeed("touch /run/stub/fail")
        j = ok("rebuild")["job_id"]
        done = wait_job(j)
        assert done["state"] == "failed" and done["error"]["code"] == 3003, done
        assert done["error"]["data"]["stage"] in ("building", "evaluating", "downloading"), done
        assert "stub.drv" in done["error"]["data"]["log_hint"], done
        assert tree_hash() == base_tree and current_system() == orig and len(gens()) == 1
        machine.fail("test -e /var/lib/hinteros/staging")
        machine.succeed("rm /run/stub/fail")

    with subtest("a rebuild that changes nothing: job events"):
        machine.succeed(f"echo {orig} > /run/stub/toplevel")
        j2 = ok("rebuild")["job_id"]
        done = wait_job(j2)
        assert done["state"] == "succeeded", done
        assert done["session_restart_required"] is False
        assert current_system() == orig and tree_hash() == base_tree
        evs = [json.loads(l) for l in machine.succeed("cat /tmp/events.ndjson").splitlines()]
        mine = [e for e in evs if e.get("params", {}).get("job_id") == j2]
        names = [e["method"] for e in mine]
        print(names)
        assert names[0] == "job_started" and mine[0]["params"]["kind"] == "rebuild", mine
        assert "job_progress" in names, names
        assert names[-1] == "job_finished" and mine[-1]["params"]["ok"] is True, mine
        machine.succeed(f"echo {variant} > /run/stub/toplevel")

    with subtest("a rebuild with a new system: a new generation, a switch that restarts the service mid-job"):
        # Only the unstable base is built for this release.
        r = fails("base.set", {"base": "stable", "acknowledge_downgrade": True}, 4001, user="root")
        assert r["data"] == {"service": "base", "reason": "not_built"}, r
        assert tree_hash() == base_tree
        # A rebuild keeps /etc/hinteros: a change of it, for the rollback below to take back.
        machine.succeed("sed -i 's/^{/{\"testMarker\":1,/' /etc/hinteros/state.json")
        pid_before = pid()
        j3 = ok("rebuild")["job_id"]
        done = wait_job(j3)
        assert done["state"] == "succeeded", done
        assert done["session_restart_required"] is False, done
        # The switch restarted hinteros-system (its unit differs) and the job survived it.
        assert pid() != pid_before, "hinteros-system was not restarted by the switch"
        machine.succeed("systemctl is-active hinteros-system.service")
        assert current_system() == variant
        machine.succeed("test -e /etc/hinteros-variant")
        g = gens()
        assert len(g) == 2 and g[0]["current"] and g[0]["generation"] == gen1 + 1, g
        assert done["result"]["generation"] == gen1 + 1, done
        machine.succeed("ls /etc/hinteros | grep -qx flake.nix")
        machine.fail("test -e /var/lib/hinteros/staging")
        # The job's events reached the listener (it reconnects after the restart).
        machine.wait_until_succeeds(f"grep -q '\"job_finished\".*{j3}\\|{j3}.*\"job_finished\"' /tmp/events.ndjson", timeout=30)
        evs = [json.loads(l) for l in machine.succeed("cat /tmp/events.ndjson").splitlines()]
        assert any(e.get("method") == "job_started" and e["params"]["job_id"] == j3 for e in evs)

    with subtest("rollback restores the previous generation and the /etc/hinteros snapshot"):
        cur = current_gen()["generation"]
        assert fails("rollback", {"generation": cur}, 3010, user="root")
        assert fails("rollback", {"generation": 99}, 3010, user="root")
        assert tree_hash() != base_tree  # still the variant's files
        pid_before = pid()
        j4 = ok("rollback", user="root")["job_id"]
        done = wait_job(j4)
        assert done["state"] == "succeeded", done
        assert pid() != pid_before, "the switch back should restart hinteros-system too"
        assert current_system() == orig
        machine.fail("test -e /etc/hinteros-variant")
        assert current_gen()["generation"] == gen1, gens()
        # /etc/hinteros is the snapshot of the generation we are back on (what config-sync does).
        for f in ("flake.nix", "flake.lock", "state.json"):
            machine.succeed(f"cmp {FIXTURE_A}/{f} /etc/hinteros/{f}")
            machine.succeed(f"cmp /run/current-system/hinteros/{f} /etc/hinteros/{f}")
        assert tree_hash() == base_tree
        assert ok("settings.get")["settings"]["base"] == "unstable"
        machine.fail("test -e /var/lib/hinteros/staging")
        machine.succeed("systemctl is-active hinteros-config-sync.service")

    with subtest("every job is in the audit trail with its outcome"):
        out = machine.succeed("journalctl -o json --no-pager HINTEROS_AUDIT=1")
        entries = [json.loads(l) for l in out.splitlines() if l.strip()]
        outcomes = [(e.get("HINTEROS_JOB_ID"), e.get("HINTEROS_OUTCOME")) for e in entries if e.get("HINTEROS_OUTCOME")]
        print(outcomes)
        assert any(j == j3 for j, _ in outcomes) and any(j == j4 for j, _ in outcomes), outcomes

    with subtest("jobs leave /var/lib/hinteros to hinteros-system"):
        # Jobs ran after the service restarted (the rebuild's switch); none took the tree back to
        # root:root, which made systemd chown all of it and race the service's file writes.
        assert machine.succeed("stat -c %U:%G /var/lib/hinteros").strip() == "root:hinteros"

    machine.succeed("pkill -f '[e]vents.py' || true")
  '';
}
