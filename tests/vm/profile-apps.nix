# Per-profile apps through the real chain (VM `profile-apps`, single
# user): a launcher-like client of the session socket (API 0.18) -> the session daemon's relay ->
# hinteros-system (0.5) -> a job unit -> the profile's Nix profile -> the published link -> the
# session daemon's apps.list. Install Moonlight into p1 with no new system generation, roll back,
# remove with delete_data. NEEDS the M7 daemon.
#
# STUBBED: evaluating and building envs (system/stub-nix-envs.nix): the envs this test uses are
# built with the VM (config.hinteros.appEnv.build), the stub answers the job's `nix eval`/`nix
# build` from that table. Setting the profile (nix-env), publishing, the registry and the session
# daemon's reload are real.
{ self, pkgs }:
let
  stubNix = import ./system/stub-nix-envs.nix;
  fixture = ./fixtures/profile-apps;
in
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-profile-apps";
  meta.timeout = 3600;

  nodes.machine =
    { config, lib, ... }:
    let
      idSets = [
        [
          "firefox"
          "youtube"
        ]
        [
          "firefox"
          "moonlight"
          "youtube"
        ]
      ];
      envs = lib.listToAttrs (
        map (
          ids:
          let
            e = config.hinteros.appEnv.build ids;
          in
          lib.nameValuePair (lib.concatStringsSep "," ids) {
            # Only its name: the stub answers from the table, and a .drv in the closure would
            # need every source it was built from.
            drv = builtins.unsafeDiscardStringContext e.drvPath;
            out = e.outPath;
          }
        ) idSets
      );
    in
    {
      imports = [ (import ./system/node.nix { inherit self pkgs; }) ];
      hinteros = {
        state = builtins.fromJSON (builtins.readFile (fixture + "/state.json"));
        deviceConfig.configDir = lib.mkForce fixture;
        # Kiosk apps open local pages (nothing here launches them, but keep them offline).
        appEnv.overrides.youtube.kiosk.url = "file:///etc/hinteros-pages/youtube.html";
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
      system.extraDependencies = map (ids: config.hinteros.appEnv.build ids) idSets;
      environment.etc."hinteros-envs.json".text = builtins.toJSON envs;
      boot.loader.grub.enable = lib.mkForce false;
      virtualisation.diskSize = 4096;
      # Apps, not the picker: autologin of p1 (greeter mode: profiles-greeter).
      hinteros.profiles.greeter.enable = false;
      virtualisation.memorySize = lib.mkForce 3072;
    };

  testScript = ''
    import json
    import time

    envs = json.loads(machine.succeed("cat /etc/hinteros-envs.json"))
    P = "/nix/var/nix/profiles/hinteros/apps/hinteros-p1"
    home = "/home/hinteros-p1"
    ENV = "HINTEROS_SYSTEM_API=1.0 HINTEROS_SESSION_API=1.0"

    machine.succeed("mkdir -p /run/stub")
    machine.wait_for_unit("multi-user.target")
    # p1 as a profile (it is a spare without metadata), unlocked, admin; its apps the starter env.
    machine.succeed("""
      install -d -m 0700 /var/lib/hinteros
      now=$(date +%s)
      printf '{"version":1,"next":2,"profiles":{"p1":{"name":"Test","color":"teal","admin":true,"locked":false,"created_at":%s,"last_used_at":null,"appearance":{"text_scale":1.0,"high_contrast":false,"reduce_motion":false}}}}' "$now" > /var/lib/hinteros/profiles.json
      chmod 0600 /var/lib/hinteros/profiles.json
      # The service's file (it is not root), as if it had written it.
      chown -R hinteros-system:hinteros /var/lib/hinteros
    """)
    machine.succeed(f"nix-env -p {P} --set {envs['firefox,youtube']['out']}")
    machine.succeed("systemctl restart hinteros-system.service")
    machine.wait_for_unit("hinteros-system.service")
    machine.wait_until_succeeds("test -L /run/hinteros/apps/hinteros-p1")
    machine.wait_until_succeeds("test -S /run/user/$(id -u hinteros-p1)/hinteros/session.sock")
    system_gen = machine.succeed("readlink -f /run/current-system").strip()

    def sess(method, params=None):
        # Early on the session start may restart a daemon that came up before the compositor
        # (session.nix, try-restart): its socket goes away for a moment, and the client fails
        # to connect. Only that is tried again; every answer counts.
        cmd = f"runuser -u hinteros-p1 -- env {ENV} python3 /etc/hinteros-test/session.py {method} '{json.dumps(params or {})}'"
        for _ in range(30):
            status, out = machine.execute(cmd)
            if status == 0:
                return json.loads(out)["response"]
            time.sleep(1)
        return json.loads(machine.succeed(cmd))["response"]

    def job(method, params):
        # The launcher's update check at session start is a job of its own and may run at any
        # moment (job_busy, 3005, while it runs): wait for it, then start ours.
        for _ in range(5):
            r = sess(method, params)
            if r.get("error", {}).get("code") != 3005:
                break
            wait_job(r["error"]["data"]["job_id"])
        assert "result" in r, (method, params, r)
        return r["result"]["job_id"]

    def ok(method, params=None):
        r = sess(method, params)
        assert "result" in r, (method, params, r)
        return r["result"]

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

    def app_ids():
        return sorted(a["id"] for a in ok("apps.list")["apps"])

    def mine():
        return ok("system.apps.list")

    def gens():
        return machine.succeed(f"nix-env -p {P} --list-generations").strip().splitlines()

    with subtest("the profile's env is what the session lists"):
        machine.wait_until_succeeds("test -e /run/hinteros/apps/hinteros-p1/share/hinteros/apps.json")
        for _ in range(30):
            if {"firefox", "youtube"} <= set(app_ids()):
                break
            time.sleep(1)
        assert {"firefox", "youtube"} <= set(app_ids()), app_ids()
        assert "moonlight" not in app_ids()
        m = mine()
        assert m["ids"] == ["firefox", "youtube"], m

    with subtest("install Moonlight: a new generation of p1's profile, no new system generation"):
        j = job("system.apps.install", {"ids": ["moonlight"], "revision": mine()["revision"]})
        done = wait_job(j)
        assert done["state"] == "succeeded" and done["kind"] == "apps_install", done
        assert machine.succeed(f"readlink -f {P}").strip() == envs["firefox,moonlight,youtube"]["out"]
        assert len(gens()) == 2, gens()
        assert machine.succeed("readlink -f /run/current-system").strip() == system_gen
        for _ in range(10):
            if "moonlight" in app_ids():
                break
            time.sleep(1)
        assert "moonlight" in app_ids(), app_ids()
        assert mine()["ids"] == ["firefox", "moonlight", "youtube"]
        reg = json.loads(machine.succeed("cat /var/lib/hinteros/apps/registry.json"))
        assert reg["owners"]["p1"]["ids"] == ["firefox", "moonlight", "youtube"], reg

    with subtest("roll back to the generation before the install"):
        g = ok("system.apps.generations")["generations"]
        assert len(g) == 2, g
        old = next(x for x in g if not x["current"])
        done = wait_job(job("system.apps.rollback", {"generation": old["generation"]}))
        assert done["state"] == "succeeded", done
        assert machine.succeed(f"readlink -f {P}").strip() == envs["firefox,youtube"]["out"]
        for _ in range(10):
            if "moonlight" not in app_ids():
                break
            time.sleep(1)
        assert "moonlight" not in app_ids(), app_ids()
        assert machine.succeed("readlink -f /run/current-system").strip() == system_gen

    with subtest("remove with delete_data: the app's dataPaths in this home only"):
        done = wait_job(job("system.apps.install", {"ids": ["moonlight"], "revision": mine()["revision"]}))
        assert done["state"] == "succeeded", done
        machine.succeed(f"""
          set -e
          d='{home}/.config/Moonlight Game Streaming Project'
          mkdir -p "$d" {home}/.config/other
          echo x > "$d/settings.conf"; echo keep > {home}/.config/other/keep
          chown -R hinteros-p1: {home}/.config
        """)
        done = wait_job(job("system.apps.remove", {"ids": ["moonlight"], "revision": mine()["revision"], "delete_data": True}))
        assert done["state"] == "succeeded" and done["kind"] == "apps_remove", done
        machine.fail(f"test -e '{home}/.config/Moonlight Game Streaming Project'")
        machine.succeed(f"test -e {home}/.config/other/keep")
        assert mine()["ids"] == ["firefox", "youtube"]
        assert machine.succeed("readlink -f /run/current-system").strip() == system_gen
  '';
}
