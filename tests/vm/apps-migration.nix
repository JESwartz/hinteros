# The v1 -> v2 migration (apps.md, "The v1 -> v2 migration"; VM `apps-migration`): a schema-1
# box with box-wide apps (jellyfin, youtube, firefox; Steam is the fake one) runs the M7 system.
# hinteros-system queues `migrate_apps` by itself (DECISIONS D11): p1's Nix profile and the starter
# env are set to the env of the box's apps, the registry is written, state.json becomes schema 2
# (no apps, requirements = the envs' box features, profiles {id, user}) and the apply flow switches
# to it. Afterwards `[[apps]]` is gone from session.toml, the session daemon reads p1's manifest,
# and the app list (ids and commands, i.e. the same store paths) is what it was. NEEDS the M7
# daemon.
#
# STUBBED (system/stub-nix-envs.nix): the env evaluation and build (the env is built with the VM)
# and the system build, which prints the `migrated` specialisation: this same system with the
# schema-2 state the migration writes. The profile links, the registry, state.json, the switch
# and the session daemon's reload are real. Not covered here: a system rollback to before the
# migration (schema-1 behaviour again) and the session restart's pids.
{ self, pkgs }:
let
  stubNix = import ./system/stub-nix-envs.nix;
  v1 = ./fixtures/apps-migration;
  v2 = ./fixtures/apps-migration-v2;
  ids = [
    "firefox"
    "jellyfin"
    "youtube"
  ];
in
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-apps-migration";
  meta.timeout = 3600;

  nodes.machine =
    { config, lib, ... }:
    let
      env = config.hinteros.appEnv.build ids;
      envs.${lib.concatStringsSep "," ids} = {
        # Only its name (see profile-apps.nix).
        drv = builtins.unsafeDiscardStringContext env.drvPath;
        out = env.outPath;
      };
      stateOf = dir: builtins.fromJSON (builtins.readFile (dir + "/state.json"));
    in
    {
      imports = [ (import ./system/node.nix { inherit self pkgs; }) ];
      hinteros = {
        state = stateOf v1;
        deviceConfig.configDir = lib.mkForce v1;
        fakeSteam.enable = true;
      };
      systemd.tmpfiles.settings."10-hinteros-config"."/etc/hinteros".C.argument = lib.mkForce "${v1}";
      # The system the migration's apply flow "builds".
      specialisation.migrated.configuration = {
        hinteros.state = lib.mkOverride 40 (stateOf v2);
        hinteros.deviceConfig.configDir = lib.mkOverride 40 v2;
      };
      systemd.services = {
        "hinteros-job@".path = lib.mkBefore [
          (stubNix {
            inherit pkgs envs;
            nix = config.nix.package;
          })
        ];
        stub-toplevel = {
          wantedBy = [ "multi-user.target" ];
          before = [ "hinteros-system.service" ];
          serviceConfig.Type = "oneshot";
          script = ''
            mkdir -p /run/stub
            # The migration's system build waits until the test has seen the box before it.
            touch /run/stub/hold
            if [ -e /run/current-system/specialisation/migrated ]; then
              readlink -f /run/current-system/specialisation/migrated > /run/stub/toplevel
            fi
          '';
        };
      };
      system.extraDependencies = [ env ];
      environment.etc."hinteros-envs.json".text = builtins.toJSON envs;
      boot.loader.grub.enable = lib.mkForce false;
      virtualisation.diskSize = 4096;
      virtualisation.memorySize = lib.mkForce 3072;
    };

  testScript = ''
    import json
    import time

    envs = json.loads(machine.succeed("cat /etc/hinteros-envs.json"))
    env = envs["firefox,jellyfin,youtube"]["out"]
    ENV = "HINTEROS_SESSION_API=0.12"

    def apps():
        out = machine.succeed(f"runuser -u hinteros -- env {ENV} python3 /etc/hinteros-test/session.py apps.list")
        r = json.loads(out)["response"]
        assert "result" in r, r
        return {a["id"]: a["name"] for a in r["result"]["apps"]}

    def commands_before():
        """The box-wide apps' commands: session.toml's [[apps]] (schema 1)."""
        import tomllib
        args = machine.succeed("ps -u hinteros -o args= | grep -m1 'hinteros-session --config'").split()
        toml = tomllib.loads(machine.succeed(f"cat {args[args.index('--config') + 1]}"))
        return {a["id"]: a["command"] for a in toml.get("apps", []) if isinstance(a, dict)}

    def commands_after():
        """p1's apps' commands: its env's manifest (schema 2)."""
        m = json.loads(machine.succeed("cat /run/hinteros/apps/hinteros/share/hinteros/apps.json"))
        return {a["id"]: a["command"] for a in m["apps"]}

    machine.wait_for_unit("multi-user.target")
    machine.wait_until_succeeds("test -S /run/user/$(id -u hinteros)/hinteros/session.sock")
    # The generation it booted (the migration may have switched already).
    orig = machine.succeed("readlink -f /run/booted-system").strip()

    with subtest("before: schema 1, box-wide apps from session.toml"):
        # The migration may already be running; its switch waits for /run/stub/hold to go.
        before = apps()
        assert {"jellyfin", "youtube", "firefox"} <= set(before), before
        cmds = commands_before()
        assert {"jellyfin", "youtube", "firefox"} <= set(cmds), cmds
        assert machine.succeed("readlink -f /run/current-system").strip() == orig
        machine.succeed("rm /run/stub/hold")

    with subtest("the migration job runs by itself and switches to schema 2"):
        machine.wait_until_succeeds("grep -Eq '\"schemaVersion\": *2' /etc/hinteros/state.json", timeout=600)
        machine.wait_until_succeeds(f"test \"$(readlink -f /run/current-system)\" != {orig}", timeout=600)
        state = json.loads(machine.succeed("cat /etc/hinteros/state.json"))
        assert "apps" not in state, state
        assert state["profiles"] == [{"id": "p1", "user": "hinteros"}], state
        assert state["requirements"] == [] and state["services"] == [], state
        assert machine.succeed("readlink -f /nix/var/nix/profiles/hinteros/apps/hinteros").strip() == env
        assert machine.succeed("readlink -f /nix/var/nix/profiles/hinteros/starter").strip() == env
        machine.succeed("test -L /run/hinteros/apps/hinteros")
        reg = json.loads(machine.succeed("cat /var/lib/hinteros/apps/registry.json"))
        assert reg["owners"]["p1"]["ids"] == ["firefox", "jellyfin", "youtube"], reg
        assert reg["owners"]["starter"]["ids"] == ["firefox", "jellyfin", "youtube"], reg
        profiles = json.loads(machine.succeed("cat /var/lib/hinteros/profiles.json"))
        assert profiles["profiles"]["p1"]["admin"] is True and profiles["profiles"]["p1"]["locked"] is False, profiles

    with subtest("after: the same apps, from p1's manifest"):
        machine.wait_until_succeeds("test -S /run/user/$(id -u hinteros)/hinteros/session.sock")
        # The fake Steam is a box-wide program here, not the catalog's `steam` (not in the
        # fixture's apps): in profile mode Steam comes only from an env's manifest, so it goes.
        # (A box with the catalog's Steam keeps it: its env has `steam` and the box features.)
        want = {k: v for k, v in before.items() if k != "steam"}
        after = {}
        for _ in range(60):
            try:
                after = apps()
            except Exception:
                after = {}
            if after == want:
                break
            time.sleep(1)
        assert after == want, (before, after)
        assert commands_after() == cmds, (cmds, commands_after())

    with subtest("next boot: the picker (schema 2), and the migrated p1 gets in without a PIN"):
        # The switch kept the autologin session (greetd is not restarted by a switch); a new
        # greetd is what the next boot runs.
        machine.succeed("systemctl restart greetd.service")
        gsock = "/run/user/$(id -u hinteros-greeter)/hinteros/session.sock"
        machine.wait_until_succeeds(f"test -S {gsock}", timeout=120)
        out = machine.succeed(
            f"runuser -u hinteros-greeter -- env {ENV} PYTHONPATH=/etc/hinteros-test "
            f"HINTEROS_SESSION_SOCK={gsock} python3 /etc/hinteros-test/greeter.py p1"
        )
        g = json.loads(out)
        assert [p["id"] for p in g["list"]["profiles"]] == ["p1"], g
        assert len(g["outcomes"]) == 1 and g["outcomes"][0]["ok"] is True, g
        machine.wait_until_succeeds("test -S /run/user/$(id -u hinteros)/hinteros/session.sock", timeout=120)
        machine.wait_until_succeeds("pgrep -u hinteros -f '/bin/cage '", timeout=60)
        cur = json.loads(machine.succeed(f"runuser -u hinteros -- env {ENV} HINTEROS_SESSION_SOCK=/run/user/$(id -u hinteros)/hinteros/session.sock python3 /etc/hinteros-test/session.py profile.current"))["response"]["result"]
        # "Set your PIN" comes up in the session.
        assert cur["id"] == "p1" and cur["admin"] and not cur["pin_set"], cur
  '';
}
