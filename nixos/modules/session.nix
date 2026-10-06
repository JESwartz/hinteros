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
    gamescope = [ (lib.getExe cfg.gamescope.package) ] ++ cfg.gamescope.extraArgs ++ [ "--" ];
    # Fallback for machines without a usable Vulkan GPU (e.g. the test VM).
    cage = [
      (lib.getExe pkgs.cage)
      "-s"
      "--"
    ];
  };

  sessionCommand = lib.escapeShellArgs (
    [ (lib.getExe' pkgs.coreutils "env") ]
    ++ lib.mapAttrsToList (name: value: "${name}=${value}") cfg.environment
    ++ compositorCommand.${cfg.compositor}
    ++ [ (lib.getExe cfg.homeApp) ]
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

    users.users.${cfg.user} = {
      isNormalUser = true;
      extraGroups = [
        "video"
        "input"
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
