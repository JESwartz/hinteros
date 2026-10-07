# Console session: greetd autologin straight into a compositor running the home app.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hinteros.session;

  compositorCommand = {
    gamescope = [
      (lib.getExe cfg.gamescope.package)
    ]
    ++ lib.optionals (cfg.gamescope.backend != null) [
      "--backend"
      cfg.gamescope.backend
    ]
    # -e: Steam mode. Only then does gamescope take app ids from reapers and publish the
    # focus state, which the session daemon drives (spike 3). Native Wayland clients (the
    # launcher, see GDK_BACKEND below) need gamescope's Wayland socket; Xwayland is always there.
    ++ [
      "-e"
      "--expose-wayland"
    ]
    ++ cfg.gamescope.extraArgs
    ++ [ "--" ];
    # Fallback for machines without a usable Vulkan GPU (e.g. the test VM).
    cage = [
      (lib.getExe pkgs.cage)
      "-s"
      "--"
    ];
  };

  # Under gamescope the home app runs under the reaper, which is how gamescope (Steam mode)
  # learns the app id of its windows. Started here rather than by the daemon's
  # launcher.command: gamescope needs a child to run anyway, and the home app then comes up
  # (and lives and dies with the session) whether or not the daemon is alive.
  homeCommand =
    if cfg.compositor == "gamescope" then
      [
        (lib.getExe cfg.reaperPackage)
        "reaper"
        "SteamLaunch"
        "AppId=${toString cfg.launcherAppId}"
        "--"
        (lib.getExe cfg.homeApp)
      ]
    else
      [ (lib.getExe cfg.homeApp) ];

  # Runs its arguments with gamescope's display mode files set (runtime settings, API 0.7):
  # `GAMESCOPE_PATCHED_EDID_FILE` (gamescope writes the connector's modes next to it, as
  # `<file>.modes`) in the runtime dir, and `GAMESCOPE_MODE_SAVE_FILE` (the mode the user picked,
  # which gamescope applies at its next start) in the session user's state dir. The session daemon
  # runs through it too, so both see the same files. A wrapper, not fixed paths: the uid is only
  # known at login.
  displayEnvWrapper = pkgs.writeShellScript "hinteros-display-env" ''
    state="''${XDG_STATE_HOME:-$HOME/.local/state}/hinteros"
    ${pkgs.coreutils}/bin/mkdir -p "$state"
    export GAMESCOPE_PATCHED_EDID_FILE="$XDG_RUNTIME_DIR/gamescope-edid"
    export GAMESCOPE_MODE_SAVE_FILE="$state/gamescope-modes"
    exec "$@"
  '';

  sessionCommand = lib.escapeShellArgs (
    [ (lib.getExe' pkgs.coreutils "env") ]
    ++ lib.mapAttrsToList (name: value: "${name}=${value}") cfg.environment
    ++ lib.optional (cfg.compositor == "gamescope") cfg.displayEnvWrapper
    ++ compositorCommand.${cfg.compositor}
    ++ homeCommand
  );
in
{
  options.hinteros.session = {
    enable = lib.mkEnableOption "the HinterOS console session";

    user = lib.mkOption {
      type = lib.types.str;
      default = "hinteros";
      description = "User that is logged in automatically and owns the session.";
    };

    compositor = lib.mkOption {
      type = lib.types.enum [
        "gamescope"
        "cage"
      ];
      default = "gamescope";
      description = ''
        Compositor that hosts the home app. `gamescope` is the real session and needs a
        Vulkan GPU with DRM format modifiers; `cage` is a software-rendering fallback
        for the test VM, where gamescope cannot start on llvmpipe.
      '';
    };

    homeApp = lib.mkOption {
      type = lib.types.package;
      default = pkgs.hinteros-launcher;
      defaultText = lib.literalExpression "pkgs.hinteros-launcher";
      description = ''
        The home app: the program the compositor runs and that stays in the foreground
        when nothing else is running. Must have `meta.mainProgram` set. Defaults to the Flutter
        launcher; `pkgs.hinteros-placeholder-home` (an xterm) is kept for debugging.
      '';
    };

    launcherAppId = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4100000000;
      description = ''
        gamescope app id of the home app's windows (given through the reaper). The session
        daemon uses the same id (`launcher.app_id`) to bring the home app to the front.
      '';
    };

    reaperPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.hinteros-session;
      defaultText = lib.literalExpression "pkgs.hinteros-session";
      description = "Package providing `hinteros-session reaper`, which wraps the home app under gamescope.";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        WLR_RENDERER = "pixman";
      };
      description = "Environment variables set for the compositor.";
    };

    displayEnvWrapper = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = displayEnvWrapper;
      internal = true;
      description = "Wrapper script that sets gamescope's mode file variables for the command it runs.";
    };

    gamescope = {
      package = lib.mkPackageOption pkgs "gamescope" { };
      reviewedVersion = lib.mkOption {
        type = lib.types.str;
        default = "3.16.31";
        description = ''
          gamescope version the session daemon's vendored private protocol was checked
          against. The session fails to evaluate with any other version; bump it only after
          diffing `protocol/gamescope-input-method.xml` in hinteros-daemon.
        '';
      };
      backend = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.enum [
            "drm"
            "headless"
            "wayland"
            "sdl"
          ]
        );
        default = null;
        example = "headless";
        description = ''
          gamescope `--backend`. `null` lets gamescope choose (DRM on a bare TTY). `headless`
          renders without a display and is what the `gamescope` VM test uses.
        '';
      };
      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [
          "-W"
          "1920"
          "-H"
          "1080"
        ];
        description = "Extra command-line arguments for gamescope, placed before the home app.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    hardware.graphics.enable = true;
    hardware.uinput.enable = true;

    # Spike 1: the Flutter launcher runs better on native Wayland than on Xwayland under
    # gamescope (correct 2x scale at 4K, steadier frame times). The cage VM config sets the same.
    hinteros.session.environment = lib.mkMerge [
      (lib.mkIf (cfg.compositor == "gamescope") { GDK_BACKEND = lib.mkDefault "wayland"; })
      # The daemon's virtual keyboard sends US key codes, so the compositor's layout must be US
      # (gamescope reads XKB_DEFAULT_LAYOUT in wlserver.cpp; cage/wlroots too). Non-US text goes
      # through gamescope's input method instead.
      { XKB_DEFAULT_LAYOUT = lib.mkDefault "us"; }
    ];

    # The daemon vendors gamescope's private `gamescope_input_method` protocol
    # (crates/hinteros-session/protocol/gamescope-input-method.xml, from 3.16.31) and the
    # overlay/focus atoms; neither is a stable interface. A nixpkgs bump that changes the
    # version must fail here until someone diffs those files and updates reviewedVersion.
    assertions = [
      {
        assertion =
          cfg.compositor != "gamescope" || cfg.gamescope.package.version == cfg.gamescope.reviewedVersion;
        message = "hinteros.session: gamescope is ${cfg.gamescope.package.version} but the daemon was reviewed against ${cfg.gamescope.reviewedVersion} (private gamescope_input_method protocol). Re-check the daemon's protocol XML against the new version, then update hinteros.session.gamescope.reviewedVersion.";
      }
    ];

    users.users.${cfg.user} = {
      isNormalUser = true;
      extraGroups = [
        "video"
        "input"
        "uinput" # the daemon injects key presses for keyboard-driven apps
      ];
    };

    services.greetd = {
      enable = true;
      settings = rec {
        initial_session = {
          command = sessionCommand;
          inherit (cfg) user;
        };
        default_session = initial_session;
      };
    };

    environment.systemPackages = [ cfg.gamescope.package ];
  };
}
