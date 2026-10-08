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
        drv = builtins.unsafeDiscardOutputDependency env.drvPath;
        out = env.outPath;
      };
      stateOf = dir: builtins.fromJSON (builtins.readFile (dir + "/state.json"));
    in
    {
      imports = [ (import ./system/node.nix { inherit self pkgs; }) ];
      hinteros.state = stateOf v1;
      hinteros.deviceConfig.configDir = lib.mkForce v1;
      systemd.tmpfiles.settings."10-hinteros-config"."/etc/hinteros".C.argument = lib.mkForce "${v1}";
      hinteros.fakeSteam.enable = true;
      systemd.services."hinteros-job@".path = lib.mkBefore [
        (stubNix {
          inherit pkgs envs;
          nix = config.nix.package;
        })
      ];
      # The system the migration's apply flow "builds".
      specialisation.migrated.configuration = {
        hinteros.state = lib.mkOverride 40 (stateOf v2);
        hinteros.deviceConfig.configDir = lib.mkOverride 40 v2;
      };
      systemd.services.stub-toplevel = {
        wantedBy = [ "multi-user.target" ];
        before = [ "hinteros-system.service" ];
        serviceConfig.Type = "oneshot";
        script = ''
          mkdir -p /run/stub
          if [ -e /run/current-system/specialisation/migrated ]; then
            readlink -f /run/current-system/specialisation/migrated > /run/stub/toplevel
          fi
        '';
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
        return {a["id"]: a["command"] for a in r["result"]["apps"]}

    machine.wait_for_unit("multi-user.target")
    machine.wait_until_succeeds("test -S /run/user/$(id -u hinteros)/hinteros/session.sock")
    orig = machine.succeed("readlink -f /run/current-system").strip()

    with subtest("before: schema 1, box-wide apps from session.toml"):
        # The migration may already be running; the generation is still the original one.
        before = apps()
        assert {"jellyfin", "youtube", "firefox"} <= set(before), before

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
        after = {}
        for _ in range(60):
            try:
                after = apps()
            except Exception:
                after = {}
            if set(after) == set(before):
                break
            time.sleep(1)
        assert after == before, (before, after)
  '';
}
