# Per-profile apps (apps.md, "The app env", "Where it lives", "The session side"; spike 8).
#
#   config.hinteros.appEnv.build [ "<catalog app id>" ... ]
#
# is the app env of an owner (a profile, the starter set, the guest): one buildEnv of the apps'
# packages plus `share/hinteros/apps.json`, the manifest the session daemon reads instead of
# session.toml's `[[apps]]`. hinteros-system evaluates it from the running system's device flake
# (`builtins.getFlake "path:/etc/hinteros"`), lazily: reading it forces the module system and the
# apps' packages, never `system.build.toplevel`. The same ids on the same system give the same
# store path.
#
# The env's packages come from a second nixpkgs instance (same revision, overlays and config as
# the system) whose allowUnfreePredicate allows exactly the selected entries' unfreePackages; the
# system's own pkgs never lists app packages. A changed predicate changes no
# derivation hash, so free apps still come from the cache.
#
# The rest of this module is the system side of per-profile apps (build plan step 6):
#   - /nix/var/nix/profiles/hinteros/{apps/<user>,starter}: root-owned Nix profiles (GC roots),
#     set by hinteros-system's jobs with `nix-env -p … --set <env>`;
#   - /run/hinteros/apps/<user>: the link sessions read, published by hinteros-system;
#   - with a state: session.toml `[apps] profile`. The env is never on any
#     unsandboxed process's PATH or XDG_DATA_DIRS (a package is not trusted outside the sandbox:
#     a Vulkan layer, a font or a `bin/` name of its own would load into gamescope, the launcher
#     or the daemon). The session daemon reads it by path: the manifest, the commands (absolute
#     store paths), `share/applications`, `share/icons` and `share/pixmaps` for icons;
#   - the automatic clean-up (maintenance.nix) trims every app profile to its newest generations.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hinteros.appEnv;
  entries = config.hinteros.catalog.entries;
  entriesLib = import ../lib/app-entries.nix { inherit lib; };

  # nixpkgs for an env with these unfree package names allowed (none: the system's own pkgs).
  envPkgsFor =
    unfree:
    if unfree == [ ] then
      pkgs
    else
      import pkgs.path {
        localSystem = pkgs.stdenv.hostPlatform;
        inherit (pkgs) overlays;
        config = (removeAttrs config.nixpkgs.config [ "allowUnfreePredicate" ]) // {
          allowUnfreePredicate = p: builtins.elem (lib.getName p) unfree;
        };
      };

  entryOf =
    id:
    let
      e = entries.${id} or (throw "hinteros.appEnv.build: unknown catalog id ${builtins.toJSON id}");
    in
    if (e.kind or "app") != "app" then
      throw "hinteros.appEnv.build: ${id} is a ${e.kind}, not an app"
    else
      e;

  build =
    ids0:
    let
      # Tombstones are dropped (the update's apps stage removes them from every env).
      sel = lib.filter (e: e.status != "removed") (map entryOf (lib.sort lib.lessThan (lib.unique ids0)));
      ids = map (e: e.id) sel;
      unfree = lib.sort lib.lessThan (lib.unique (lib.concatMap (e: e.license.unfreePackages) sel));
      forbidden = lib.subtractLists config.hinteros.unfreeExceptions unfree;
      p =
        if config.hinteros.forbidUnfree && forbidden != [ ] then
          throw "hinteros.appEnv.build: hinteros.forbidUnfree is set but the env needs unfree packages: ${lib.concatStringsSep ", " forbidden}"
        else
          envPkgsFor unfree;
      # The box's inputs to apps (catalog.md, format 3). Steam is stock pkgs.steam (spike 8) with
      # our sockets hidden (lib/steam.nix); its drivers come from /run/opengl-driver(-32) at run time.
      box = {
        firefoxKiosk = config.hinteros.firefoxKiosk.mkWrapper p;
        steam = import ../lib/steam.nix p.steam;
      };
      apps =
        (lib.evalModules {
          modules = [
            {
              options.apps = lib.mkOption {
                type = lib.types.attrsOf (
                  lib.types.submodule (entriesLib.appModuleWith (lib.getExe box.firefoxKiosk))
                );
                default = { };
              };
              config.apps = lib.listToAttrs (
                map (
                  e:
                  lib.nameValuePair e.id (
                    entriesLib.defaultLeaves (
                      entriesLib.catalogSettings {
                        pkgs = p;
                        inherit lib box;
                      } e
                    )
                    // {
                      enable = true;
                    }
                  )
                ) sel
              );
            }
            { config.apps = lib.filterAttrs (id: _: lib.elem id ids) cfg.overrides; }
          ];
        }).config.apps;
      enabled = lib.attrValues apps;
      steam = apps.steam or null;
      manifest = {
        version = 1;
        system_rev = cfg.systemRev;
        inherit ids;
        apps = entriesLib.toEntries apps;
        box = lib.sort lib.lessThan (lib.unique (lib.concatMap (e: e.boxFeatures or [ ]) sel));
      }
      // {
        # DECISIONS D3: `steam` is `{path}` or null.
        steam =
          if steam != null && steam.package != null then { path = lib.getExe steam.package; } else null;
      };
      packages =
        lib.concatMap (a: lib.optional (a.package != null) a.package) enabled
        ++ lib.optional (lib.any (a: a.kiosk.url != null) enabled) box.firefoxKiosk;
    in
    assert lib.all (a: a.listed -> a.command != [ ]) enabled;
    p.buildEnv {
      name = "hinteros-apps";
      paths = packages ++ [ (p.writeTextDir "share/hinteros/apps.json" (builtins.toJSON manifest)) ];
      # Only what the session daemon reads (icons, the manifest) and `bin` (for a person at the
      # console). Apps never use the env's share: their wrappers name their own store paths.
      pathsToLink = [
        "/bin"
        "/share/applications"
        "/share/icons"
        "/share/pixmaps"
        "/share/hinteros"
      ];
      passthru = { inherit ids manifest; };
    };
in
{
  options.hinteros.appEnv = {
    build = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      default = build;
      description = "Catalog app ids -> the app env (a buildEnv with `share/hinteros/apps.json`). Order and duplicates do not matter.";
    };

    buildAll = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      default = lib.mapAttrs (_: build);
      description = "`{ <owner> = [ ids ]; }` -> `{ <owner> = env; }`: every owner's env in one evaluation (the update's apps stage).";
    };

    systemRev = lib.mkOption {
      type = lib.types.str;
      default = "unknown";
      description = "The manifest's `system_rev`: the revision of the hinteros flake the env was built against (set by mkDevice).";
    };

    overrides = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = lib.literalExpression ''{ youtube.kiosk.url = "file:///etc/test/youtube.html"; }'';
      description = "Settings merged into the `hinteros.apps`-shaped entries of every env that has the app (test VMs point kiosk apps at local pages).";
    };

    profilesDir = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "/nix/var/nix/profiles/hinteros";
      description = "Root-owned Nix profiles: `apps/<user>` per profile, `starter`.";
    };

    linkDir = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "/run/hinteros/apps";
      description = "`<linkDir>/<user>`: the link each session reads (published by hinteros-system).";
    };
  };

  config = lib.mkMerge [
    {
      # Root-owned 0755: a profile user cannot repoint its own link (unlike per-user/<user>).
      systemd.tmpfiles.rules = [
        "d ${cfg.profilesDir} 0755 root root -"
        "d ${cfg.profilesDir}/apps 0755 root root -"
      ];
    }

    # Every device: the session daemon reads each profile's env manifest. Test VMs without a state
    # have the box-wide `hinteros.apps`.
    (lib.mkIf (config.hinteros.state != null) {
      assertions = [
        {
          # session.toml `apps` is either the profile table or the box-wide array, never both.
          assertion = !(lib.any (a: a.enable) (lib.attrValues config.hinteros.apps));
          message = "hinteros.apps: box-wide apps (hinteros.apps.<id>.enable) are on; with a state, apps are per profile.";
        }
      ];
      # %u: the session daemon's own user.
      hinteros.daemon.session.settings.apps.profile = "${cfg.linkDir}/%u";
    })
  ];
}
