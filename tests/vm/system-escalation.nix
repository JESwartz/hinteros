# The privileged service against hostile input. As the session user (so, as any game or web page
# running as it), a script talks to /run/hinteros/system.sock directly, not through the session
# daemon, with unknown fields, forged identities, paths and URLs, wrong types, bad framing, non-UTF-8,
# oversize messages and a connection flood. Every request must be refused, the service must stay
# up (same process, no restart), /etc/hinteros must be untouched, no job unit may have started, and
# the sandbox of the service and its job template must be what the module promises. The service
# is not root: its account has no capabilities and may start only its own units over D-Bus.
{ self, pkgs }:
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-system-escalation";

  nodes.machine = import ./system/node.nix {
    inherit self pkgs;
    rateLimits = true;
  };

  testScript = ''
    import json

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("hinteros-system.service")
    machine.wait_for_unit("greetd.service")
    machine.wait_until_succeeds("loginctl list-sessions --no-legend | grep -w hinteros-p1")
    machine.wait_until_succeeds("test -S /run/hinteros/system.sock")

    def pid():
        return machine.succeed("systemctl show -p MainPID --value hinteros-system.service").strip()

    def tree_hash():
        return machine.succeed("cd /etc/hinteros && find . -type f | sort | xargs sha256sum | sha256sum && stat -c '%n %a %U %Y' /etc/hinteros").strip()

    def rpc(user, method, params=None):
        out = machine.succeed(f"runuser -u {user} -- python3 /etc/hinteros-test/rpc.py {method} '{json.dumps(params or {})}'")
        return json.loads(out)

    with subtest("the sandbox the module promises"):
        show = machine.succeed("systemctl show hinteros-system.service -p ProtectSystem -p RuntimeDirectoryPreserve -p MemoryDenyWriteExecute -p ReadWritePaths -p RestrictAddressFamilies -p NoNewPrivileges -p StateDirectory")
        print(show)
        for want in ("ProtectSystem=strict", "RuntimeDirectoryPreserve=yes", "MemoryDenyWriteExecute=yes",
                     "NoNewPrivileges=yes", "RestrictAddressFamilies=AF_UNIX", "StateDirectory=hinteros",
                     "ReadWritePaths=/run/hinteros"):
            assert want in show, (want, show)
        # Really read-only: even root in its mount namespace cannot write /etc.
        mp = pid()
        machine.fail(f"nsenter -m -t {mp} -- touch /etc/hinteros-write-test")
        machine.fail(f"nsenter -m -t {mp} -- touch /nix/var/write-test")
        machine.fail(f"nsenter -m -t {mp} -- touch /etc/hinteros/write-test")
        machine.fail(f"nsenter -m -t {mp} -- touch /nix/store/write-test")
        machine.fail(f"nsenter -m -t {mp} -- touch /usr/write-test")
        machine.succeed(f"nsenter -m -t {mp} -- test -d /run/hinteros")
        assert machine.succeed("stat -c '%a %U' /var/lib/hinteros").strip() == "700 hinteros-system"
        assert machine.succeed("stat -c '%a %U:%G' /etc/hinteros").strip() == "755 root:root"
        # The template: root, no ProtectSystem, never restarted by a switch.
        unit = machine.succeed("systemctl cat 'hinteros-job@.service'")
        print(unit)
        assert "ExecStart=" in unit and " job %i" in unit and "X-RestartIfChanged=false" in unit and "X-StopIfChanged=false" in unit, unit
        assert "ProtectSystem" not in unit and "User=root" in unit
        assert machine.succeed("systemctl show 'hinteros-job@x.service' -p Nice --value").strip() == "10"
        # The time zone helper (time_zone.set): the only HinterOS unit besides jobs that writes
        # /etc, and only /etc/hinteros (timedated replaces /etc/localtime); no network, started
        # on demand only.
        show = machine.succeed("systemctl show hinteros-time-zone-apply.service -p ProtectSystem -p ReadWritePaths -p PrivateNetwork -p NoNewPrivileges -p Type -p WantedBy")
        print(show)
        for want in ("ProtectSystem=strict", "PrivateNetwork=yes", "NoNewPrivileges=yes", "Type=oneshot", "WantedBy=\n"):
            assert want in show, (want, show)
        rw = next(l for l in show.splitlines() if l.startswith("ReadWritePaths=")).split("=", 1)[1].split()
        assert sorted(rw) == ["/etc/hinteros", "/run/hinteros"], rw

    with subtest("not root: its own account, no capabilities, only its own units on the bus"):
        # A bug in the request path is the hinteros-system account's, not root's.
        mp = pid()
        assert machine.succeed(f"stat -c %U /proc/{mp}").strip() == "hinteros-system"
        status = machine.succeed(f"cat /proc/{mp}/status")
        for cap in ("CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb"):
            line = next(l for l in status.splitlines() if l.startswith(cap + ":"))
            assert int(line.split()[1], 16) == 0, line
        show = machine.succeed("systemctl show hinteros-system.service -p User -p CapabilityBoundingSet -p AmbientCapabilities")
        print(show)
        assert "User=hinteros-system" in show and "CapabilityBoundingSet=\n" in show, show
        # As that account on the system bus: an arbitrary transient unit is refused (as root it
        # would run anything), and so are other units and verbs; its own helper units start.
        bus = "runuser -u hinteros-system -- busctl call org.freedesktop.systemd1 /org/freedesktop/systemd1 org.freedesktop.systemd1.Manager"
        out = machine.fail(
            f"{bus} StartTransientUnit 'ssa(sv)a(sa(sv))' hinteros-evil.service fail "
            "1 ExecStart 'a(sasb)' 1 /run/current-system/sw/bin/touch 2 touch /root/pwned false 0 2>&1"
        )
        print(out)
        assert "denied" in out.lower() or "authentication" in out.lower(), out
        machine.fail("test -e /root/pwned")
        # Also with a name the rule allows for StartUnit or FreezeUnit: polkit says no (not only
        # systemd's "has a fragment file"). A transient slice of a profile uid has no fragment and
        # would pull in a transient root service.
        for name in ("hinteros-job@0123456789abcdef.service", "hinteros-usage.service", "hinteros-time-zone-apply.service"):
            out = machine.fail(
                f"{bus} StartTransientUnit 'ssa(sv)a(sa(sv))' {name} fail "
                "1 ExecStart 'a(sasb)' 1 /run/current-system/sw/bin/touch 2 touch /root/pwned false 0 2>&1"
            )
            print(name, out)
            assert "denied" in out.lower(), out
            machine.fail("test -e /root/pwned")
        out = machine.fail(
            f"{bus} StartTransientUnit 'ssa(sv)a(sa(sv))' user-20099.slice fail "
            "1 Wants as 1 hinteros-evil.service "
            "1 hinteros-evil.service 1 ExecStart 'a(sasb)' 1 /run/current-system/sw/bin/touch 2 touch /root/pwned false 2>&1"
        )
        print(out)
        assert "denied" in out.lower(), out
        machine.fail("test -e /root/pwned")
        # A profile's slice: freeze and thaw, not stop (that would end the session).
        p1 = machine.succeed("id -u hinteros-p1").strip()
        out = machine.fail(f"{bus} StopUnit ss user-{p1}.slice replace 2>&1")
        assert "denied" in out.lower(), out
        machine.fail(f"{bus} StartUnit ss user-{p1}.slice replace")
        machine.succeed(f"{bus} FreezeUnit s user-{p1}.slice")
        machine.succeed(f"{bus} ThawUnit s user-{p1}.slice")
        assert machine.succeed(f"systemctl show -p FreezerState --value user-{p1}.slice").strip() == "running"
        machine.wait_until_succeeds("loginctl list-sessions --no-legend | grep -w hinteros-p1")
        machine.fail(f"{bus} StartUnit ss systemd-tmpfiles-clean.service replace")
        machine.fail(f"{bus} StartUnit ss hinteros-job@not-a-job.service replace")
        machine.fail(f"{bus} StopUnit ss greetd.service replace")
        machine.fail(f"{bus} KillUnit ssi greetd.service all 9")
        machine.succeed(f"{bus} StartUnit ss hinteros-usage.service replace")
        machine.wait_until_succeeds("test -s /var/lib/hinteros/usage.json")
        assert machine.succeed("stat -c %U /var/lib/hinteros/usage.json").strip() == "hinteros-system"
        machine.succeed("systemctl is-active greetd.service")
        # Nothing else polkit guards either, even what anyone may (delaying sleep here).
        machine.fail("runuser -u hinteros-system -- sh -c 'exec pkcheck --action-id org.freedesktop.login1.inhibit-delay-sleep --process $$'")

    def jobs():
        return rpc("hinteros-p1", "jobs.list")["response"]["result"]["jobs"]

    # The launcher (a client of the same uid, via the session daemon) may start a job of its own
    # at startup (an update check); let it finish and take the baseline afterwards.
    for _ in range(60):
        if not [j for j in rpc("hinteros-p1", "jobs.list")["response"]["result"]["jobs"] if j["state"] == "running"]:
            break
        machine.sleep(1)
    machine.sleep(5)
    baseline_jobs = sorted(j["job_id"] for j in jobs())
    print("baseline jobs", baseline_jobs)
    before_pid = pid()
    before_tree = tree_hash()

    with subtest("hostile input at the socket, as the session user"):
        out = machine.succeed("runuser -u hinteros-p1 -- python3 /etc/hinteros-test/hostile.py 2>&1")
        print(out)
        assert out.rstrip().endswith("hostile: all refused, service alive")

    def assert_untouched():
        assert pid() == before_pid, "hinteros-system was restarted"
        machine.succeed("systemctl is-active hinteros-system.service")
        assert tree_hash() == before_tree, "/etc/hinteros changed"
        assert sorted(j["job_id"] for j in jobs()) == baseline_jobs, "a job was started"
        # No job unit other than the baseline's, no staging copy.
        started = machine.succeed("systemctl list-units --all --plain --no-legend 'hinteros-job@*' | awk '{print $1}'").split()
        assert all(s.split("@")[1].split(".")[0] in baseline_jobs for s in started), started
        machine.fail("test -e /var/lib/hinteros-root/staging")
        assert "panicked" not in machine.succeed("journalctl -u hinteros-system.service --no-pager")

    with subtest("the service stayed up and nothing changed"):
        assert_untouched()
        assert rpc("hinteros-p1", "system.info")["response"]["result"]["dev"] is False

    with subtest("rate limiting: a burst of mutating requests is cut off"):
        # Valid in shape, unknown job: not_found when let through, rate_limited when not.
        codes = [rpc("hinteros-p1", "jobs.cancel", {"job_id": "0123456789abcdef"})["response"]["error"]["code"] for _ in range(15)]
        print(codes)
        assert 3006 in codes and 3010 in codes, codes
        assert set(codes) <= {3006, 3010}, codes
        r = rpc("hinteros-p1", "jobs.cancel", {"job_id": "0123456789abcdef"})["response"]
        # Reads are never rate limited.
        assert "result" in rpc("hinteros-p1", "settings.get")["response"]
        assert_untouched()

    with subtest("the audit trail has the refusals, and the session user cannot read it"):
        out = machine.succeed("journalctl -o json --no-pager HINTEROS_AUDIT=1")
        entries = [json.loads(l) for l in out.splitlines() if l.strip()]
        decisions = {e.get("HINTEROS_DECISION") for e in entries}
        print(decisions)
        # Denials are capped per minute and uid (then summarised), so the rate_limited ones may be
        # folded into the summary after the hostile run; the invalid ones and the allowed (none here
        # were mutating) ones must be there.
        print([e["MESSAGE"] for e in entries if e.get("HINTEROS_DECISION") is None][:3])
        assert "invalid" in decisions, decisions
        assert all(e.get("HINTEROS_UID") for e in entries)
        # The caller's executable: its exe is another user's (no CAP_SYS_PTRACE), so its name.
        assert any("python3" in e.get("HINTEROS_EXE", "") for e in entries), entries[-3:]
        machine.fail("runuser -u hinteros-p1 -- journalctl --system HINTEROS_AUDIT=1 -q | grep -q HINTEROS")
  '';
}
