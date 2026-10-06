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

  sessionCommand = lib.escapeShellArgs (
    [ (lib.getExe' pkgs.coreutils "env") ]
    ++ lib.mapAttrsToList (name: value: "${name}=${value}") cfg.environment
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

    gamescope = {
      package = lib.mkPackageOption pkgs "gamescope" { };
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
    hinteros.session.environment = lib.mkIf (cfg.compositor == "gamescope") {
      GDK_BACKEND = lib.mkDefault "wayland";
    };

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
