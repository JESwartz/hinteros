# Shared parts of the profile VM tests (profiles.md "VM tests", apps.md build plan steps 6-10):
# a schema-2 box with profile accounts, their metadata and PINs as hinteros-system keeps them,
# optional prebuilt app envs (with the stub `nix` of stub-nix-envs.nix, so jobs need no network),
# specialisations that stand for the systems the jobs' apply flow "builds", and Python helpers
# that drive the greeter-mode daemon (the picker's buttons), a profile's session daemon (the
# launcher) and system.sock, as the test users.
#
#   mkTest {
#     name; testScript;              # testScript: a string or { nodes, ... }: string, run after
#                                    #   the Python helpers below
#     state;                         # state.json (schema 2: mkState { ... }; or a schema-1 set)
#     profiles ? { };                # { p1 = { name; color ? "teal"; admin ? false;
#                                    #          locked ? false; pin ? null; }; ... }
#     envs ? { };                    # { <key> = { ids; rooted ? true; }; } app envs built with
#                                    #   the VM (config.hinteros.appEnv.build ids). The stub nix
#                                    #   answers the jobs' env evaluation and build from them.
#                                    #   rooted = false: in the VM's store (additionalPaths) but
#                                    #   not in the system closure, so a GC can collect it.
#     appProfiles ? { };             # { <user> = <env key>; } set at boot (nix-env), before
#                                    #   hinteros-system starts, if the profile does not exist
#     starter ? null;                # <env key>: the starter env, set the same way
#     specialisations ? { };         # { <name> = <state>; } systems the stub "builds"
#                                    #   (or { state; module; }: with more config)
#     overrides ? { };               # hinteros.appEnv.overrides (merged into every env)
#     extraModule ? { };             # more config for the node
#   }
#
# The node is a greeter-mode box by default (schema 2 turns it on) with cage, like
# profiles-greeter. /etc/hinteros is the device config snapshot (an embedded flake whose
# flake.nix only carries the channel line the daemon reads, and the state), so each
# specialisation's snapshot matches the state.json a job writes for it.
{ self, pkgs }:
let
  inherit (pkgs) lib;

  userOf = id: if id == "p1" then "hinteros" else "hinteros-${id}";
  numOf = id: lib.toInt (lib.removePrefix "p" id);

  # The channel line hinteros-system reads (the device flake is never evaluated: the stub nix
  # answers every evaluation and build).
  fixture = ../fixtures/profile-apps;
  embeddedFlake = {
    flake = builtins.readFile (fixture + "/flake.nix");
    lock = builtins.readFile (fixture + "/flake.lock");
  };

  # A PIN as the service stores it (an argon2id PHC string; any parameters verify).
  pinHash =
    pin:
    pkgs.runCommand "hinteros-test-pin" { nativeBuildInputs = [ pkgs.libargon2 ]; } ''
      printf %s ${lib.escapeShellArg pin} | argon2 hinteros-test-salt -id -t 2 -m 12 -p 1 -e > $out
    '';

  # A stubborn app: ignores SIGTERM (and so does every child), as a hung game would.
  stubbornApp = pkgs.writeShellScriptBin "stubborn-app" ''
    trap "" TERM
    while :; do sleep 1; done
  '';
in
rec {
  inherit userOf pinHash stubbornApp;

  # state.json schema 2 (DECISIONS D6).
  mkState =
    {
      accounts ? [
        "p1"
        "p2"
      ],
      requirements ? [ ],
      guest ? true,
      services ? [ ],
    }:
    {
      schemaVersion = 2;
      base = "unstable";
      settings = {
        ssh.enable = false;
        guest.enable = guest;
      };
      profiles = map (id: {
        inherit id;
        user = userOf id;
      }) accounts;
      inherit requirements services;
    };

  # profiles.json (DECISIONS D4) for `profiles`; `next` is one past the highest account.
  profilesJson =
    state: profiles:
    pkgs.writeText "profiles.json" (
      builtins.toJSON {
        version = 1;
        next =
          1
          + lib.foldl' lib.max 1 (
            map (a: numOf a.id) (state.profiles or [ ]) ++ map numOf (lib.attrNames profiles)
          );
        profiles = lib.mapAttrs (_: p: {
          inherit (p) name;
          color = p.color or "teal";
          admin = p.admin or false;
          locked = p.locked or false;
          created_at = 1790000000;
          last_used_at = null;
          appearance = {
            text_scale = 1.0;
            high_contrast = false;
            reduce_motion = false;
          };
        }) profiles;
      }
    );

  # The node (a module).
  node =
    {
      state,
      profiles ? { },
      envs ? { },
      appProfiles ? { },
      starter ? null,
      specialisations ? { },
      overrides ? { },
      extraModule ? { },
    }:
    { config, lib, ... }:
    let
      built = lib.mapAttrs (
        _: e:
        let
          env = config.hinteros.appEnv.build e.ids;
        in
        {
          # Only names: the stub answers from the table; a rooted env is in the closure through
          # extraDependencies, an unrooted one only in the store (additionalPaths).
          drv = builtins.unsafeDiscardStringContext env.drvPath;
          out = builtins.unsafeDiscardStringContext env.outPath;
          inherit env;
          rooted = e.rooted or true;
        }
      ) envs;
      # The stub's table: sorted ids joined by "," -> {drv, out}.
      table = lib.mapAttrs' (
        key: e:
        lib.nameValuePair (lib.concatStringsSep "," (lib.sort lib.lessThan (lib.unique envs.${key}.ids))) {
          inherit (e) drv out;
        }
      ) built;
      setProfile = path: key: ''
        if [ ! -e ${path} ]; then
          nix-env -p ${path} --set ${built.${key}.out}
        fi
      '';
    in
    {
      imports = [
        ../../../nixos/modules # everything but the overlay (the test pkgs already have it)
        self.nixosModules.catalog
        ../../../nixos/vm
        extraModule
      ];

      hinteros = {
        inherit state;
        deviceConfig.embeddedFlake = embeddedFlake;
        appEnv.overrides = overrides;
      };
      systemd = {
        tmpfiles.settings."10-hinteros-config"."/etc/hinteros".C = {
          user = "root";
          group = "root";
          mode = "0755";
          argument = "${config.hinteros.deviceConfig.snapshot}";
        };

        # Before hinteros-system's first start: the profiles' metadata and PINs, the app profiles
        # (each only if it is not there yet: these survive a reboot like the real ones), the
        # stub's directory.
        services = {
          hinteros-test-setup = {
            wantedBy = [ "hinteros-system.service" ];
            before = [ "hinteros-system.service" ];
            after = [ "systemd-tmpfiles-setup.service" ];
            path = [ config.nix.package ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = ''
              mkdir -p /run/stub
              install -d -m 0700 /var/lib/hinteros
              if ${if profiles == { } then "false" else "[ ! -e /var/lib/hinteros/profiles.json ]"}; then
                install -d -m 0700 /var/lib/hinteros/pins
                install -m 0600 ${profilesJson state profiles} /var/lib/hinteros/profiles.json
                ${lib.concatStrings (
                  lib.mapAttrsToList (
                    id: p:
                    lib.optionalString ((p.pin or null) != null) ''
                      install -m 0600 ${pinHash p.pin} /var/lib/hinteros/pins/${id}
                    ''
                  ) profiles
                )}
              fi
              ${lib.concatStrings (
                lib.mapAttrsToList (
                  user: key: setProfile "/nix/var/nix/profiles/hinteros/apps/${user}" key
                ) appProfiles
              )}
              ${lib.optionalString (starter != null) (
                setProfile "/nix/var/nix/profiles/hinteros/starter" starter
              )}
            '';
          };

          # Jobs: the stub nix (env evaluations and builds from the table; the system build prints
          # /run/stub/toplevel), the real nix-env, switch and everything after.
          "hinteros-job@".path = lib.mkBefore [
            ((import ./stub-nix-envs.nix) {
              inherit pkgs;
              envs = table;
              nix = config.nix.package;
            })
          ];
          # As daemon.nix (--freeze-inactive); the launcher shares the uid's token bucket; the VM's
          # store is small (see node.nix).
          hinteros-system.serviceConfig.ExecStart = lib.mkForce "${lib.getExe config.hinteros.daemon.system.package} --freeze-inactive --min-memory-bytes 268435456 --min-disk-bytes 1048576 --rate-burst 100 --rate-per-minute 6000";
        };
      };
      boot.loader.grub.enable = lib.mkForce false;

      specialisation = lib.mapAttrs (
        _: s:
        let
          withModule = s ? state;
        in
        {
          configuration = {
            imports = lib.optional withModule (s.module or { });
            hinteros.state = lib.mkOverride 40 (if withModule then s.state else s);
          };
        }
      ) specialisations;

      system.extraDependencies = lib.mapAttrsToList (_: e: e.env) (
        lib.filterAttrs (_: e: e.rooted) built
      );
      environment = {
        etc."hinteros-test-envs.json".text = builtins.toJSON (lib.mapAttrs (_: e: e.out) built);
        etc."hinteros-test".source = ./client;
        systemPackages = [
          pkgs.python3
          pkgs.acl
          pkgs.jq
        ];
      };
      virtualisation = {
        additionalPaths = lib.mapAttrsToList (_: e: e.env) (lib.filterAttrs (_: e: !e.rooted) built);
        memorySize = lib.mkForce 3072;
        diskSize = 4096;
      };
    };

  # Python helpers (the test script starts with these).
  python = ''
    import json
    import time

    ENV = "HINTEROS_SESSION_API=0.18 HINTEROS_SYSTEM_API=0.10 PYTHONPATH=/etc/hinteros-test"

    def env_path(key):
        """The store path of a prebuilt app env (mkTest `envs`)."""
        return json.loads(machine.succeed("cat /etc/hinteros-test-envs.json"))[key]

    def uid(user):
        return machine.succeed(f"id -u {user}").strip()

    def sock(user):
        return f"/run/user/{uid(user)}/hinteros/session.sock"

    def picker_up():
        machine.wait_until_succeeds(f"test -S {sock('hinteros-greeter')}", timeout=180)
        machine.wait_until_succeeds("pgrep -u hinteros-greeter -f -- '--greeter'", timeout=60)

    def greeter(target, *pins):
        """The picker: log in to `target` (an id or "guest"), answering each PIN prompt in turn
        (see client/greeter.py). {"list": greeter.list, "outcomes": [greeter_result...]}."""
        out = machine.succeed(
            f"runuser -u hinteros-greeter -- env {ENV} HINTEROS_SESSION_SOCK={sock('hinteros-greeter')} "
            f"python3 /etc/hinteros-test/greeter.py {target} {' '.join(pins)}"
        )
        return json.loads(out)

    def greeter_call(method, params=None):
        out = machine.succeed(
            f"runuser -u hinteros-greeter -- env {ENV} HINTEROS_SESSION_SOCK={sock('hinteros-greeter')} "
            f"python3 /etc/hinteros-test/session.py {method} '{json.dumps(params or {})}'"
        )
        return json.loads(out)["response"]

    def sess(user, method, params=None):
        """One call on `user`'s session daemon (as the launcher); the raw response."""
        out = machine.succeed(
            f"runuser -u {user} -- env {ENV} HINTEROS_SESSION_SOCK={sock(user)} "
            f"python3 /etc/hinteros-test/session.py {method} '{json.dumps(params or {})}'"
        )
        return json.loads(out)["response"]

    def sess_ok(user, method, params=None):
        r = sess(user, method, params)
        assert "result" in r, (user, method, params, r)
        return r["result"]

    def sys_call(user, method, params=None):
        """One call on system.sock as `user`: {"response": ...}, {"connect_error": ...} or
        {"failed": output} (the service restarting)."""
        rc, out = machine.execute(
            f"runuser -u {user} -- env {ENV} python3 /etc/hinteros-test/rpc.py {method} '{json.dumps(params or {})}'"
        )
        try:
            return json.loads(out)
        except ValueError:
            return {"failed": out}

    def sysrpc(user, method, params=None):
        r = sys_call(user, method, params)
        assert r.get("response"), (user, method, r)
        return r["response"]

    def sys_ok(user, method, params=None):
        r = sysrpc(user, method, params)
        assert "result" in r, (user, method, params, r)
        return r["result"]

    def sys_err(user, method, params, code):
        r = sysrpc(user, method, params)
        assert "error" in r and r["error"]["code"] == code, (user, method, params, r)
        return r["error"]

    def wait_job(user, jid, timeout=300):
        """Poll until the job leaves `running` (the service may restart meanwhile)."""
        last = None
        for _ in range(timeout):
            last = sys_call(user, "jobs.get", {"job_id": jid})
            resp = last.get("response")
            if resp and "result" in resp and resp["result"]["job"]["state"] != "running":
                return resp["result"]["job"]
            time.sleep(1)
        raise AssertionError(f"job {jid} did not finish: {last}")

    def jobs_idle(user, timeout=120):
        for _ in range(timeout):
            r = sys_call(user, "jobs.list").get("response") or {}
            if "result" in r and not [j for j in r["result"]["jobs"] if j["state"] == "running"]:
                return
            time.sleep(1)
        raise AssertionError("jobs still running")

    def session_of(user):
        """`user`'s session is up (its daemon and compositor) and the picker is gone."""
        machine.wait_until_succeeds(f"test -S {sock(user)}", timeout=180)
        machine.wait_until_succeeds(f"pgrep -u {user} -f '/bin/cage '", timeout=60)
        machine.wait_until_fails("pgrep -u hinteros-greeter -f '/bin/cage '", timeout=60)

    def enter(target, user, *pins):
        """From the picker into a profile (the last PIN must be the right one, if any)."""
        picker_up()
        g = greeter(target, *pins)
        assert g["outcomes"] and g["outcomes"][-1]["ok"] is True, g
        session_of(user)
        return g

    def switch(src, dst, user, **params):
        """A switch from `src`'s session to profile `dst` (user `user`), nothing running."""
        r = sess(src, "session.switch_profile", {"id": dst, **params})
        assert r.get("result") == {}, r
        session_of(user)
        machine.wait_until_fails(f"pgrep -u {src} -f '/bin/cage '", timeout=60)

    def public():
        return json.loads(machine.succeed("cat /run/hinteros/profiles-public.json"))

    def profiles_file():
        return json.loads(machine.succeed("cat /var/lib/hinteros/profiles.json"))

    def state_json():
        return json.loads(machine.succeed("cat /etc/hinteros/state.json"))

    def current_system():
        return machine.succeed("readlink -f /run/current-system").strip()

    def system_generations():
        return len(machine.succeed("nix-env -p /nix/var/nix/profiles/system --list-generations").strip().splitlines())

    def boot_box():
        """Boot, and make the running system generation 1 of the system profile (the VM has
        none), as system-jobs does. Returns {"": the running system, <name>: each
        specialisation} for stub_build()."""
        machine.wait_for_unit("multi-user.target")
        machine.wait_for_unit("hinteros-system.service")
        orig = current_system()
        systems = {"": orig}
        for name in machine.succeed("ls /run/current-system/specialisation 2>/dev/null || true").split():
            systems[name] = machine.succeed(f"readlink -f /run/current-system/specialisation/{name}").strip()
        machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {orig}")
        return systems

    def stub_build(path):
        """The system the next apply flow "builds"."""
        machine.succeed(f"echo {path} > /run/stub/toplevel")
  '';

  mkTest =
    {
      name,
      testScript,
      timeout ? 1800,
      ...
    }@args:
    (pkgs.extend self.overlays.default).testers.runNixOSTest {
      name = "hinteros-${name}";
      meta.timeout = timeout;
      nodes.machine = node (
        removeAttrs args [
          "name"
          "testScript"
          "timeout"
        ]
      );
      testScript =
        { nodes, ... }:
        python + (if builtins.isFunction testScript then testScript { inherit nodes; } else testScript);
    };
}
