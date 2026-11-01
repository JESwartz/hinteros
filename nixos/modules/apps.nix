# Box-wide app registry: `hinteros.apps.<id>` describes an app every profile's launcher lists.
# Each enabled app becomes an `[[apps]]` entry of the session daemon's session.toml (id, name,
# kind, command, input and the icon fields; see the hinteros-daemon README) and its package is
# installed.
#
# Only test VMs without a state use it. On a device every app is off: apps live in each profile's
# own Nix profile (app-env.nix), and the daemon reads them from the profile's env manifest instead.
#
# The apps themselves come from the catalog (catalog.nix: one `hinteros.apps.<id>` per entry,
# with the entry's settings as defaults). The entry shape and the session.toml entries are shared
# with the app envs (nixos/lib/app-entries.nix), so a test VM and a profile env list the same
# apps the same way. The `onIso` apps (jellyfin, youtube, firefox) are enabled whenever the session
# is; a test VM enables any other catalog id with `hinteros.apps.<id>.enable = true` (Plex and
# Steam are unfree: allowed by name from the entry, see unfree.nix).
{
  config,
  lib,
  ...
}:
let
  cfg = config.hinteros.apps;
  entriesLib = import ../lib/app-entries.nix { inherit lib; };
  kioskCmd = lib.getExe config.hinteros.firefoxKiosk.wrapper;

  enabled = lib.filterAttrs (_: a: a.enable) cfg;
  listed = lib.filterAttrs (_: a: a.listed) enabled;
  steam = cfg.steam or null;
in
{
  imports = [
    ./daemon.nix
    ./unfree.nix
    ./firefox-kiosk.nix
  ];

  options.hinteros.apps = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule (entriesLib.appModuleWith kioskCmd));
    default = { };
    description = "Apps shown in the launcher of every profile (box-wide, test VMs); see the module header.";
  };

  config = lib.mkMerge [
    (lib.mkIf (listed != { }) {
      hinteros.daemon.session.settings.apps = entriesLib.toEntries cfg;
    })

    # Steam's tile is the daemon's built-in entry; it runs the package of the catalog's Steam.
    (lib.mkIf (steam != null && steam.enable && steam.package != null) {
      hinteros.daemon.session.settings.steam.path = lib.mkDefault (lib.getExe steam.package);
    })

    {
      environment.systemPackages =
        lib.concatMap (a: lib.optional (a.package != null) a.package) (lib.attrValues enabled)
        ++ lib.optional (lib.any (a: a.kiosk.url != null) (
          lib.attrValues enabled
        )) config.hinteros.firefoxKiosk.wrapper;

      assertions = lib.mapAttrsToList (id: a: {
        assertion = a.command != [ ];
        message = "hinteros.apps.${id}: no command (set package, command or kiosk.url)";
      }) listed;
    }
  ];
}
