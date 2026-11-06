# The app entry shared by the box-wide app registry (apps.nix, `hinteros.apps.<id>`, the test VMs)
# and the per-profile app envs (app-env.nix): one submodule
# for an app's settings and one function that turns the enabled, listed apps into the daemon's
# entries (session.toml `[[apps]]`, or the env manifest's `apps`), so both carry exactly the same
# entries for the same apps.
{ lib }:
rec {
  # The `hinteros.apps.<id>` submodule. `kioskCmd`: the absolute path of the
  # `hinteros-firefox-kiosk` wrapper that kiosk apps run.
  appModuleWith =
    kioskCmd:
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

        iconSha256 = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Hex SHA-256 of the `iconUrl` file (the catalog's `icon.sha256`): the daemon refuses a download with another hash (session.toml `icon_sha256`).";
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

        sandbox = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Start the app in the session daemon's bwrap sandbox (session.toml `sandbox`). Every
            catalog app except Steam; needs `hinteros.sandbox.enable`.
          '';
        };

        permissions = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.enum [
              "required"
              "optional"
            ]
          );
          default = { };
          example = {
            gamepad = "required";
            downloads = "optional";
          };
          description = ''
            What the app may use in its sandbox (the catalog's `permissions`): `gamepad`, `mic`,
            `downloads`, `lan`, each `required` or `optional` (the profile user can deny it).
            Written to session.toml as `permissions`.
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

  # Apps the launcher lists (catalog apps without a tile of their own, like Steam, are not), by
  # `order`, ties broken by id.
  sortedListed =
    apps:
    lib.sort (
      a: b: a.value.order < b.value.order || (a.value.order == b.value.order && a.name < b.name)
    ) (lib.mapAttrsToList lib.nameValuePair (lib.filterAttrs (_: a: a.enable && a.listed) apps));

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
    // lib.optionalAttrs (value.iconUrl != null && value.iconSha256 != null) {
      icon_sha256 = value.iconSha256;
    }
    // lib.optionalAttrs (value.siteUrl != null) { site_url = value.siteUrl; }
    // lib.optionalAttrs value.firefoxProfile {
      firefox_profile = "~/.local/share/hinteros/firefox/${name}";
    }
    // lib.optionalAttrs (value.input != null) { inherit (value) input; }
    // lib.optionalAttrs value.addressBar { address_bar = true; }
    // lib.optionalAttrs (value.backKey != null) { back_key = value.backKey; }
    // lib.optionalAttrs (value.permissions != { }) { inherit (value) permissions; }
    // {
      inherit (value) sandbox;
    };

  # mkDefault on every leaf: settings stay overridable one by one. Derivations (the `package`)
  # are values, not attribute sets to walk into.
  defaultLeaves =
    v:
    if lib.isAttrs v && !lib.isDerivation v then lib.mapAttrs (_: defaultLeaves) v else lib.mkDefault v;

  # attrsOf app config -> the daemon's entries, in list order.
  toEntries = apps: map toEntry (sortedListed apps);

  # A catalog entry's metadata as `hinteros.apps.<id>` settings, plus what its `app` returns
  # when called with `args` ({ pkgs, lib, box }; format 3).
  catalogSettings =
    args: e:
    {
      inherit (e) name;
      listed = e.app != null;
      desktopId = e.icon.desktopId or null;
      iconUrl = e.icon.iconUrl or null;
      iconSha256 = e.icon.sha256 or null;
      siteUrl = e.icon.siteUrl or null;
      firefoxProfile = e.icon.firefoxProfile or false;
      sandbox = e.sandbox or true;
      permissions = e.permissions or { };
    }
    // (
      if e.app == null then
        { }
      else if lib.isFunction e.app then
        e.app args
      else
        e.app
    );
}
