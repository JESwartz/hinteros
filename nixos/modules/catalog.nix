# The App Store catalog (design/catalog.md, repo hinteros-catalog; entry format 3) in the system.
# The flake supplies the data (`hinteros.catalog.*`, see flake.nix); this module
#   - turns every `kind = "app"` entry into a box-wide `hinteros.apps.<id>` with the entry's `app`
#     settings (as defaults) and its name and icon fields. `app` is called with `{ pkgs, lib,
#     box }`, `box` being the system's (`box.firefoxKiosk`: the kiosk wrapper; `box.steam`: stock
#     pkgs.steam with our sockets hidden, lib/steam.nix). Per-profile envs call it with their own
#     pkgs (app-env.nix);
#   - derives, from the box-wide apps that are on, the unfree packages they need
#     (`hinteros.unfreeAllowlist`, the enabled services' too) and the box features they name
#     (`hinteros.boxFeatures`);
#   - enables the restricted `service` module of every service in `hinteros.catalog.services`
#     (state.json `services`, M10);
#   - installs the generated index and vendor terms at `share/hinteros/catalog.json` and
#     `share/hinteros/terms/` (the Store reads /run/current-system/sw/share/hinteros/).
#
# Which box-wide apps are on is decided elsewhere: the installer's `onIso` apps (app-ids.nix: on
# the ISO and offered by the installer, so jellyfin, youtube and firefox) are on with the session
# (no state), state.nix sets exactly the ids of a schema-1 state's `apps` and none on schema 2.
# A function of the catalog data, not a plain module: which entries exist decides the shape of
# this module's config (one `service` module per entry), so it must not be read from `config`.
# flake.nix passes it in; `hinteros.catalog.*` re-exports it for other modules to read.
{
  entries,
  cacheableUnfree,
  index,
}:
{
  config,
  options,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hinteros.catalog;
  entriesLib = import ../lib/app-entries.nix { inherit lib; };
  # An entry's own `onIso` only says its closure is on the ISO (format 3: the Store-only streaming
  # apps have it too). The default apps are the installer's `onIso` list: also offered (`starter`).
  appIds = import ../lib/app-ids.nix entries;
  sessionEnabled = config.hinteros.session.enable;

  # Tombstones (`status = "removed"`) are known ids that do nothing.
  live = lib.filterAttrs (_: e: e.status != "removed") entries;
  liveApps = lib.filterAttrs (_: e: (e.kind or "app") == "app") live;
  liveServices = lib.filterAttrs (_: e: (e.kind or "app") == "service") live;
  enabled = lib.filterAttrs (id: _: config.hinteros.apps.${id}.enable) liveApps;

  # The box's inputs to the box-wide apps (catalog.md, format 3).
  box = {
    firefoxKiosk = config.hinteros.firefoxKiosk.wrapper;
    steam = import ../lib/steam.nix pkgs.steam;
  };

  serviceOf =
    e:
    if e.service == null then
      { }
    else if lib.isFunction e.service then
      e.service {
        inherit
          config
          options
          lib
          pkgs
          ;
      }
    else
      e.service;
in
{
  options.hinteros.catalog = {
    entries = lib.mkOption {
      type = lib.types.attrsOf lib.types.raw;
      default = entries;
      readOnly = true;
      internal = true;
      description = "The catalog's entries (hinteros-catalog's `catalog`), validated and normalized, tombstones included.";
    };

    cacheableUnfree = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = cacheableUnfree;
      readOnly = true;
      description = ''
        Unfree package names (`lib.getName`) the binary cache may hold: those of entries with
        `cache = true` (hinteros-catalog's `lib.cacheableUnfree`). A cache build sets
        `hinteros.forbidUnfree = true` and `hinteros.unfreeExceptions` to this list.
      '';
    };

    index = lib.mkOption {
      type = lib.types.package;
      default = index;
      readOnly = true;
      description = "Package with `share/hinteros/catalog.json` (the Store index) and `share/hinteros/terms/*.txt`.";
    };

    services = lib.mkOption {
      type = lib.types.listOf (lib.types.enum (builtins.attrNames liveServices));
      default = [ ];
      description = "Enabled catalog services (state.json `services`): their `service` modules are part of the system.";
    };

    box = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      internal = true;
      default = box;
      description = "The `box` argument the box-wide apps' `app` functions get.";
    };
  };

  imports = [ ./box-features.nix ];

  config = lib.mkMerge [
    {
      hinteros.apps = lib.mapAttrs (
        id: e:
        entriesLib.defaultLeaves (
          {
            enable = sessionEnabled && lib.elem id appIds.onIso;
          }
          // entriesLib.catalogSettings {
            inherit pkgs lib box;
          } e
        )
      ) liveApps;
    }

    {
      environment = {
        systemPackages = [ index ];
        pathsToLink = [ "/share/hinteros" ];
      };
    }

    # The unfree packages the box-wide apps and the enabled services need, by name (nixpkgs.config
    # must not depend on pkgs): Plex Media Server is allowed only while it is on. App envs allow
    # their own in a separate nixpkgs instance (app-env.nix).
    {
      hinteros.unfreeAllowlist = lib.unique (
        lib.concatMap (e: e.license.unfreePackages or [ ]) (
          lib.attrValues enabled ++ map (id: liveServices.${id}) cfg.services
        )
      );
    }

    # Box features the box-wide apps name (schema 1; on schema 2 state.json `requirements`).
    {
      hinteros.boxFeatures = lib.unique (lib.concatMap (e: e.box or [ ]) (lib.attrValues enabled));
    }

    # Each enabled service's restricted NixOS module.
    (lib.mkMerge (
      lib.mapAttrsToList (id: e: lib.mkIf (lib.elem id cfg.services) (serviceOf e)) liveServices
    ))
  ];
}
