# Hardening baseline (hinteros-docs/design/threat-model.md, "What must change ... before a box is
# given out"; system-api.md, "Required changes elsewhere"). On with the session. Anything that
# would make the session user (so: any game or web page) root, or let it reach the nix daemon
# as a trusted user, is a build error unless `hinteros.dev.enable` is set, and that option only
# ever adds a separate `deploy` user, never privileges for the session user.
{
  config,
  lib,
  ...
}:
let
  cfg = config.hinteros;
  sessionUser = cfg.session.user;
  dev = cfg.dev.enable;
  adminCfg = cfg.admin;
  admin = adminCfg.enable;
  adminUser = adminCfg.user;

  # Every user (other than root) that is a wheel member, by either route.
  wheelUsers =
    lib.filter (n: n != "root") (
      lib.attrNames (
        lib.filterAttrs (_: u: u.isNormalUser || u.isSystemUser) (
          lib.filterAttrs (_: u: u.group == "wheel" || lib.elem "wheel" u.extraGroups) config.users.users
        )
      )
    )
    ++ lib.filter (n: n != "root") config.users.groups.wheel.members;

  sudoRuleOptions = lib.concatMap (
    r: lib.concatMap (c: c.options or [ ]) r.commands
  ) config.security.sudo.extraRules;
in
{
  options.hinteros = {
    admin = {
      enable = lib.mkEnableOption "an optional admin account (wheel, sudo always asks for its password, never NOPASSWD). Off by default; the first-boot wizard sets the password (M9)";

      user = lib.mkOption {
        type = lib.types.str;
        default = "hinteros-admin";
        description = "Name of the admin account.";
      };

      hashedPasswordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "File holding the admin's hashed password (mkpasswd output). Never commit a password; required when the admin is enabled.";
      };

    };

    ssh.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Run sshd (set from state.json `settings.ssh.enable`; hinteros-system gates flipping it behind the admin password via polkit `org.hinteros.system.ssh`, defined in daemon.nix). Needs hinteros.admin: the admin account is the only login.";
    };

    dev = {
      enable = lib.mkEnableOption ''
        dev conveniences, the only way to get them: a separate `deploy` user (wheel, passwordless
        sudo, nix trusted user, SSH key-only) for `nixos-rebuild --target-host deploy@box --sudo`.
        The session user stays unprivileged. Never set this on a box that leaves the house'';

      deployKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "ssh-ed25519 AAAA... you@desktop" ];
        description = ''
          SSH public keys allowed to log in as `deploy`. Empty on purpose: add your own key in the
          dev device's config (devices/devbox/default.nix). Plain `ssh-` key lines only.
        '';
      };
    };
  };

  config = lib.mkIf cfg.session.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = dev || lib.subtractLists (lib.optional admin adminUser) wheelUsers == [ ];
            message = "hinteros hardening: users in wheel (${lib.concatStringsSep ", " wheelUsers}) without hinteros.dev.enable; only the optional admin account (hinteros.admin) may be, and only with a sudo password.";
          }
          {
            assertion = !admin || adminCfg.hashedPasswordFile != null;
            message = "hinteros hardening: hinteros.admin.enable needs hinteros.admin.hashedPasswordFile (no password, no admin).";
          }
          {
            assertion =
              dev || !config.services.openssh.enable || (admin && adminCfg.hashedPasswordFile != null);
            message = "hinteros hardening: SSH is enabled but hinteros.admin is not (enable it with hashedPasswordFile); the admin is the only SSH login.";
          }
          {
            assertion = adminUser != sessionUser;
            message = "hinteros hardening: the admin account must not be the session user.";
          }
          {
            assertion = dev || config.security.sudo.wheelNeedsPassword;
            message = "hinteros hardening: passwordless wheel sudo without hinteros.dev.enable.";
          }
          {
            assertion =
              dev
              || !(
                lib.elem "NOPASSWD" sudoRuleOptions || lib.hasInfix "NOPASSWD" config.security.sudo.extraConfig
              );
            message = "hinteros hardening: NOPASSWD sudo rule without hinteros.dev.enable.";
          }
          {
            assertion = dev || lib.unique config.nix.settings.trusted-users == [ "root" ];
            message = "hinteros hardening: nix trusted-users is ${builtins.toJSON config.nix.settings.trusted-users}; only root without hinteros.dev.enable (trusted users are root-equivalent).";
          }
          {
            assertion = !(lib.elem sessionUser config.nix.settings.trusted-users);
            message = "hinteros hardening: the session user must not be a nix trusted user, even in dev.";
          }
          {
            assertion = !(lib.elem sessionUser wheelUsers);
            message = "hinteros hardening: the session user must not be in wheel, even in dev; deploy as `deploy`.";
          }
          {
            assertion = !(lib.elem "systemd-journal" config.users.users.${sessionUser}.extraGroups);
            message = "hinteros hardening: the session user must not read the system journal (audit trail).";
          }
          {
            assertion = lib.all (k: !lib.hasPrefix "/nix/store" k.path) config.services.openssh.hostKeys;
            message = "hinteros hardening: SSH host keys must be generated on the box, never live in the store.";
          }
        ];

        # The session never needs nix; only root (and, in dev, the deploy user) talks to the daemon.
        nix.settings = {
          trusted-users = [ "root" ];
          allowed-users = lib.mkDefault [ "root" ];
        };

        # Physical access must not mean root: no boot menu editing (init=/bin/sh). The one place
        # this is set.
        boot.loader.systemd-boot.editor = false;

        # Only root (and the optional admin) approve polkit actions; no auth agent, so auth_admin
        # fails closed for the session.
        security.polkit.adminIdentities = [ "unix-user:0" ] ++ lib.optional admin "unix-user:${adminUser}";

        # No setuid sudo at all unless dev.
        security.sudo.enable = lib.mkDefault admin;

        # The audit trail survives reboots; capped so it can't fill the disk.
        services.journald.settings.Journal = {
          Storage = "persistent";
          SystemMaxUse = "500M";
          SystemKeepFree = "1G";
          MaxRetentionSec = "3month";
        };
      }

      (lib.mkIf cfg.ssh.enable { services.openssh.enable = true; })

      # SSH, whoever enabled it (state.json, or dev). Plain username + password for now; key-only,
      # key import, a LAN-only firewall and rate limiting are backlog.
      (lib.mkIf config.services.openssh.enable {
        services.openssh = {
          openFirewall = lib.mkDefault true;
          # Host keys: the NixOS default (/etc/ssh, generated on first start, per box).
          settings = {
            PasswordAuthentication = true;
            KbdInteractiveAuthentication = false;
            PermitRootLogin = "no";
            MaxAuthTries = 3;
            # The session user is never allowed over SSH; only the admin (and, in dev, deploy).
            AllowUsers = lib.optional admin adminUser ++ lib.optional dev "deploy";
            AllowTcpForwarding = false;
            AllowAgentForwarding = false;
            X11Forwarding = false;
          };
        };
      })

      (lib.mkIf admin {
        users.users.${adminUser} = {
          isNormalUser = true;
          description = "HinterOS admin";
          extraGroups = [ "wheel" ];
          inherit (adminCfg) hashedPasswordFile;
        };
        security.sudo.enable = true;
      })

      (lib.mkIf dev {
        warnings = [
          "hinteros.dev.enable is set: the `deploy` user has passwordless root and is a nix trusted user. This build must never leave the house."
        ]
        ++ lib.optional (
          cfg.dev.deployKeys == [ ]
        ) "hinteros.dev.deployKeys is empty: nobody can deploy to this box over SSH.";

        users.users.deploy = {
          isNormalUser = true;
          description = "Dev deploy user (nixos-rebuild --target-host)";
          extraGroups = [ "wheel" ];
          openssh.authorizedKeys.keys = cfg.dev.deployKeys;
        };

        security.sudo = {
          enable = true;
          wheelNeedsPassword = false;
        };
        nix.settings = {
          trusted-users = [ "deploy" ];
          allowed-users = [ "@wheel" ];
        };

        # Deploys need sshd even if state.json has SSH off.
        services.openssh.enable = lib.mkDefault true;
      })
    ]
  );
}
