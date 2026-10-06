# HinterOS daemons (see hinteros-docs/design/api.md):
#   hinteros-session: systemd user service of the session user, serves the session API on
#                     $XDG_RUNTIME_DIR/hinteros/session.sock (0600), which the launcher talks to.
#   hinteros-system:  privileged system service, serves the internal system API on
#                     /run/hinteros/system.sock (0660, group `hinteros`) to the session daemon.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hinteros.daemon;
  sessionUser = config.hinteros.session.user;
  toml = pkgs.formats.toml { };
  sessionConfig = toml.generate "hinteros-session.toml" cfg.session.settings;
in
{
  options.hinteros.daemon = {
    enable = lib.mkEnableOption "the HinterOS session daemon and system service";

    group = lib.mkOption {
      type = lib.types.str;
      default = "hinteros";
      description = "Group that owns the system socket; the session user is a member.";
    };

    session.package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.hinteros-session;
      defaultText = lib.literalExpression "pkgs.hinteros-session";
      description = "Package providing the `hinteros-session` binary.";
    };

    system.package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.hinteros-system;
      defaultText = lib.literalExpression "pkgs.hinteros-system";
      description = "Package providing the `hinteros-system` binary.";
    };

    session.settings = lib.mkOption {
      inherit (toml) type;
      default = { };
      example = lib.literalExpression ''
        {
          steam.autostart = true;
          apps = [ { id = "jellyfin"; name = "Jellyfin"; command = [ "jellyfin-desktop" ]; } ];
        }
      '';
      description = ''
        Contents of the session daemon's `session.toml` (see the hinteros-daemon README), as a
        Nix attribute set. The file is generated into the store and passed with `--config`.
        The module already sets `launcher.app_id`, `gamescope.*`, `osk.*`, `steam.path`, `steam.tag_windows`,
        `steam.library_poll_s`, `steam.library_debounce_ms` and `close.timeout_ms` (all with
        `mkDefault`; `steam.dir` is left to the daemon's default unless a test sets it).
      '';
    };

    # The on-screen keyboard: a second entrypoint of the launcher (`hinteros-osk`), started and
    # restarted by the session daemon and shown as a gamescope overlay (spike 5).
    osk = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run the on-screen keyboard (`[osk] enable`); Guide+Y or `osk.show` summons it.";
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.hinteros-launcher;
        defaultText = lib.literalExpression "pkgs.hinteros-launcher";
        description = "Package providing `bin/hinteros-osk` (the launcher ships it).";
      };
      summon = lib.mkOption {
        type = lib.types.str;
        default = "guide+context";
        example = "none";
        description = ''
          Controller chord that toggles the keyboard: `guide+<button>` (hold Guide, press the
          button; `context` is Y) or `none`. With a chord, Home fires on Guide release; `none`
          puts it back on the press.
        '';
      };
    };

    logLevel = lib.mkOption {
      type = lib.types.str;
      default = "info";
      example = "debug";
      description = "`RUST_LOG` filter for both daemons.";
    };
  };

  config = lib.mkIf cfg.enable {
    hinteros.daemon.session.settings = {
      launcher.app_id = lib.mkDefault config.hinteros.session.launcherAppId;
      # The cage fallback (VM) has no gamescope to drive.
      gamescope = {
        enable = lib.mkDefault (config.hinteros.session.compositor == "gamescope");
        # gamescope's Xwayland and Wayland socket; a user service does not inherit them.
        display = lib.mkDefault ":0";
        wayland_display = lib.mkDefault (
          if config.hinteros.session.compositor == "gamescope" then "gamescope-0" else "wayland-0"
        );
      };
      osk = {
        inherit (cfg.osk) enable summon;
        command = lib.mkDefault [ "${cfg.osk.package}/bin/hinteros-osk" ];
      };
      steam = {
        # Steam's own windows get STEAM_GAME=769 so gamescope can show them (needs gamescope).
        tag_windows = lib.mkDefault true;
        library_poll_s = lib.mkDefault 60;
        library_debounce_ms = lib.mkDefault 500;
        path = lib.mkIf config.programs.steam.enable (
          lib.mkDefault (lib.getExe config.programs.steam.package)
        );
      };
      close.timeout_ms = lib.mkDefault 5000;
    };

    users.groups.${cfg.group} = { };
    users.users.${sessionUser}.extraGroups = [ cfg.group ];

    systemd.services.hinteros-system = {
      description = "HinterOS system service";
      wantedBy = [ "multi-user.target" ];
      environment.RUST_LOG = cfg.logLevel;
      serviceConfig = {
        ExecStart = lib.getExe cfg.system.package;
        # Root, because it will rebuild the system and manage settings (M5). The socket is
        # created in the runtime directory, owned by root:hinteros, mode 0660.
        User = "root";
        Group = cfg.group;
        RuntimeDirectory = "hinteros";
        RuntimeDirectoryMode = "0755";
        Restart = "on-failure";
        RestartSec = 2;
        # Reasonable baseline. Tighten as the service gains real work; it will need to write
        # /etc/hinteros and run nixos-rebuild, so no ProtectSystem=strict yet.
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        RestrictRealtime = true;
        LockPersonality = true;
        UMask = "0007";
      };
    };

    # User unit: applies to every user's manager, so restrict it to the session user.
    # It is wanted by default.target, which the user manager reaches at autologin, i.e. at
    # the same time as the compositor and home app start.
    systemd.user.services.hinteros-session = {
      description = "HinterOS session daemon";
      wantedBy = [ "default.target" ];
      unitConfig.ConditionUser = sessionUser;
      environment = {
        RUST_LOG = cfg.logLevel;
      }
      # Under cage the daemon sees no gamescope (so no child_env) and apps it launches inherit
      # its environment: point them at cage's Xwayland (its first X display) and socket.
      // lib.optionalAttrs (config.hinteros.session.compositor == "cage") {
        DISPLAY = ":0";
        WAYLAND_DISPLAY = "wayland-0";
      };
      serviceConfig = {
        ExecStart = "${lib.getExe cfg.session.package} --config ${sessionConfig}";
        Restart = "on-failure";
        RestartSec = 1;
        NoNewPrivileges = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        LockPersonality = true;
      };
    };
  };
}
