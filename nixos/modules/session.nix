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
      appDisplaysWrapper
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
    # --xwayland-count 3: with more than one Xwayland, gamescope sizes the first (:0, the home
    #   app, the OSK and Steam) to the *output* mode, at start
    #   (wlserver.cpp, gamescope_xwayland_server_t) and after every mode change
    #   (steamcompmgr.cpp: wlserver_set_xwayland_server_mode(0, output size), and the nested
    #   height follows the output's aspect). With a single Xwayland its size is the nested size,
    #   fixed at start (main.cpp: nested = output at start, never updated): a display.set_mode to
    #   another size, or a display that came up after gamescope (a TV switched on after boot:
    #   gamescope starts at 1280x720), left every app letterboxed or upscaled. The second
    #   Xwayland (:1, STEAM_GAME_DISPLAY_0) is the one SteamOS gives games. The others (:2 and
    #   up, the app displays) each hold one app the daemon starts (daemon.nix `apps_display`), so
    #   that no app can read or type into the home app (PIN entry), the OSK or another app. Their
    #   number is the profile's setting (`appDisplaysWrapper` sets the count below). Patched
    #   (nixos/overlay.nix): every Xwayland but :1 follows the output like :0, none listens on an
    #   abstract socket (a sandboxed app gets only its own display's socket file, but shares the
    #   network namespace), and none from #2 on gets LIBEI_SOCKET.
    # --force-windows-fullscreen: every focused X11 app window is resized to its Xwayland root
    #   (= the output), also windows that never ask for fullscreen or pin their size.
    ++ [
      "-e"
      "--expose-wayland"
      "--xwayland-count"
      (toString (2 + cfg.gamescope.appDisplays))
      "--force-windows-fullscreen"
      # The pointer (right stick in keyboard-profile apps) never fades on inactivity (the
      # daemon hides it on the D-pad), and is large enough to see on a TV (`cursor` options).
      "--hide-cursor-delay"
      (toString cfg.cursor.hideDelayMs)
    ]
    ++ lib.optionals (cfg.cursor.scaleHeight != null) [
      "--cursor-scale-height"
      (toString cfg.cursor.scaleHeight)
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

  # The current system's console programs, linked from the system toplevel (so
  # /run/current-system/hinteros-console/{home,session}): a switch updates /run/current-system
  # (in its activation, before units are restarted); the running session keeps its programs.
  # Not /etc/hinteros: that is the device's mutable config dir, swapped at boot
  # (device-config.nix).
  consoleDir = "/run/current-system/hinteros-console";
  homeLink = "${consoleDir}/home";
  # The exit code with which the home app asks the loop below to start it again.
  homeRelaunchCode = 75;

  # The compositor's one child: runs the home app that `homeLink` points to *now*, and again
  # whenever it exits with `homeRelaunchCode`; any other exit ends the loop, the compositor and
  # the session, as before. A system switch restarts the session daemon (a user unit) but not
  # this session (greetd is never restarted by a switch), so the old launcher would keep running
  # against the new daemon; on an API mismatch it was refused forever ("Switching over"). The
  # launcher (lib/src/system/home_relaunch.dart) exits with the code when the daemon refuses it
  # or comes back after a restart and `homeLink` has another launcher than the one it was
  # started as (HINTEROS_HOME_EXE): the new one starts in the same gamescope, which never loses
  # its child (it would quit, ending every app), and whose Xwaylands keep a client (gamescope's
  # own window manager, the daemon), so their -terminate does not end them.
  homeLoop = pkgs.writeShellScript "hinteros-home" ''
    link=${homeLink}
    while :; do
      exe=$(${pkgs.coreutils}/bin/readlink -e "$link") || exe=${lib.getExe cfg.homeApp}
      HINTEROS_HOME_RELAUNCH=${toString homeRelaunchCode} HINTEROS_HOME_LINK="$link" \
        HINTEROS_HOME_EXE="$exe" "$exe" "$@"
      code=$?
      if [ "$code" -ne ${toString homeRelaunchCode} ]; then
        exit "$code"
      fi
      echo "hinteros-home: $exe asked to be replaced; starting $(${pkgs.coreutils}/bin/readlink -e "$link")" >&2
      ${pkgs.coreutils}/bin/sleep 1
    done
  '';

  # Under gamescope the home app runs under the reaper, which is how gamescope (Steam mode)
  # learns the app id of its windows. Started here rather than by the daemon's
  # launcher.command: gamescope needs a child to run anyway, and the home app then comes up
  # (and lives and dies with the session) whether or not the daemon is alive.
  homeCommandWith =
    args:
    (
      if cfg.compositor == "gamescope" then
        [
          (lib.getExe cfg.reaperPackage)
          "reaper"
          "SteamLaunch"
          "AppId=${toString cfg.launcherAppId}"
          "--"
        ]
      else
        [ ]
    )
    ++ [ homeLoop ]
    ++ args;
  homeCommand = homeCommandWith [ ];

  # Runs its arguments with gamescope's display mode files set (runtime settings, API 0.7):
  # `GAMESCOPE_PATCHED_EDID_FILE` (gamescope writes the connector's modes next to it, as
  # `<file>.modes`) in the runtime dir, and `GAMESCOPE_MODE_SAVE_FILE` (the mode the user picked,
  # which gamescope applies at its next start) in the session user's state dir. The session daemon
  # runs through it too, so both see the same files. A wrapper, not fixed paths: the uid is only
  # known at login.
  #
  # The display mode is the box's, not the user's (profiles.md "Per profile vs. shared"):
  # `display.keep` saves it for every profile (hinteros-system writes /run/hinteros/gamescope-modes
  # from runtime.json, also at boot), and every session (a profile, a fresh one, the guest whose
  # home is new at every boot, the picker) starts gamescope with it, so a switch never makes the
  # TV change mode. A copy, not a link: the session daemon writes the user's file when a mode is
  # kept (and then saves it box-wide).
  displayEnvWrapper = pkgs.writeShellScript "hinteros-display-env" ''
    state="''${XDG_STATE_HOME:-$HOME/.local/state}/hinteros"
    ${pkgs.coreutils}/bin/mkdir -p "$state"
    box=/run/hinteros/gamescope-modes
    if [ -s "$box" ]; then
      ${pkgs.coreutils}/bin/cp -f "$box" "$state/gamescope-modes.new" \
        && ${pkgs.coreutils}/bin/mv -f "$state/gamescope-modes.new" "$state/gamescope-modes"
    fi
    export GAMESCOPE_PATCHED_EDID_FILE="$XDG_RUNTIME_DIR/gamescope-edid"
    export GAMESCOPE_MODE_SAVE_FILE="$state/gamescope-modes"
    exec "$@"
  '';

  # The profile's app env (app-env.nix) is not on the session's PATH or XDG_DATA_DIRS: its
  # packages are only trusted inside the app sandbox. The session daemon reads it by path.

  # App displays (daemon README "Own display"): gamescope makes its Xwaylands at start only, so
  # the profile's number of app displays (`apps.displays.set`, one number in
  # $XDG_STATE_HOME/hinteros/app-displays; else `gamescope.appDisplays`) is read here, written
  # for the session daemon as this session's number ($XDG_RUNTIME_DIR/hinteros/app-displays,
  # hidden from Steam and the sandbox), and becomes `--xwayland-count` 2 + n. Only in front of
  # gamescope: the daemon (restarted on its own) must keep reading what this gamescope has.
  appDisplaysWrapper = pkgs.writeShellScript "hinteros-app-displays" ''
    n=$(${pkgs.coreutils}/bin/cat "''${XDG_STATE_HOME:-$HOME/.local/state}/hinteros/app-displays" 2>/dev/null)
    n=''${n//[[:space:]]/}
    case "$n" in
      [1-8]) ;;
      *) n=${toString cfg.gamescope.appDisplays} ;;
    esac
    if [ -n "''${XDG_RUNTIME_DIR:-}" ]; then
      ${pkgs.coreutils}/bin/mkdir -p -m 0700 "$XDG_RUNTIME_DIR/hinteros"
      echo "$n" > "$XDG_RUNTIME_DIR/hinteros/app-displays.new" \
        && ${pkgs.coreutils}/bin/mv -f "$XDG_RUNTIME_DIR/hinteros/app-displays.new" "$XDG_RUNTIME_DIR/hinteros/app-displays"
    fi
    args=()
    count=
    for a in "$@"; do
      if [ "$count" = next ]; then
        a=$((2 + n))
        count=done
      elif [ -z "$count" ] && [ "$a" = --xwayland-count ]; then
        count=next
      fi
      args+=("$a")
    done
    exec "''${args[@]}"
  '';

  greeterOn = config.hinteros.profiles.greeter.enable or false;

  # A new session of the user (greetd restarted, the compositor crashed) may find the previous
  # session's daemon still running: the user manager outlives a session whose scope is still being
  # torn down. That daemon is attached to the old compositor (its Xwayland is gone), so the new
  # session restarts it (try-restart: only if it is running) and the new one takes over focus.
  sessionStart = pkgs.writeShellScript "hinteros-session-start" ''
    ${lib.getExe' config.systemd.package "systemctl"} --user --no-block try-restart hinteros-session.service || true
    exec "$@"
  '';

  # gamescope's Vulkan loader (and its children's: the home app, Xwayland) reads only the
  # system's drivers and implicit layers, in /run/opengl-driver(-32) (hardware.graphics; also
  # where a gamescope WSI layer would be). Not $XDG_DATA_DIRS, $XDG_DATA_HOME or
  # $XDG_CONFIG_DIRS, so no file in a home or a profile can put a library into the compositor.
  # Apps and Steam (and its games) are the session daemon's children, not gamescope's: they keep
  # the loader's defaults. A test VM that picks its driver with VK_ICD_FILENAMES (`environment`)
  # keeps it.
  vulkanEnvironment = lib.optionalAttrs (cfg.compositor == "gamescope") (
    {
      VK_IMPLICIT_LAYER_PATH = lib.concatStringsSep ":" [
        "/run/opengl-driver/share/vulkan/implicit_layer.d"
        "/run/opengl-driver-32/share/vulkan/implicit_layer.d"
      ];
    }
    // lib.optionalAttrs (!(cfg.environment ? VK_ICD_FILENAMES)) {
      VK_DRIVER_FILES = lib.concatStringsSep ":" [
        "/run/opengl-driver/share/vulkan/icd.d"
        "/run/opengl-driver-32/share/vulkan/icd.d"
      ];
    }
  );

  # Nothing greetd runs may write to the VT: greetd connects a session's stdout/stderr to it, so a
  # log line would flash on the TV between two compositors (and scribble over the PAM splash).
  # Every command greetd starts (`greeterScript`, `pickerScript`, `sessionScript`) runs under
  # systemd-cat first: the compositor's and the home app's output is `journalctl -t
  # hinteros-compositor`, the greeter's `-t hinteros-greeter`, the session wrapper's
  # `-t hinteros-session-start`.
  systemdCat = lib.getExe' config.systemd.package "systemd-cat";
  compositorPrefix = [
    systemdCat
    "--identifier"
    "hinteros-compositor"
    (lib.getExe' pkgs.coreutils "env")
  ]
  ++ lib.mapAttrsToList (name: value: "${name}=${value}") (vulkanEnvironment // cfg.environment)
  ++ lib.optional (cfg.compositor == "gamescope") cfg.displayEnvWrapper;

  sessionCommand = lib.escapeShellArgs (
    [ sessionStart ] ++ compositorPrefix ++ compositorCommand.${cfg.compositor} ++ homeCommand
  );

  # The greeter (profiles.md, "The pieces"). greetd runs `greeterLink` as `hinteros-greeter` at
  # boot and whenever a profile's session ends. `hinteros-session greet` takes the fast path
  # into a profile (greetd IPC, no UI) or execs `pickerLink`: the compositor with the launcher in
  # greeter mode, and the session daemon in greeter mode as a child of the greeter session (so it
  # inherits GREETD_SOCK). The profile session it starts is always `sessionLink`.
  daemonExe = lib.getExe config.hinteros.daemon.session.package;
  # No unit supervises the greeter's daemon, so this does (as Restart=on-failure, RestartSec=2 for
  # a profile's): it starts again after a failure while the compositor, this script's PID after
  # the exec, runs. Without it a crash would leave the picker on screen with no input and no login,
  # and the greeter session would never end for greetd to start a new one.
  greeterDaemon = pkgs.writeShellScript "hinteros-greeter-daemon" ''
    compositor=$$
    (
      while :; do
        ${
          lib.optionalString (cfg.compositor == "cage") "DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 "
        }${daemonExe} --greeter --config ${config.hinteros.daemon.sessionConfigFile} && exit 0
        sleep 2
        kill -0 "$compositor" 2>/dev/null || exit 0
      done
    ) &
    exec "$@"
  '';
  pickerCommand = lib.escapeShellArgs (
    compositorPrefix
    ++ [ greeterDaemon ]
    ++ compositorCommand.${cfg.compositor}
    ++ homeCommandWith [ "--greeter" ]
  );
  pickerScript = pkgs.writeShellScript "hinteros-console-picker" "exec ${pickerCommand}";
  greeterScript = pkgs.writeShellScript "hinteros-console-greeter" ''
    exec ${systemdCat} --identifier hinteros-greeter ${daemonExe} greet --config ${config.hinteros.daemon.sessionConfigFile} -- ${consoleDir}/picker
  '';
  greeterLink = "${consoleDir}/greeter";

  # greetd runs the session through /run/current-system, so a session started after a switch
  # (session.restart, a crash) gets the current system's compositor and home app: greetd itself
  # keeps the config it was started with (nixpkgs: restartIfChanged = false).
  sessionLink = "${consoleDir}/session";
  sessionScript = pkgs.writeShellScript "hinteros-console-session" "exec ${
    lib.escapeShellArgs [
      systemdCat
      "--identifier"
      "hinteros-session-start"
    ]
  } ${sessionCommand}";
in
{
  options.hinteros.session = {
    enable = lib.mkEnableOption "the HinterOS console session";

    command = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "The session command (compositor and home app) that greetd runs through \`/run/current-system/hinteros-console/session\`.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "hinteros-p1";
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

    # The mouse pointer (the right stick in keyboard-mode web apps, daemon README "Right-stick
    # pointer"), read from the gamescope 3.16.31 source.
    cursor = {
      hideDelayMs = lib.mkOption {
        type = lib.types.ints.positive;
        default = 86400000;
        description = ''
          gamescope `--hide-cursor-delay` (gamescope's default is 10000; 0 would hide the pointer
          at once). A day: the pointer never fades on inactivity. The session daemon hides it
          itself with `gamescopectl paint_cursor_plane 0` when the D-pad or left stick is used
          in a pointer app and on the way Home from one, and shows it when the right stick moves.
        '';
      };
      scaleHeight = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = 540;
        description = ''
          gamescope `--cursor-scale-height`: the pointer is drawn at gamescope's 36 px base size
          times floor(output height / this), at most 256 px (steamcompmgr.cpp,
          MouseCursor::GetDesiredSize), whatever size the app's cursor image has. 540: 72 px at
          1080p and 1440p, 144 px at 2160p, 36 px at 720p. `null`: the apps' own cursor size.
        '';
      };
      theme = lib.mkOption {
        type = lib.types.str;
        default = "Adwaita";
        description = "Xcursor theme (`XCURSOR_THEME`) for the home app and the apps the session daemon starts.";
      };
      # Its share/icons goes on XCURSOR_PATH.
      package = lib.mkPackageOption pkgs "adwaita-icon-theme" { };
      size = lib.mkOption {
        type = lib.types.ints.positive;
        default = 64;
        description = ''
          `XCURSOR_SIZE` for the apps the session daemon starts when `scaleHeight` is `null`.
          With `scaleHeight` they get 256, as gamescope gives its own children (main.cpp: "We
          always want the biggest cursor size so we can scale it"): Xcursor picks the theme's
          largest image and gamescope scales it to the size above.
        '';
      };
      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        readOnly = true;
        internal = true;
        description = "The Xcursor variables for gamescope sessions (from the options above).";
        default = {
          XCURSOR_THEME = cfg.cursor.theme;
          XCURSOR_PATH = "${cfg.cursor.package}/share/icons:/run/current-system/sw/share/icons";
          XCURSOR_SIZE = toString (if cfg.cursor.scaleHeight != null then 256 else cfg.cursor.size);
        };
        defaultText = lib.literalMD "from `theme`, `package`, `size` and `scaleHeight`";
      };
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
      appDisplays = lib.mkOption {
        type = lib.types.ints.between 1 8;
        default = 4;
        description = ''
          How many app displays (Xwaylands :2 and up, one per running app the session daemon
          starts) a session gets when its profile has not chosen (Settings, `apps.displays.set`,
          read at each session start). gamescope starts with `--xwayland-count` 2 + that
          number. Each idle Xwayland costs some memory.
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
      # A pointer theme with large images (gamescope sets XCURSOR_SIZE for its own children
      # when it scales the pointer). The daemon's apps get the same (daemon.nix).
      (lib.mkIf (cfg.compositor == "gamescope") (lib.mapAttrs (_: lib.mkDefault) cfg.cursor.environment))
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

    # Autologin: the session user holds the devices through static groups. With the greeter
    # (profiles.nix) no account has them: logind's uaccess gives them to the active session.
    # Never `input`: it reads every keyboard (the admin password on the admin console). The
    # compositor gets its input devices from logind (TakeDevice), joysticks are uaccess, and
    # Ctrl+Super+D is the hinteros-keyboard unit's (daemon.nix).
    users.users.${cfg.user} = {
      isNormalUser = true;
      extraGroups = lib.optionals (!greeterOn) [
        "video"
        "uinput" # the daemon injects key presses for keyboard-driven apps
      ];
    };

    services.greetd = {
      enable = true;
      settings =
        if greeterOn then
          {
            # No initial_session: the greeter decides (and its config does not depend on the
            # account list, so creating a profile never restarts greetd).
            default_session = {
              command = greeterLink;
              user = config.hinteros.profiles.greeter.user;
            };
          }
        else
          rec {
            initial_session = {
              command = sessionLink;
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

    hinteros.session.command = sessionCommand;

    environment.systemPackages = [ cfg.gamescope.package ];

    system.systemBuilderCommands = ''
      mkdir -p $out/hinteros-console
      ln -s ${lib.getExe cfg.homeApp} $out/hinteros-console/home
      ln -s ${sessionScript} $out/hinteros-console/session
    ''
    + lib.optionalString greeterOn ''
      ln -s ${greeterScript} $out/hinteros-console/greeter
      ln -s ${pickerScript} $out/hinteros-console/picker
    '';
  };
}
