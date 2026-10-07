# The Store backend, session API 0.8 / system API 0.3, through the real chain: a client of the
# session socket (as the launcher would be) -> the session daemon's relay -> hinteros-system
# (seat0 owner, polkit `org.hinteros.system.apps` granted to the hinteros group, rate limit,
# audit) -> a job unit as root -> state.json, terms-accepted.json, the switch, and the removal of
# app data in the session user's home.
#
# STUBBED: evaluating and building the new system (see system/stub-nix.nix). `nix build` prints a
# prebuilt specialisation of the VM, so the profile generation, the real switch and /etc/hinteros
# replacement are real, but the system installed is not "with crunchyroll". The apps are checked
# in state.json, `settings.get`, and `store.list`, which read the state, not the running system.
# The catalog has no app with `depends`, so the dependent-removal refusal (app_conflict) is not
# exercised here (the daemon's unit tests cover it).
{ self, pkgs }:
let
  stubNix = import ./system/stub-nix.nix;
in
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-store-install";
  meta.timeout = 3600;

  nodes.machine =
    { config, lib, ... }:
    {
      imports = [ (import ./system/node.nix { inherit self pkgs; }) ];
      systemd.services."hinteros-job@".path = lib.mkBefore [
        (stubNix {
          inherit pkgs;
          nix = config.nix.package;
        })
      ];
      boot.loader.grub.enable = lib.mkForce false;
      virtualisation.diskSize = 4096;
      specialisation.variant.configuration.environment.etc."hinteros-variant".text = "variant\n";
    };

  testScript = ''
    import json
    import time

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("hinteros-system.service")
    machine.wait_for_unit("greetd.service")
    machine.wait_until_succeeds("loginctl list-sessions --no-legend | grep -w hinteros")
    machine.wait_until_succeeds("test -S /run/hinteros/system.sock")
    machine.wait_until_succeeds("test -S /run/user/$(id -u hinteros)/hinteros/session.sock")
    home = "/home/hinteros"

    def sess(method, params=None):
        out = machine.succeed(f"runuser -u hinteros -- python3 /etc/hinteros-test/session.py {method} '{json.dumps(params or {})}'")
        return json.loads(out)["response"]

    def ok(method, params=None):
        r = sess(method, params)
        assert "result" in r, (method, params, r)
        return r["result"]

    def fails(method, params, code):
        r = sess(method, params)
        assert "error" in r and r["error"]["code"] == code, (method, params, r)
        return r["error"]

    def sysrpc(method, params=None):
        out = machine.succeed(f"runuser -u hinteros -- python3 /etc/hinteros-test/rpc.py {method} '{json.dumps(params or {})}'")
        return json.loads(out)["response"]

    def wait_job(jid, timeout=240):
        for _ in range(timeout):
            r = sysrpc("jobs.get", {"job_id": jid})
            if "result" in r and r["result"]["job"]["state"] != "running":
                return r["result"]["job"]
            time.sleep(1)
        raise AssertionError(f"job {jid} did not finish: {r}")

    def rev():
        return ok("system.settings.get")["revision"]

    def installed():
        return ok("system.settings.get")["settings"]["apps"]

    def store():
        return {a["id"]: a for a in ok("store.list")["apps"]}

    def state():
        return json.loads(machine.succeed("cat /etc/hinteros/state.json"))

    # The launcher may start a job of its own at startup (an update check); let it finish.
    for _ in range(60):
        if not [j for j in sysrpc("jobs.list")["result"]["jobs"] if j["state"] == "running"]:
            break
        machine.sleep(1)
    machine.sleep(3)

    orig = machine.succeed("readlink -f /run/current-system").strip()
    variant = machine.succeed("readlink -f /run/current-system/specialisation/variant").strip()
    machine.succeed("mkdir -p /run/stub")
    machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {orig}")
    machine.succeed(f"echo {variant} > /run/stub/toplevel")

    with subtest("store.list shows the catalog with terms texts on this box"):
        r = ok("store.list")
        assert r["index_version"] == 2 and r["more_after_update"] is False, r
        apps = {a["id"]: a for a in r["apps"]}
        assert set(apps) == {"crunchyroll", "firefox", "jellyfin", "moonlight", "plex-htpc", "steam", "youtube"}, list(apps)
        assert all(a["state"] == "available" for a in apps.values()), apps
        t = apps["plex-htpc"]["terms"]
        assert t["version"] == "2025-10-30" and t["file"].startswith("/run/current-system/sw/share/hinteros/terms/"), t
        machine.succeed(f"test -s {t['file']}")
        assert apps["crunchyroll"]["terms"] is None and apps["crunchyroll"]["free"] is True
        # The index the daemon reads is where the system module puts it.
        machine.succeed("test -s /run/current-system/sw/share/hinteros/catalog.json")

    with subtest("hostile apps.* input is refused and nothing changes"):
        base_state = machine.succeed("cat /etc/hinteros/state.json")
        r0 = rev()
        bad_ids = [["../x"], ["/nix/store/abc-x"], ["a/b"], ["Crunchyroll"], [""], ["x" * 40], ["-rf"],
                   ["crunchyroll;id"], ["$(id)"], ["crunchyroll", "../../etc/passwd"], [5], "crunchyroll", [],
                   ["crunchyroll"] * 3 + ["a"] * 6, [f"app{i}" for i in range(1000)]]
        for ids in bad_ids:
            for m, extra in (("system.apps.install", {}), ("system.apps.remove", {"delete_data": True})):
                r = sess(m, {"ids": ids, "revision": r0, **extra})
                assert "error" in r and r["error"]["code"] == -32602, (m, str(ids)[:60], r)
        for m, extra in (("system.apps.install", {}), ("system.apps.remove", {"delete_data": True})):
            r = sess(m, {"ids": ["nope"], "revision": r0, **extra})
            assert r["error"]["code"] == 3010, r
        # Unknown fields, bad revisions, terms for apps the request does not install.
        for p in ({"ids": ["crunchyroll"], "revision": r0, "path": "/etc"},
                  {"ids": ["crunchyroll"], "revision": "../.."},
                  {"ids": ["crunchyroll"], "revision": r0, "accepted_terms": {"steam": "2026-09-10"}},
                  {"ids": ["crunchyroll"], "revision": r0, "accepted_terms": {"../x": "1"}},
                  {"ids": ["crunchyroll"], "revision": r0, "accepted_terms": {"steam": "../../x"}}):
            r = sess("system.apps.install", p)
            assert "error" in r and r["error"]["code"] == -32602, (p, r)
        # Not installed: cannot be removed.
        fails("system.apps.remove", {"ids": ["crunchyroll"], "revision": r0, "delete_data": False}, 3010)
        # A stale revision.
        fails("system.apps.install", {"ids": ["crunchyroll"], "revision": "0" * 64}, 3007)
        assert machine.succeed("cat /etc/hinteros/state.json") == base_state
        assert sysrpc("jobs.list")["result"]["jobs"] == [] or all(j["state"] != "running" for j in sysrpc("jobs.list")["result"]["jobs"])

    with subtest("a free app installs: job, state.json, settings, store.list"):
        j = ok("system.apps.install", {"ids": ["crunchyroll"], "revision": rev()})["job_id"]
        done = wait_job(j)
        assert done["state"] == "succeeded" and done["kind"] == "apps_install", done
        assert state()["apps"] == ["crunchyroll"], state()
        assert installed() == ["crunchyroll"]
        assert store()["crunchyroll"]["state"] == "installed"
        assert machine.succeed("readlink -f /run/current-system").strip() == variant
        machine.fail("test -e /var/lib/hinteros/terms-accepted.json")
        # Installing it again changes nothing and starts no job.
        assert ok("system.apps.install", {"ids": ["crunchyroll"], "revision": rev()}) == {"job_id": None}

    with subtest("an app with vendor terms needs them accepted, exactly the version"):
        for accepted in (None, {}, {"plex-htpc": "2020-01-01"}):
            p = {"ids": ["plex-htpc"], "revision": rev()}
            if accepted is not None:
                p["accepted_terms"] = accepted
            e = fails("system.apps.install", p, 3014)
            assert e["data"] == {"id": "plex-htpc", "version": "2025-10-30"}, e
        assert installed() == ["crunchyroll"]
        machine.fail("test -e /var/lib/hinteros/terms-accepted.json")
        j = ok("system.apps.install", {"ids": ["plex-htpc"], "revision": rev(), "accepted_terms": {"plex-htpc": "2025-10-30"}})["job_id"]
        done = wait_job(j)
        assert done["state"] == "succeeded", done
        assert state()["apps"] == ["crunchyroll", "plex-htpc"], state()
        # The record: root only, {id: [{version, accepted_at, by}]}.
        assert machine.succeed("stat -c '%a %U' /var/lib/hinteros/terms-accepted.json").strip() == "600 root"
        rec = json.loads(machine.succeed("cat /var/lib/hinteros/terms-accepted.json"))
        assert list(rec) == ["plex-htpc"] and len(rec["plex-htpc"]) == 1, rec
        e = rec["plex-htpc"][0]
        assert sorted(e) == ["accepted_at", "by", "version"] and e["version"] == "2025-10-30" and e["by"] == "hinteros", e
        import re
        assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ|\d{4}-\d\d-\d\dT[\d:.]+(Z|[+-]\d\d:\d\d)", e["accepted_at"]), e
        out = machine.succeed("journalctl -o json --no-pager HINTEROS_AUDIT=1")
        assert any(json.loads(l).get("HINTEROS_TERMS_ID") == "plex-htpc" for l in out.splitlines() if l.strip())

    with subtest("remove with delete_data deletes only the entry's dataPaths and never follows a symlink out"):
        machine.succeed(f"""
          set -e
          mkdir -p /var/outside /var/outside2
          echo keep > /var/outside/canary; echo keep > /var/outside2/canary; echo keep > /var/canary-file
          h={home}
          mkdir -p $h/.local/share/hinteros/firefox/crunchyroll/sub $h/.local/share/hinteros/firefox/youtube $h/.local/share/plex-htpc $h/.config
          echo x > $h/.local/share/hinteros/firefox/crunchyroll/a
          echo x > $h/.local/share/hinteros/firefox/crunchyroll/sub/b
          ln -s /var/outside $h/.local/share/hinteros/firefox/crunchyroll/escape
          ln -s /var/canary-file $h/.local/share/hinteros/firefox/crunchyroll/escape-file
          echo x > $h/.local/share/hinteros/firefox/youtube/keep
          echo x > $h/.local/share/plex-htpc/x
          ln -s /var/outside2 $h/.config/plex-htpc
          echo keep > $h/keep.txt
          chown -R hinteros: $h
        """)
        j = ok("system.apps.remove", {"ids": ["crunchyroll"], "revision": rev(), "delete_data": True})["job_id"]
        done = wait_job(j)
        assert done["state"] == "succeeded" and done["kind"] == "apps_remove", done
        assert state()["apps"] == ["plex-htpc"], state()
        machine.fail(f"test -e {home}/.local/share/hinteros/firefox/crunchyroll")
        machine.succeed(f"test -f {home}/.local/share/hinteros/firefox/youtube/keep && test -f {home}/keep.txt")
        machine.succeed("test \"$(cat /var/outside/canary)\" = keep && test \"$(cat /var/canary-file)\" = keep")
        # plex-htpc: its data path .config/plex-htpc is itself a symlink out; the link goes, not the target.
        j = ok("system.apps.remove", {"ids": ["plex-htpc"], "revision": rev(), "delete_data": True})["job_id"]
        done = wait_job(j)
        assert done["state"] == "succeeded", done
        assert state()["apps"] == [], state()
        machine.fail(f"test -e {home}/.local/share/plex-htpc")
        machine.fail(f"test -L {home}/.config/plex-htpc")
        machine.succeed("test \"$(cat /var/outside2/canary)\" = keep")
        machine.succeed(f"test -f {home}/keep.txt")
        assert store()["plex-htpc"]["state"] == "available"
        out = machine.succeed("journalctl -u 'hinteros-job@*' --no-pager")
        assert "deleted app data" in out, out[-1500:]

    with subtest("remove without delete_data keeps the data"):
        j = ok("system.apps.install", {"ids": ["firefox"], "revision": rev()})["job_id"]
        assert wait_job(j)["state"] == "succeeded"
        machine.succeed(f"mkdir -p {home}/.local/share/hinteros/firefox/firefox && echo x > {home}/.local/share/hinteros/firefox/firefox/m && chown -R hinteros: {home}/.local")
        j = ok("system.apps.remove", {"ids": ["firefox"], "revision": rev(), "delete_data": False})["job_id"]
        assert wait_job(j)["state"] == "succeeded"
        assert state()["apps"] == []
        machine.succeed(f"test -f {home}/.local/share/hinteros/firefox/firefox/m")

    with subtest("the session user cannot get the installer's rights another way: ssh stays admin-only"):
        r = sysrpc("ssh.set", {"enabled": True})
        assert r["error"]["code"] == 3012, r
  '';
}
