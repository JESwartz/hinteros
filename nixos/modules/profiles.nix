# Profiles: one Unix user per account, the guest, and the
# greeter mode with the PAM stack that enforces PINs and the kill on switch, plus device access
# per seat (uaccess) instead of static groups.
#
# Accounts come from state.json `profiles` (state.nix): `p<N>` is `hinteros-p<N>` with uid
# 20000+N. Each is a normal user in the `hinteros` group and nothing else, home 0700, no
# password. Whether an account is a *profile* (name, PIN, lock flag) is
# hinteros-system's business (/var/lib/hinteros/profiles.json); nothing here depends on it, and
# nothing generated from the account list changes greetd's, gamescope's or the session daemon's
# units, so creating or removing an account does not restart the running session.
#
# Two session modes:
#   - `greeter.enable = true` (the default with a state): greetd runs the greeter
#     (`hinteros-greeter`) at boot and whenever a profile's session ends; profile sessions go
#     through the PAM stack below; devices follow the active session (logind uaccess), and every
#     per-user grant is written against the group;
#   - `greeter.enable = false` (test VMs): autologin of the first account, which keeps the static
#     device groups.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hinteros.profiles;
  inherit (config.hinteros.daemon) group;
  sessionCfg = config.hinteros.session;
  greeterOn = cfg.greeter.enable;
  systemdPkg = config.systemd.package;

  # Fixed, like the guest's (stable across rollbacks and export/restore).
  userFor = id: "hinteros-${id}";
  uidFor = id: 20000 + lib.toInt (lib.removePrefix "p" id);

  # The PAM helper (profiles.md, "PAM: where the PIN and the kill are enforced"): a subcommand of
  # hinteros-system. pam_exec runs it with an empty PATH.
  pin = "${lib.getExe config.hinteros.daemon.system.package} pin";

  # The handover splash draws in the launcher's typeface: Atkinson Hyperlegible Bold, the
  # launcher's bundled assets/fonts file (byte-identical to nixpkgs' 2021 release).
  splash = "${pin} splash --font ${pkgs.atkinson-hyperlegible}/share/fonts/opentype/AtkinsonHyperlegible-Bold.otf";

  # The session part of NixOS' login stack that a console session needs. No pam_limits: NixOS has
  # no /etc/security/limits.conf (its stacks name a generated file), and a `required` module that
  # cannot read its config fails pam_open_session, so greetd could start no session at all.
  sessionTail = ''
    session  required   pam_env.so conffile=/etc/pam/environment readenv=0
    session  required   pam_unix.so
    session  required   pam_loginuid.so
    session  optional   ${systemdPkg}/lib/security/pam_systemd.so
  '';

  accountUsers = map (a: userFor a.id) cfg.accounts;
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
          };
        }
      );
      default = [ { id = "p1"; } ];
      description = "The profile accounts (state.json `profiles`); `p<N>` is the Unix user `hinteros-p<N>`.";
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
        description = "The guest account (state.json `settings.guest.enable`, default true there): a temporary profile whose home is emptied at every boot.";
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
        default = config.hinteros.state != null;
        defaultText = lib.literalExpression "config.hinteros.state != null";
        description = ''
          The greeter session (the profile picker) instead of autologin, with the PIN and
          end-others PAM stack and uaccess device access. On for every device; test VMs without
          a state keep autologin.
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
        ];

        # The text console: the handover splash no longer uses it (it draws on the framebuffer), but
        # a text console is still what the TV shows for the root terminal on Ctrl+Alt+F2 (where
        # `hinteros-system reset-pin` is typed), the splash's console-text fallback (no
        # framebuffer) and early boot. Terminus 16x32 (120x33 cells at 1920x1080) reads from a
        # couch; the kernel's 8x16 (240x67) does not. Set once in the initrd (`earlySetup`, after
        # the GPU's KMS driver, which facter puts there too): the stage-2 systemd-vconsole-setup
        # (re-run by udev for every vtcon) sets the same font again, so fbcon never re-lays out and
        # redraws tty1 in the middle of the boot, under the "HinterOS" splash.
        console = {
          font = lib.mkDefault "ter-v32b";
          packages = [ pkgs.terminus_font ];
          earlySetup = lib.mkDefault true;
        };

        # Autologin (and the boot-health check) use the first account.
        hinteros.session.user = lib.mkDefault (
          if cfg.accounts == [ ] then "hinteros-p1" else userFor (builtins.head cfg.accounts).id
        );

        users.users = lib.listToAttrs (
          map (
            a:
            lib.nameValuePair (userFor a.id) {
              isNormalUser = true;
              uid = uidFor a.id;
              homeMode = "700";
              extraGroups = [ group ];
            }
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
        # First of all, `splash` shows the launcher's "Loading <name>…" page on greetd's VT
        # (PAM_TTY): between the last frame of the picker and the first of the session (~2 s on
        # real hardware) the framebuffer of that VT is what the TV shows. The helper starts a
        # detached painter (VT in graphics mode, /dev/fb0 repainted until the next compositor
        # holds the VT, at most 5 s) and returns at once; console text without a framebuffer.
        # Optional, and the helper always exits 0 for it: a splash never stops a login. The
        # greeter's stack has it too (just "HinterOS", on the way back to the picker).
        security.pam.services = {
          greetd.text = lib.mkForce ''
            auth     requisite  pam_succeed_if.so user ingroup ${group}
            auth     [success=done default=ignore] pam_exec.so quiet ${pin} unlocked
            auth     required   pam_exec.so quiet stdout expose_authtok ${pin} verify
            auth     required   pam_permit.so
            account  required   pam_unix.so
            session  optional   pam_exec.so quiet ${splash}
            session  required   pam_exec.so quiet ${pin} end-others
            ${sessionTail}
          '';
          # The greeter's own session: a leaving profile is gone before the picker starts. Optional
          # here (a failing helper must not leave the box without a picker); the profile session's
          # line above is the one that must hold.
          greetd-greeter.text = lib.mkForce ''
            auth     required   pam_permit.so
            account  required   pam_unix.so
            session  optional   pam_exec.so quiet ${splash}
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
        # joysticks are uaccess in systemd's own rules; uinput is not. The tag must be set before
        # systemd's 71-seat.rules and 73-seat-late.rules (which run the `uaccess` builtin for tagged
        # devices), so not in extraRules (99-local.rules): there it came too late and /dev/uinput
        # never got an ACL (VM profiles-switch).
        # Keyboards never: no profile may read one (a game could log the admin password typed
        # into the launcher's prompt or on the admin console). Ctrl+Super+D is read by the
        # hinteros-keyboard system unit (daemon.nix). An fd opened before a switch stays open
        # (logind cannot revoke it), so hinteros-system freezes a profile whose session is not
        # the active one (--freeze-inactive).
        services.udev.packages = [
          (pkgs.writeTextDir "lib/udev/rules.d/70-hinteros-uinput.rules" ''
            KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"
          '')
        ];

        # The greeter reads the public view the service writes at start; the console font is set
        # before the first splash (no vconsole setup on tty1 while it paints).
        systemd.services.greetd = {
          after = [
            "hinteros-system.service"
            "systemd-vconsole-setup.service"
          ];
          wants = [ "hinteros-system.service" ];
        };
      })
    ]
  );
}
