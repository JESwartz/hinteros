# The Store backend per profile (session API 0.18 / system API 0.10, apps.md), through the real
# chain: a client of the session socket (as the launcher would be) -> the session daemon's relay
# -> hinteros-system (seat0 owner, polkit `org.hinteros.system.apps` granted to the hinteros group,
# audit) -> a job unit as root -> p1's Nix profile, terms-accepted.json, the removal of app data
# in p1's home. Apps are per profile: no install touches state.json or the system generation.
#
# STUBBED (system/stub-nix-envs.nix): building envs. Each id set this test reaches has a small
# env with just its manifest (ids, no app entries), prebuilt with the VM; the stub answers the
# job's `nix eval`/`nix build` from that table. Setting the profile (nix-env), publishing, the
# registry, terms and data removal are real. Real envs: profile-apps.
{ self, pkgs }:
let
  inherit (pkgs) lib;
  stubNix = import ./system/stub-nix-envs.nix;
  fixture = ./fixtures/profile-apps;
  idSets = [
    [ ]
    [ "crunchyroll" ]
    [
      "crunchyroll"
      "plex-htpc"
    ]
    [ "plex-htpc" ]
    [ "firefox" ]
  ];
  key = lib.concatStringsSep ",";
  # An env with only its manifest (DECISIONS D3).
  envOf =
    ids:
    pkgs.writeTextDir "share/hinteros/apps.json" (
      builtins.toJSON {
        version = 1;
        system_rev = null;
        inherit ids;
        apps = [ ];
        steam = null;
        box = [ ];
      }
    );
  envs = lib.listToAttrs (
    map (
      ids:
      lib.nameValuePair (key ids) {
        # Only its name: the stub answers from this table.
        drv = builtins.unsafeDiscardStringContext (envOf ids).drvPath;
        out = (envOf ids).outPath;
      }
    ) idSets
  );
in
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-store-install";
  meta.timeout = 3600;

  nodes.machine =
    { config, lib, ... }:
    {
      imports = [ (import ./system/node.nix { inherit self pkgs; }) ];
      hinteros = {
        state = builtins.fromJSON (builtins.readFile (fixture + "/state.json"));
        deviceConfig.configDir = lib.mkForce fixture;
        # The Store, not the picker: autologin of p1.
        profiles.greeter.enable = false;
      };
      systemd.tmpfiles.settings."10-hinteros-config"."/etc/hinteros".C.argument = lib.mkForce "${
        fixture
      }";
      systemd.services."hinteros-job@".path = lib.mkBefore [
        (stubNix {
          inherit pkgs envs;
          nix = config.nix.package;
        })
      ];
      system.extraDependencies = map envOf idSets;
      environment.etc."hinteros-envs.json".text = builtins.toJSON envs;
      boot.loader.grub.enable = lib.mkForce false;
      virtualisation.diskSize = 4096;
    };

  testScript = ''
    import json
    import re
    import time

    envs = json.loads(machine.succeed("cat /etc/hinteros-envs.json"))
    P = "/nix/var/nix/profiles/hinteros/apps/hinteros-p1"
    home = "/home/hinteros-p1"
    ENV = "HINTEROS_SYSTEM_API=1.0 HINTEROS_SESSION_API=1.0"

    machine.succeed("mkdir -p /run/stub")
    machine.wait_for_unit("multi-user.target")
    # p1 as a profile (without metadata it is a spare in first-boot mode), unlocked, admin.
    machine.succeed("""
      install -d -m 0700 /var/lib/hinteros
      now=$(date +%s)
      printf '{"version":1,"next":2,"profiles":{"p1":{"name":"Test","color":"teal","admin":true,"locked":false,"created_at":%s,"last_used_at":null,"appearance":{"text_scale":1.0,"high_contrast":false,"reduce_motion":false}}}}' "$now" > /var/lib/hinteros/profiles.json
      chmod 0600 /var/lib/hinteros/profiles.json
    """)
    machine.succeed("systemctl restart hinteros-system.service")
    machine.wait_for_unit("hinteros-system.service")
    machine.wait_until_succeeds("test -S /run/hinteros/system.sock")
    machine.wait_until_succeeds("test -S /run/user/$(id -u hinteros-p1)/hinteros/session.sock")
    system = machine.succeed("readlink -f /run/current-system").strip()
    base_state = machine.succeed("cat /etc/hinteros/state.json")

    def sess(method, params=None):
        out = machine.succeed(f"runuser -u hinteros-p1 -- env {ENV} python3 /etc/hinteros-test/session.py {method} '{json.dumps(params or {})}'")
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
        out = machine.succeed(f"runuser -u hinteros-p1 -- env {ENV} python3 /etc/hinteros-test/rpc.py {method} '{json.dumps(params or {})}'")
        return json.loads(out)["response"]

    def wait_job(jid, timeout=240):
        for _ in range(timeout):
            r = sysrpc("jobs.get", {"job_id": jid})
            if "result" in r and r["result"]["job"]["state"] != "running":
                return r["result"]["job"]
            time.sleep(1)
        raise AssertionError(f"job {jid} did not finish: {r}")

    def mine():
        return ok("system.apps.list")

    def rev():
        return mine()["revision"]

    def installed():
        return mine()["ids"]

    def store():
        return {a["id"]: a for a in ok("store.list")["apps"]}

    def unchanged_box():
        # Per-profile apps never touch state.json or the system.
        assert machine.succeed("cat /etc/hinteros/state.json") == base_state
        assert machine.succeed("readlink -f /run/current-system").strip() == system

    def env_is(key):
        assert machine.succeed(f"readlink -f {P}").strip() == envs[key]["out"], (key, machine.succeed(f"readlink -f {P}"))

    # The launcher may start a job of its own at startup (an update check); let it finish.
    for _ in range(60):
        if not [j for j in sysrpc("jobs.list")["result"]["jobs"] if j["state"] == "running"]:
            break
        machine.sleep(1)
    machine.sleep(3)

    with subtest("no Steam tile while this profile has no Steam"):
        ids = [a["id"] for a in ok("apps.list")["apps"]]
        assert "steam" not in ids, ids

    with subtest("store.list: the catalog for this profile, services hidden, terms texts on this box"):
        r = ok("store.list")
        assert r["index_version"] == 4 and r["more_after_update"] is False, r
        apps = {a["id"]: a for a in r["apps"]}
        assert {"crunchyroll", "firefox", "jellyfin-desktop", "moonlight", "plex-htpc", "steam", "youtube"} <= set(apps), list(apps)
        assert "jellyfin-server" not in apps, "a service in the Store"
        assert all(a["state"] == "available" for a in apps.values()), apps
        t = apps["plex-htpc"]["terms"]
        assert t["version"] == "2025-10-30" and t["file"].startswith("/run/current-system/sw/share/hinteros/terms/"), t
        machine.succeed(f"test -s {t['file']}")
        assert apps["crunchyroll"]["terms"] is None and apps["crunchyroll"]["unfree"] is False
        machine.succeed("test -s /run/current-system/sw/share/hinteros/catalog.json")

    with subtest("hostile apps.* input is refused and nothing changes"):
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
        for p in ({"ids": ["crunchyroll"], "revision": r0, "path": "/etc"},
                  {"ids": ["crunchyroll"], "revision": "../.."},
                  {"ids": ["crunchyroll"], "revision": r0, "accepted_terms": {"steam": "2026-09-10"}},
                  {"ids": ["crunchyroll"], "revision": r0, "accepted_terms": {"../x": "1"}},
                  {"ids": ["crunchyroll"], "revision": r0, "accepted_terms": {"steam": "../../x"}}):
            r = sess("system.apps.install", p)
            assert "error" in r and r["error"]["code"] == -32602, (p, r)
        # Not installed: cannot be removed. A stale revision.
        fails("system.apps.remove", {"ids": ["crunchyroll"], "revision": r0, "delete_data": False}, 3010)
        fails("system.apps.install", {"ids": ["crunchyroll"], "revision": "0" * 64}, 3007)
        unchanged_box()
        machine.fail(f"test -e {P}")
        assert all(j["state"] != "running" for j in sysrpc("jobs.list")["result"]["jobs"])

    with subtest("a free app installs into this profile: job, its env, apps.list, store.list"):
        j = ok("system.apps.install", {"ids": ["crunchyroll"], "revision": rev()})["job_id"]
        done = wait_job(j)
        assert done["state"] == "succeeded" and done["kind"] == "apps_install", done
        env_is("crunchyroll")
        assert installed() == ["crunchyroll"]
        assert store()["crunchyroll"]["state"] == "installed"
        unchanged_box()
        machine.fail("test -e /var/lib/hinteros/terms-accepted.json")
        # Installing it again changes nothing and starts no job.
        assert ok("system.apps.install", {"ids": ["crunchyroll"], "revision": rev()}) == {"job_id": None}

    with subtest("an app with vendor terms needs them accepted, exactly the version, recorded for this profile"):
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
        env_is("crunchyroll,plex-htpc")
        assert installed() == ["crunchyroll", "plex-htpc"]
        unchanged_box()
        # The record: root only, {id: [{version, accepted_at, by, profile}]}.
        assert machine.succeed("stat -c '%a %U' /var/lib/hinteros/terms-accepted.json").strip() == "600 hinteros-system"
        rec = json.loads(machine.succeed("cat /var/lib/hinteros/terms-accepted.json"))["accepted"]
        assert list(rec) == ["plex-htpc"] and len(rec["plex-htpc"]) == 1, rec
        e = rec["plex-htpc"][0]
        assert sorted(e) == ["accepted_at", "by", "profile", "version"], e
        assert e["version"] == "2025-10-30" and e["by"] == "hinteros-p1" and e["profile"] == "p1", e
        assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ|\d{4}-\d\d-\d\dT[\d:.]+(Z|[+-]\d\d:\d\d)", e["accepted_at"]), e
        out = machine.succeed("journalctl -o json --no-pager HINTEROS_AUDIT=1")
        assert any(json.loads(l).get("HINTEROS_TERMS_ID") == "plex-htpc" for l in out.splitlines() if l.strip())

    with subtest("remove with delete_data deletes only the entry's dataPaths in this home, never through a symlink"):
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
          chown -R hinteros-p1: $h
        """)
        j = ok("system.apps.remove", {"ids": ["crunchyroll"], "revision": rev(), "delete_data": True})["job_id"]
        done = wait_job(j)
        assert done["state"] == "succeeded" and done["kind"] == "apps_remove", done
        env_is("plex-htpc")
        assert installed() == ["plex-htpc"]
        machine.fail(f"test -e {home}/.local/share/hinteros/firefox/crunchyroll")
        machine.succeed(f"test -f {home}/.local/share/hinteros/firefox/youtube/keep && test -f {home}/keep.txt")
        machine.succeed("test \"$(cat /var/outside/canary)\" = keep && test \"$(cat /var/canary-file)\" = keep")
        # plex-htpc: its data path .config/plex-htpc is itself a symlink out; the link goes, not the target.
        j = ok("system.apps.remove", {"ids": ["plex-htpc"], "revision": rev(), "delete_data": True})["job_id"]
        done = wait_job(j)
        assert done["state"] == "succeeded", done
        env_is("")
        assert installed() == []
        machine.fail(f"test -e {home}/.local/share/plex-htpc")
        machine.fail(f"test -L {home}/.config/plex-htpc")
        machine.succeed("test \"$(cat /var/outside2/canary)\" = keep")
        machine.succeed(f"test -f {home}/keep.txt")
        assert store()["plex-htpc"]["state"] == "available"
        unchanged_box()

    with subtest("remove without delete_data keeps the data"):
        j = ok("system.apps.install", {"ids": ["firefox"], "revision": rev()})["job_id"]
        assert wait_job(j)["state"] == "succeeded"
        env_is("firefox")
        machine.succeed(f"mkdir -p {home}/.local/share/hinteros/firefox/firefox && echo x > {home}/.local/share/hinteros/firefox/firefox/m && chown -R hinteros-p1: {home}/.local")
        j = ok("system.apps.remove", {"ids": ["firefox"], "revision": rev(), "delete_data": False})["job_id"]
        assert wait_job(j)["state"] == "succeeded"
        assert installed() == []
        machine.succeed(f"test -f {home}/.local/share/hinteros/firefox/firefox/m")

    with subtest("the profile cannot get the installer's rights another way: ssh stays admin-only"):
        r = sysrpc("ssh.set", {"enabled": True})
        assert r["error"]["code"] == 3012, r
  '';
}
