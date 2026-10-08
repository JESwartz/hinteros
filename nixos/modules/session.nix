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
    # focus state, which the session daemon drives (spike 3). --expose-wayland puts gamescope's
    # Wayland socket in the home app's environment; apps run on Xwayland (GDK_BACKEND below).
    #
    # App size (read from the gamescope 3.16.31 source; README "Display size"):
    # --xwayland-count 2: with more than one Xwayland, gamescope sizes the first (:0, where the
    #   home app and everything the daemon starts run) to the *output* mode, at start
    #   (wlserver.cpp, gamescope_xwayland_server_t) and after every mode change
    #   (steamcompmgr.cpp: wlserver_set_xwayland_server_mode(0, output size), and the nested
    #   height follows the output's aspect). With a single Xwayland its size is the nested size,
    #   fixed at start (main.cpp: nested = output at start, never updated): a display.set_mode to
    #   another size, or a display that came up after gamescope (a TV switched on after boot:
    #   gamescope starts at 1280x720), left every app letterboxed or upscaled. The second
    #   Xwayland (:1, STEAM_GAME_DISPLAY_0) is the one SteamOS gives games; our apps do not use it.
    # --force-windows-fullscreen: every focused X11 app window is resized to its Xwayland root
    #   (= the output), also windows that never ask for fullscreen or pin their size.
    ++ [
      "-e"
      "--expose-wayland"
      "--xwayland-count"
      "2"
      "--force-windows-fullscreen"
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

  # A new session of the user (greetd restarted, the compositor crashed) may find the previous
  # session's daemon still running: the user manager outlives a session whose scope is still being
  # torn down. That daemon is attached to the old compositor (its Xwayland is gone), so the new
  # session restarts it (try-restart: only if it is running) and the new one takes over focus.
  sessionStart = pkgs.writeShellScript "hinteros-session-start" ''
    ${lib.getExe' config.systemd.package "systemctl"} --user --no-block try-restart hinteros-session.service || true
    exec "$@"
  '';

  # The compositor's and the home app's stdout/stderr go to the journal
  # (`journalctl -t hinteros-compositor`); greetd would drop them.
  sessionCommand = lib.escapeShellArgs (
    [
      sessionStart
      (lib.getExe' config.systemd.package "systemd-cat")
      "--identifier"
      "hinteros-compositor"
      (lib.getExe' pkgs.coreutils "env")
    ]
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

    # Under gamescope the launcher runs on Xwayland, as Steam does. gamescope 3.16.31 never sizes
    # a native Wayland toplevel: its xdg_toplevel configures carry no size, set_fullscreen is
    # ignored (wlserver.cpp: xdg_toplevel_new is empty; no wlr_xdg_toplevel_set_size or
    # _set_fullscreen anywhere) and the client's buffer is aspect-fitted to the output with a
    # linear filter (steamcompmgr.cpp, calc_scale_factor). The GTK window's fullscreen request
    # thus left the launcher at its tiny natural size, drawn as a blurry centred square on real
    # hardware. X11 windows are sized to the Xwayland root by gamescope itself (see the flags
    # above). Spike 1 measured slightly steadier frame times on Wayland and no automatic 2x at 4K
    # on X11; the launcher scales its own layout to the window. Cage keeps Wayland (VM config):
    # cage honors fullscreen.
    hinteros.session.environment = lib.mkMerge [
      (lib.mkIf (cfg.compositor == "gamescope") { GDK_BACKEND = lib.mkDefault "x11"; })
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

    # greetd starts `default_session` as a "greeter" once the `initial_session` has ended (a session
    # restart, session.restart). A greeter that ends without having created a session makes greetd
    # exit, so the *second* restart (or a crashing console session) would leave no console at all:
    # start greetd again, which runs the initial session afresh.
    systemd.services.greetd.serviceConfig = {
      Restart = lib.mkForce "always";
      RestartSec = 1;
    };

    environment.systemPackages = [ cfg.gamescope.package ];
  };
}
