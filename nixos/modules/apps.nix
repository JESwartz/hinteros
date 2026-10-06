# App registry (M4): `hinteros.apps.<id>` describes an app the launcher lists. Each enabled app
# becomes an `[[apps]]` entry of the session daemon's session.toml (id, name, kind, icon,
# command; see the hinteros-daemon README) and its package is installed.
#
# Default apps (jellyfin, youtube, crunchyroll, firefox) are enabled whenever the session is.
# Plex HTPC is defined but disabled; the dev box enables it (unfree, see unfree.nix).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hinteros.apps;
  sessionEnabled = config.hinteros.session.enable;
  kioskCmd = lib.getExe config.hinteros.firefoxKiosk.wrapper;
  mkIcon = pkgs.callPackage ../pkgs/app-icon.nix { };

  # TV User-Agent for YouTube's leanback UI (youtube.com/tv refuses desktop browsers).
  # A PlayStation 5 browser UA: YouTube serves its TV UI to it, and Firefox on Linux with
  # it is the combination used by existing "YouTube TV in a desktop browser" setups.
  # Not verifiable offline; if Google stops accepting it, change it here or fall back to
  # backend = "vacuumtube". Alternatives: an Xbox Series X or Fire TV UA.
  youtubeTvUserAgent = "Mozilla/5.0 (PlayStation; PlayStation 5/2.26) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0 Safari/605.1.15";

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

        icon = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "PNG icon (absolute path). The default apps use generated neutral letter icons.";
        };

        unfreeName = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "plex-htpc";
          description = ''
            Name of the unfree package (`lib.getName`); added to `hinteros.unfreeAllowlist` while
            the app is enabled. A plain string, not derived from `package`: nixpkgs.config
            depends on it, so it must not depend on pkgs.
          '';
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

        backKey = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "backspace";
          description = "Key the daemon presses for \"back\" (keyboard input): a name from the API's key list, e.g. `backspace` or `alt+left`.";
        };

        # youtube only: which implementation runs.
        backend = lib.mkOption {
          type = lib.types.enum [
            "firefox"
            "vacuumtube"
          ];
          default = "firefox";
          description = ''
            Only used by the `youtube` app: `firefox` (kiosk profile at youtube.com/tv with a
            TV User-Agent) or `vacuumtube` (the Electron YouTube TV wrapper).
          '';
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

  enabled = lib.filterAttrs (_: a: a.enable) cfg;
  sorted = lib.sort (
    a: b: a.value.order < b.value.order || (a.value.order == b.value.order && a.name < b.name)
  ) (lib.mapAttrsToList lib.nameValuePair enabled);

  toEntry =
    { name, value }:
    {
      id = name;
      inherit (value) kind command name;
    }
    // lib.optionalAttrs (value.icon != null) { icon = toString value.icon; }
    // lib.optionalAttrs (value.input != null) { inherit (value) input; }
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
    {
      hinteros.apps = {
        jellyfin = {
          enable = lib.mkDefault sessionEnabled;
          name = lib.mkDefault "Jellyfin";
          order = lib.mkDefault 10;
          # jellyfin-desktop (formerly jellyfin-media-player; the old name is an alias): Qt +
          # mpv, with its own TV mode driven by the gamepad.
          package = lib.mkDefault pkgs.jellyfin-desktop;
          icon = lib.mkDefault (mkIcon {
            letter = "J";
            color = "#5b4bb7";
          });
        };
        youtube = {
          enable = lib.mkDefault sessionEnabled;
          name = lib.mkDefault "YouTube";
          order = lib.mkDefault 20;
          kind = lib.mkDefault "web";
          kiosk = lib.mkIf (cfg.youtube.backend == "firefox") {
            url = lib.mkDefault "https://www.youtube.com/tv";
            userAgent = lib.mkDefault youtubeTvUserAgent;
          };
          package = lib.mkIf (cfg.youtube.backend == "vacuumtube") (lib.mkDefault pkgs.vacuum-tube);
          # The TV UI is keyboard driven: arrows, Enter, Escape.
          input = lib.mkDefault "keyboard";
          backKey = lib.mkDefault "escape";
          icon = lib.mkDefault (mkIcon {
            letter = "Y";
            color = "#b3261e";
          });
        };
        crunchyroll = {
          enable = lib.mkDefault sessionEnabled;
          name = lib.mkDefault "Crunchyroll";
          order = lib.mkDefault 30;
          kiosk.url = lib.mkDefault "https://www.crunchyroll.com";
          input = lib.mkDefault "keyboard";
          backKey = lib.mkDefault "escape";
          icon = lib.mkDefault (mkIcon {
            letter = "C";
            color = "#d9731a";
          });
        };
        firefox = {
          enable = lib.mkDefault sessionEnabled;
          name = lib.mkDefault "Firefox";
          order = lib.mkDefault 40;
          kind = lib.mkDefault "web";
          kiosk = {
            url = lib.mkDefault "about:home";
            fullscreenOnly = lib.mkDefault true;
          };
          input = lib.mkDefault "keyboard";
          backKey = lib.mkDefault "escape";
          icon = lib.mkDefault (mkIcon {
            letter = "F";
            color = "#2f6fb5";
          });
        };
        # Not a default app: Store app later (M8); the dev box enables it directly.
        plex = {
          name = lib.mkDefault "Plex";
          order = lib.mkDefault 15;
          package = lib.mkDefault pkgs.plex-htpc;
          unfreeName = lib.mkDefault "plex-htpc";
          icon = lib.mkDefault (mkIcon {
            letter = "P";
            color = "#3c3c3c";
          });
        };
      };
    }

    (lib.mkIf (enabled != { }) {
      hinteros.daemon.session.settings.apps = map toEntry sorted;
      environment.systemPackages = lib.concatMap (a: lib.optional (a.package != null) a.package) (
        lib.attrValues enabled
      );
      hinteros.unfreeAllowlist = lib.concatMap (a: lib.optional (a.unfreeName != null) a.unfreeName) (
        lib.attrValues enabled
      );
    })

    {
      hinteros.firefoxKiosk.enable = lib.mkDefault (
        lib.any (a: a.kiosk.url != null) (lib.attrValues enabled)
      );

      assertions = lib.mapAttrsToList (id: a: {
        assertion = a.command != [ ];
        message = "hinteros.apps.${id}: no command (set package, command or kiosk.url)";
      }) enabled;
    }
  ];
}
