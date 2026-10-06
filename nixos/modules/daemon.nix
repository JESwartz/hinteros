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

    logLevel = lib.mkOption {
      type = lib.types.str;
      default = "info";
      example = "debug";
      description = "`RUST_LOG` filter for both daemons.";
    };
  };

  config = lib.mkIf cfg.enable {
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
      environment.RUST_LOG = cfg.logLevel;
      serviceConfig = {
        ExecStart = lib.getExe cfg.session.package;
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
