# The App Store catalog (design/catalog.md, repo hinteros-catalog) as the source of
# `hinteros.apps.<id>`. The flake supplies the data (`hinteros.catalog.*`, see flake.nix); this
# module turns every entry into
#   - a `hinteros.apps.<id>` with the entry's `app` settings (as defaults), its name and icon
#     fields (`icon.desktopId`, `iconUrl`, `siteUrl`, `firefoxProfile`, written into session.toml),
#   - its restricted `nixos` module, active while the app is enabled,
#   - the unfree packages it needs (`hinteros.unfreeAllowlist`, derived from the enabled entries),
#   - the `requires` features,
# and installs the generated index and vendor terms at `share/hinteros/catalog.json` and
# `share/hinteros/terms/` (the Store reads /run/current-system/sw/share/hinteros/).
#
# Which apps are on is decided elsewhere: apps.nix enables the `onIso` apps with the session (no
# state), state.nix enables exactly the ids of state.json `apps`.
# A function of the catalog data, not a plain module: which entries exist decides the shape of
# this module's config (one `nixos` module per entry), so it must not be read from `config`.
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
  # What an entry's `app` and `nixos` functions are called with.
  args = {
    inherit
      config
      options
      lib
      pkgs
      ;
  };

  sessionEnabled = config.hinteros.session.enable;

  # Tombstones (`status = "removed"`) are known ids that do nothing.
  live = lib.filterAttrs (_: e: e.status != "removed") entries;
  enabled = lib.filterAttrs (id: _: config.hinteros.apps.${id}.enable) live;

  # mkDefault on every leaf: a device can still override single settings of an entry. Derivations
  # (the `package`) are values, not attribute sets to walk into.
  defaultLeaves =
    v:
    if lib.isAttrs v && !lib.isDerivation v then lib.mapAttrs (_: defaultLeaves) v else lib.mkDefault v;

  appOf =
    e:
    if e.app == null then
      { }
    else if lib.isFunction e.app then
      e.app args
    else
      e.app;

  nixosOf =
    e:
    if e.nixos == null then
      { }
    else if lib.isFunction e.nixos then
      e.nixos args
    else
      e.nixos;
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
  };

  config = lib.mkMerge [
    {
      hinteros.apps = lib.mapAttrs (
        _: e:
        defaultLeaves (
          {
            enable = sessionEnabled && e.onIso;
            inherit (e) name;
            listed = e.app != null;
            desktopId = e.icon.desktopId or null;
            iconUrl = e.icon.iconUrl or null;
            siteUrl = e.icon.siteUrl or null;
            firefoxProfile = e.icon.firefoxProfile or false;
          }
          // appOf e
        )
      ) live;

    }

    {
      environment = {
        systemPackages = [ index ];
        pathsToLink = [ "/share/hinteros" ];
      };
    }

    # The unfree packages the enabled entries need, by name (nixpkgs.config must not depend on pkgs).
    {
      hinteros.unfreeAllowlist = lib.unique (
        lib.concatMap (e: e.license.unfreePackages) (lib.attrValues enabled)
      );
    }

    # System features the enabled entries ask for.
    (lib.mkIf (lib.any (e: lib.elem "graphics32" e.requires) (lib.attrValues enabled)) {
      hardware.graphics.enable32Bit = lib.mkDefault true;
    })

    # Each entry's own NixOS config (the restricted `nixos` module) while it is enabled.
    (lib.mkMerge (
      lib.mapAttrsToList (id: e: lib.mkIf config.hinteros.apps.${id}.enable (nixosOf e)) live
    ))
  ];
}
