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

  # Every account that may be on screen (profiles.nix), and the session user.
  profileUsers = lib.unique ([ sessionUser ] ++ (cfg.profiles.users or [ ]));
  greeterOn = cfg.profiles.greeter.enable or false;
  # With the greeter, devices follow the active session (uaccess); nobody holds them by group.
  deviceGroups = [
    "video"
    "input"
    "uinput"
    "inputplumber"
  ];
  groupsOf =
    u:
    (config.users.users.${u}.extraGroups or [ ])
    ++ lib.filter (g: lib.elem u (config.users.groups.${g}.members or [ ])) (
      lib.attrNames config.users.groups
    );
  inDeviceGroups = lib.filter (u: lib.intersectLists deviceGroups (groupsOf u) != [ ]) (
    lib.attrNames (lib.filterAttrs (_: u: u.isNormalUser) config.users.users)
  );

  # The networks that may reach sshd (hinteros.ssh.allowFrom), split by family.
  sshFrom6 = lib.filter (lib.hasInfix ":") cfg.ssh.allowFrom;
  sshFrom4 = lib.filter (s: !lib.hasInfix ":" s) cfg.ssh.allowFrom;
  sshPorts = map toString config.services.openssh.ports;
  isCidr =
    s:
    builtins.match "[0-9]{1,3}(\\.[0-9]{1,3}){3}/[0-9]{1,2}" s != null
    || builtins.match "[0-9a-fA-F:]*:[0-9a-fA-F:]*/[0-9]{1,3}" s != null;

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

    ssh.allowFrom = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "10.0.0.0/8"
        "172.16.0.0/12"
        "192.168.0.0/16"
        "169.254.0.0/16"
        "fc00::/7"
        "fe80::/10"
      ];
      example = [
        "0.0.0.0/0"
        "::/0"
      ];
      description = ''
        Source networks (IPv4 and IPv6 CIDR) the firewall lets reach sshd. Default: the local
        networks only (RFC 1918, IPv4 link-local, IPv6 ULA and link-local). sshd's own
        `openFirewall` stays off, so nothing else opens its port. `[ "0.0.0.0/0" "::/0" ]` opens
        it to all networks.
      '';
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
            assertion = !(lib.elem adminUser profileUsers);
            message = "hinteros hardening: the admin account must not be a profile's account.";
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
            assertion = lib.intersectLists profileUsers config.nix.settings.trusted-users == [ ];
            message = "hinteros hardening: no profile account may be a nix trusted user, even in dev.";
          }
          {
            assertion = lib.intersectLists profileUsers wheelUsers == [ ];
            message = "hinteros hardening: no profile account may be in wheel, even in dev; deploy as `deploy`.";
          }
          {
            assertion = lib.all (u: !(lib.elem "systemd-journal" (groupsOf u))) profileUsers;
            message = "hinteros hardening: no profile account may read the system journal (audit trail).";
          }
          {
            assertion = lib.all (u: !(lib.elem "input" (groupsOf u))) profileUsers;
            message = "hinteros hardening: no profile account may be in group input, even in dev: it reads every keyboard (the admin password). Ctrl+Super+D is the hinteros-keyboard unit's.";
          }
          {
            assertion = dev || !greeterOn || inDeviceGroups == [ ];
            message = "hinteros hardening: users in device groups (${lib.concatStringsSep ", " inDeviceGroups}) with the greeter; devices follow the active session (uaccess).";
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

        # Only root (and the optional admin) approve polkit actions; without an auth agent, auth_admin
        # fails closed for the session unless the session daemon's polkit agent (hinteros-session, API
        # 0.8) answers the prompt: it only talks to the launcher, only for requests it relayed.
        security.polkit.adminIdentities = [ "unix-user:0" ] ++ lib.optional admin "unix-user:${adminUser}";

        # No setuid sudo at all unless dev.
        security.sudo.enable = lib.mkDefault admin;

        # Kernel attack surface for code running as a profile user (games, web pages, apps; the app
        # sandbox's seccomp filter also blocks most of these). Checked against what the box runs:
        # Steam/Proton, gamescope, InputPlumber, pipewire, NetworkManager, nix, systemd and the
        # sandboxed apps use none of io_uring (no liburing in the closure), perf, unprivileged
        # BPF or ptrace of non-descendants (Chromium's crash handler is allowed by
        # PR_SET_PTRACER, which scope 1 honours).
        boot.kernel.sysctl = {
          # Kernel pointers hidden from everyone, also root (default 1: from users).
          "kernel.kptr_restrict" = 2;
          "kernel.dmesg_restrict" = 1;
          # 3: no perf for users at all where the kernel knows it (upstream treats it as 2).
          "kernel.perf_event_paranoid" = 3;
          # 1: off until reboot (the kernel default 2 can be switched back by root).
          "kernel.unprivileged_bpf_disabled" = 1;
          "net.core.bpf_jit_harden" = 2;
          # 2: io_uring off for everyone, root too; nothing on the box uses it.
          "kernel.io_uring_disabled" = 2;
          # Only parents may ptrace (their descendants), not any process of the same user.
          "kernel.yama.ptrace_scope" = 1;
          "fs.protected_hardlinks" = 1;
          "fs.protected_symlinks" = 1;
          # 2: also group-writable sticky directories (systemd's default is 1).
          "fs.protected_fifos" = 2;
          "fs.protected_regular" = 2;
        };

        # The audit trail survives reboots; capped so it can't fill the disk.
        services.journald.settings.Journal = {
          Storage = "persistent";
          SystemMaxUse = "500M";
          SystemKeepFree = "1G";
          MaxRetentionSec = "3month";
        };
      }

      # Less code on the box.
      {
        # setuid helpers nothing here uses (pkexec: PwnKit). sudo stays for the admin, passwd and
        # unix_chkpwd for PAM, mount and umount for users. Root still has the plain `su` on PATH.
        security.wrappers =
          lib.genAttrs
            [
              "pkexec"
              "su"
              "chsh"
              "newgrp"
              "sg"
              "newuidmap"
              "newgidmap"
            ]
            (_: {
              enable = lib.mkDefault false;
            });

        services = {
          # NixOS turns speech-dispatcher on for every graphical system: a socket every app and
          # web page (Firefox Web Speech) can reach, with espeak-ng, mbrola, flite and a full
          # ffmpeg behind it. HinterOS has no text to speech. Set with mkDefault there, so plain
          # false.
          speechd.enable = false;
          # No installer layout uses LVM.
          lvm.enable = lib.mkDefault false;
        };

        # NixOS defaults a TV box does not use: perl, rsync and strace on PATH, man pages, bcache,
        # nixos-build-vms and nixos-option (man-db), and channels (flakes only).
        environment.defaultPackages = lib.mkDefault [ ];
        documentation.man.enable = lib.mkDefault false;
        boot.bcache.enable = lib.mkDefault false;
        system.tools = {
          nixos-build-vms.enable = lib.mkDefault false;
          nixos-option.enable = lib.mkDefault false;
        };
        nix.channel.enable = lib.mkDefault false;
      }

      (lib.mkIf cfg.ssh.enable { services.openssh.enable = true; })

      # SSH, whoever enabled it (state.json, the installer plan, or dev). Plain username + password
      # for now, so the firewall lets only the local networks (hinteros.ssh.allowFrom) reach it;
      # key-only, key import and rate limiting are backlog.
      (lib.mkIf config.services.openssh.enable {
        assertions = [
          {
            assertion = lib.all isCidr cfg.ssh.allowFrom;
            message = "hinteros hardening: hinteros.ssh.allowFrom: every entry must be an IPv4 or IPv6 CIDR (e.g. 192.168.0.0/16, fe80::/10).";
          }
        ];

        # The port is open only to hinteros.ssh.allowFrom, never to all sources.
        networking.firewall = lib.mkMerge [
          (lib.mkIf config.networking.nftables.enable {
            extraInputRules = lib.concatStrings [
              (lib.optionalString (sshFrom4 != [ ]) ''
                ip saddr { ${lib.concatStringsSep ", " sshFrom4} } tcp dport { ${lib.concatStringsSep ", " sshPorts} } accept comment "hinteros-ssh"
              '')
              (lib.optionalString (sshFrom6 != [ ]) ''
                ip6 saddr { ${lib.concatStringsSep ", " sshFrom6} } tcp dport { ${lib.concatStringsSep ", " sshPorts} } accept comment "hinteros-ssh"
              '')
            ];
          })
          (lib.mkIf (!config.networking.nftables.enable) {
            extraCommands = lib.concatStrings (
              lib.concatMap (
                port:
                map (
                  src:
                  "iptables -w -A nixos-fw -p tcp --dport ${port} -s ${src} -m comment --comment hinteros-ssh -j nixos-fw-accept\n"
                ) sshFrom4
                ++ lib.optionals config.networking.enableIPv6 (
                  map (
                    src:
                    "ip6tables -w -A nixos-fw -p tcp --dport ${port} -s ${src} -m comment --comment hinteros-ssh -j nixos-fw-accept\n"
                  ) sshFrom6
                )
              ) sshPorts
            );
          })
        ];

        services.openssh = {
          openFirewall = lib.mkDefault false;
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
