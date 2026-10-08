# Profiles (hinteros-docs/design/profiles.md): one Unix user per account, the guest, and the
# greeter mode with the PAM stack that enforces PINs and the kill on switch, plus device access
# per seat (uaccess) instead of static groups.
#
# Accounts come from state.json `profiles` (state.nix): `p1` is `hinteros`, `p<N>` is
# `hinteros-p<N>` with uid 20000+N. Each is a normal user in the `hinteros` group and nothing
# else, home 0700, no password. Whether an account is a *profile* (name, PIN, lock flag) is
# hinteros-system's business (/var/lib/hinteros/profiles.json); nothing here depends on it, and
# nothing generated from the account list changes greetd's, gamescope's or the session daemon's
# units, so creating or removing an account does not restart the running session.
#
# Two session modes:
#   - `greeter.enable = false` (the default on schema 1, i.e. until the box has migrated):
#     autologin of the first account, which keeps the static device groups;
#   - `greeter.enable = true` (the default on schema 2): greetd runs the greeter (`hinteros-greeter`) at boot and whenever a
#     profile's session ends; profile sessions go through the PAM stack below; devices follow the
#     active session (logind uaccess), and every per-user grant is written against the group.
{
  config,
  lib,
  ...
}:
let
  cfg = config.hinteros.profiles;
  inherit (config.hinteros.daemon) group;
  sessionCfg = config.hinteros.session;
  greeterOn = cfg.greeter.enable;
  systemdPkg = config.systemd.package;

  # p1 keeps its auto-allocated uid (existing boxes); every later account and the guest get a
  # fixed one (stable across rollbacks and export/restore).
  uidFor = id: if id == "p1" then null else 20000 + lib.toInt (lib.removePrefix "p" id);

  # The PAM helper (profiles.md, "PAM: where the PIN and the kill are enforced"): a subcommand of
  # hinteros-system. pam_exec runs it with an empty PATH.
  pin = "${lib.getExe config.hinteros.daemon.system.package} pin";

  # The session part of NixOS' login stack that a console session needs. No pam_limits: NixOS has
  # no /etc/security/limits.conf (its stacks name a generated file), and a `required` module that
  # cannot read its config fails pam_open_session, so greetd could start no session at all.
  sessionTail = ''
    session  required   pam_env.so conffile=/etc/pam/environment readenv=0
    session  required   pam_unix.so
    session  required   pam_loginuid.so
    session  optional   ${systemdPkg}/lib/security/pam_systemd.so
  '';

  accountUsers = map (a: a.user) cfg.accounts;
in
{
  options.hinteros.profiles = {
    accounts = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            id = lib.mkOption {
              type = lib.types.strMatching "p[1-9][0-9]{0,2}";
              description = "Profile id.";
            };
            user = lib.mkOption {
              type = lib.types.str;
              description = "Unix user: `hinteros` for p1, `hinteros-p<N>` otherwise.";
            };
          };
        }
      );
      default = [
        {
          id = "p1";
          user = "hinteros";
        }
      ];
      description = "The profile accounts (state.json `profiles`; schema 1: p1 only).";
    };

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = accountUsers ++ lib.optional cfg.guest.enable cfg.guest.user;
      defaultText = lib.literalMD "the accounts' users, and the guest's";
      description = "Every user that may be on screen (all members of the `hinteros` group).";
    };

    guest = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "The guest account (state.json schema 2 `settings.guest.enable`, default true there): a temporary profile whose home is emptied at every boot.";
      };
      user = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "hinteros-guest";
        description = "The guest's user (uid 20000).";
      };
    };

    greeter = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = config.hinteros.appEnv.perProfile or false;
        defaultText = lib.literalExpression "config.hinteros.appEnv.perProfile";
        description = ''
          The greeter session (the profile picker) instead of autologin, with the PIN and
          end-others PAM stack and uaccess device access. On by default on schema 2 (profiles);
          a schema-1 box keeps autologin until its migration switches it to schema 2. The
          migration's switch does not restart greetd (nixpkgs: restartIfChanged = false), so
          the running session stays; the picker comes at the next boot or session end, where
          the migrated p1 (unlocked, no PIN yet) is entered without a PIN.
        '';
      };
      user = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "hinteros-greeter";
        description = "System user of the greeter session (not in `hinteros`, no login shell).";
      };
    };
  };

  config = lib.mkIf sessionCfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = lib.unique (map (a: a.id) cfg.accounts) == map (a: a.id) cfg.accounts;
            message = "hinteros.profiles.accounts: duplicate ids";
          }
          {
            assertion = lib.all (a: a.user == (if a.id == "p1" then "hinteros" else "hinteros-${a.id}")) (
              lib.filter (a: a.id != "p1") cfg.accounts
            );
            message = "hinteros.profiles.accounts: p<N> (N > 1) must be user hinteros-p<N>";
          }
        ];

        # Autologin (and the boot-health check) use the first account.
        hinteros.session.user = lib.mkDefault (
          if cfg.accounts == [ ] then "hinteros" else (builtins.head cfg.accounts).user
        );

        users.users = lib.listToAttrs (
          map (
            a:
            lib.nameValuePair a.user (
              {
                isNormalUser = true;
                homeMode = "700";
                extraGroups = [ group ];
              }
              // lib.optionalAttrs (uidFor a.id != null) { uid = uidFor a.id; }
            )
          ) cfg.accounts
        );
      }

      # The guest: its home lives on disk (Steam games need the space) and is emptied at every
      # boot (`D!`, which never follows symlinks); its app env is a link under /run (app-env.nix).
      (lib.mkIf cfg.guest.enable {
        users.users.${cfg.guest.user} = {
          isNormalUser = true;
          uid = 20000;
          homeMode = "700";
          extraGroups = [ group ];
        };
        systemd.tmpfiles.rules = [ "D! /home/${cfg.guest.user} 0700 ${cfg.guest.user} users -" ];
      })

      (lib.mkIf greeterOn {
        # DECISIONS D2/D8: the profile session the greeter starts over greetd IPC.
        hinteros.daemon.session.settings.greeter.session_command = [
          "/run/current-system/hinteros-console/session"
        ];
      })

      (lib.mkIf greeterOn {
        users.users.${cfg.greeter.user} = {
          isSystemUser = true;
          group = cfg.greeter.user;
          home = "/var/lib/${cfg.greeter.user}";
          createHome = true;
        };
        users.groups.${cfg.greeter.user} = { };

        # The profile sessions (greetd's `greetd` service): hinteros members only (never the admin
        # account or root); no PIN when the helper says the profile may be entered without one
        # (unlocked, the guest, a one-time token, the spare in first-boot mode), else the PIN;
        # pam_permit for setcred (spike 7). Before pam_systemd opens the session, every other
        # account's processes are ended (spike 7: logind alone leaves SIGTERM-ignoring ones).
        security.pam.services = {
          greetd.text = lib.mkForce ''
            auth     requisite  pam_succeed_if.so user ingroup ${group}
            auth     [success=done default=ignore] pam_exec.so quiet ${pin} unlocked
            auth     required   pam_exec.so quiet stdout expose_authtok ${pin} verify
            auth     required   pam_permit.so
            account  required   pam_unix.so
            session  required   pam_exec.so quiet ${pin} end-others
            ${sessionTail}
          '';
          # The greeter's own session: a leaving profile is gone before the picker starts. Optional
          # here (a failing helper must not leave the box without a picker); the profile session's
          # line above is the one that must hold.
          greetd-greeter.text = lib.mkForce ''
            auth     required   pam_permit.so
            account  required   pam_unix.so
            session  optional   pam_exec.so quiet ${pin} end-others
            ${sessionTail}
          '';
        };

        # spike 7: a closed session's processes end about 140 ms later; `end-others` handles the
        # ones that ignore SIGTERM. No lingering user managers.
        services.logind.settings.Login = {
          KillUserProcesses = true;
          UserStopDelaySec = 0;
        };

        security.polkit.extraConfig = ''
          // A profile cannot keep a user manager running after its session ends.
          polkit.addRule(function (action, subject) {
            if (action.id == "org.freedesktop.login1.set-self-linger" && subject.isInGroup("${group}")) {
              return polkit.Result.NO;
            }
          });
        '';

        # Devices follow the active session: logind moves the ACLs at every switch. DRM and
        # joysticks are uaccess in systemd's own rules; uinput is not.
        services.udev.extraRules = ''
          KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"
        '';

        # The greeter reads the public view the service writes at start.
        systemd.services.greetd = {
          after = [ "hinteros-system.service" ];
          wants = [ "hinteros-system.service" ];
        };
      })
    ]
  );
}
