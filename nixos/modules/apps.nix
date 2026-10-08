# App registry: `hinteros.apps.<id>` describes an app the launcher lists. Each enabled app becomes an
# `[[apps]]` entry of the session daemon's session.toml (id, name, kind, command, input and the
# icon fields; see the hinteros-daemon README) and its package is installed.
#
# The apps themselves come from the catalog (catalog.nix: one `hinteros.apps.<id>` per entry,
# with the entry's settings as defaults). The `onIso` apps (jellyfin, youtube,
# firefox) are enabled whenever the session is, until a state.json selects the apps; a device
# enables any other catalog id with `hinteros.apps.<id>.enable = true` (Plex and Steam are unfree:
# allowed by name from the entry, see unfree.nix).
{
  config,
  lib,
  ...
}:
let
  cfg = config.hinteros.apps;
  kioskCmd = lib.getExe config.hinteros.firefoxKiosk.wrapper;

  appModule =
    { config, name, ... }:
    {
      options = {
        enable = lib.mkEnableOption "this app in the launcher";

        name = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Display name.";
        };

        order = lib.mkOption {
          type = lib.types.int;
          default = 100;
          description = "Position in apps.list: lower first, ties broken by id.";
        };

        kind = lib.mkOption {
          type = lib.types.enum [
            "native"
            "web"
          ];
          default = if config.kiosk.url != null then "web" else "native";
          defaultText = lib.literalExpression ''"web" for kiosk apps, else "native"'';
          description = "`kind` reported by the daemon (`web` marks browser-based apps).";
        };

        package = lib.mkOption {
          type = lib.types.nullOr lib.types.package;
          default = null;
          description = "Package installed for this app. Its main program is the default command.";
        };

        command = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = ''
            argv the daemon runs. Defaults to the Firefox kiosk wrapper for `kiosk.url`
            apps and to the package's main program otherwise.
          '';
        };

        kiosk = {
          url = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Open this URL in a Firefox kiosk profile named after the app id.";
          };
          userAgent = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "User-Agent override for this app's Firefox profile only.";
          };
          fullscreenOnly = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Run Firefox without `--kiosk` (address bar and tabs stay available). The
              compositor still shows it fullscreen.
            '';
          };
        };

        listed = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether the launcher lists the app. False for catalog entries that only add system config (Steam: the daemon's built-in `steam` entry is its tile).";
        };

        icon = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "PNG icon (absolute path), first choice when set. Catalog apps leave it unset: the daemon finds real icons at runtime from the fields below.";
        };

        desktopId = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "The installed app's freedesktop `.desktop` file id; its `Icon=` is the icon (session.toml `desktop_id`).";
        };

        iconUrl = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "https URL of the vendor's own logo, fetched by the daemon at runtime (session.toml `icon_url`).";
        };

        siteUrl = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Site whose icon the daemon looks up (session.toml `site_url`).";
        };

        firefoxProfile = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Use the favicon the app's kiosk profile stored (session.toml `firefox_profile`, needs `siteUrl`).";
        };

        input = lib.mkOption {
          type = lib.types.nullOr (
            lib.types.enum [
              "gamepad"
              "keyboard"
            ]
          );
          default = null;
          description = ''
            How the app takes controller input: `gamepad` (passed through) or `keyboard` (the
            daemon turns controller actions into key presses for it). `null` leaves the
            daemon's default (`gamepad`). Written to session.toml as `input` (daemon API 0.4).
          '';
        };

        addressBar = lib.mkOption {
          type = lib.types.bool;
          default = config.kiosk.fullscreenOnly;
          defaultText = lib.literalExpression "kiosk.fullscreenOnly";
          description = ''
            Plain Firefox with a toolbar (not a kiosk): the daemon maps View to Ctrl+L plus the
            on-screen keyboard, and LB / RB to history back / forward (Alt+Left / Alt+Right)
            (session.toml `address_bar`, see the hinteros-daemon README). On for
            `fullscreenOnly` apps (the catalog's Firefox), off for kiosk apps.
          '';
        };

        backKey = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "backspace";
          description = "Key the daemon presses for \"back\" (keyboard input): a name from the API's key list, e.g. `backspace` or `alt+left`.";
        };
      };

      config = {
        command = lib.mkMerge [
          (lib.mkIf (config.kiosk.url != null) (
            [ kioskCmd ]
            ++ lib.optional (config.kiosk.userAgent != null) "--user-agent"
            ++ lib.optional (config.kiosk.userAgent != null) config.kiosk.userAgent
            ++ lib.optional config.kiosk.fullscreenOnly "--no-kiosk"
            ++ [
              name
              config.kiosk.url
            ]
          ))
          (lib.mkIf (config.kiosk.url == null && config.package != null) [ (lib.getExe config.package) ])
        ];
      };
    };

  # Entries the launcher lists (catalog apps that only add system config, like Steam, are not).
  enabled = lib.filterAttrs (_: a: a.enable) cfg;
  listed = lib.filterAttrs (_: a: a.listed) enabled;
  sorted = lib.sort (
    a: b: a.value.order < b.value.order || (a.value.order == b.value.order && a.name < b.name)
  ) (lib.mapAttrsToList lib.nameValuePair listed);

  # The icon fields are the daemon's own (hinteros-daemon README, "Icons"): it finds the real
  # icon at runtime, so HinterOS ships no logos.
  toEntry =
    { name, value }:
    {
      id = name;
      inherit (value) kind command name;
    }
    // lib.optionalAttrs (value.icon != null) { icon = toString value.icon; }
    // lib.optionalAttrs (value.desktopId != null) { desktop_id = value.desktopId; }
    // lib.optionalAttrs (value.iconUrl != null) { icon_url = value.iconUrl; }
    // lib.optionalAttrs (value.siteUrl != null) { site_url = value.siteUrl; }
    // lib.optionalAttrs value.firefoxProfile {
      firefox_profile = "~/.local/share/hinteros/firefox/${name}";
    }
    // lib.optionalAttrs (value.input != null) { inherit (value) input; }
    // lib.optionalAttrs value.addressBar { address_bar = true; }
    // lib.optionalAttrs (value.backKey != null) { back_key = value.backKey; };
in
{
  imports = [
    ./daemon.nix
    ./unfree.nix
    ./firefox-kiosk.nix
  ];

  options.hinteros.apps = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule appModule);
    default = { };
    description = "Apps shown in the launcher; see the module header.";
  };

  config = lib.mkMerge [
    (lib.mkIf (listed != { }) {
      hinteros.daemon.session.settings.apps = map toEntry sorted;
    })

    {
      environment.systemPackages = lib.concatMap (a: lib.optional (a.package != null) a.package) (
        lib.attrValues enabled
      );

      hinteros.firefoxKiosk.enable = lib.mkDefault (
        lib.any (a: a.kiosk.url != null) (lib.attrValues enabled)
      );

      assertions = lib.mapAttrsToList (id: a: {
        assertion = a.command != [ ];
        message = "hinteros.apps.${id}: no command (set package, command or kiosk.url)";
      }) listed;
    }
  ];
}
