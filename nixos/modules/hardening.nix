# Hardening baseline: what a box needs before it is given out. On with the session. Anything that
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
  # The only groups a profile account may have (an allowlist: disk, kvm, tty and the like are
  # root for every game). `input` never (asserted on its own); device groups only without the
  # greeter (or in dev, where the device-group check is off too).
  profileGroupsOk = [
    cfg.daemon.group
  ]
  ++ lib.optionals (dev || !greeterOn) (lib.remove "input" deviceGroups);
  extraProfileGroups = lib.unique (
    lib.concatMap (u: lib.subtractLists ([ "input" ] ++ profileGroupsOk) (groupsOf u)) profileUsers
  );

  # The networks that may reach sshd (hinteros.ssh.allowFrom).
  localNets = import ../lib/local-networks.nix { inherit lib; };
  sshRule = {
    from = cfg.ssh.allowFrom;
    proto = "tcp";
    ports = config.services.openssh.ports;
    comment = "hinteros-ssh";
  };
  # sshd ports the firewall opens to every source on every interface (a port opened on one
  # interface, such as tailscale0 by server.nix, is that interface's choice).
  sshOpenToAll =
    let
      fw = config.networking.firewall;
    in
    lib.filter (
      p: lib.elem p fw.allowedTCPPorts || lib.any (r: r.from <= p && p <= r.to) fw.allowedTCPPortRanges
    ) config.services.openssh.ports;

  # sudo-rs, and classic sudo should a device module turn it back on.
  sudoRuleOptions = lib.concatMap (r: lib.concatMap (c: c.options or [ ]) r.commands) (
    config.security.sudo.extraRules ++ config.security.sudo-rs.extraRules
  );
  sudoExtraConfig = config.security.sudo.extraConfig + config.security.sudo-rs.extraConfig;
in
{
  options.hinteros = {
    admin = {
      enable = lib.mkEnableOption "an optional admin account (wheel, sudo always asks for its password, never NOPASSWD). Off by default; the installer writes the password hash";

      user = lib.mkOption {
        type = lib.types.str;
        default = "hinteros-admin";
        description = "Name of the admin account.";
      };

      hashedPasswordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "File holding the admin's hashed password (mkpasswd output), applied at every activation (users are immutable with the admin). Never commit a password; required when the admin is enabled.";
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
        Source networks (IPv4 and IPv6 CIDR) the firewall lets reach sshd, and the servers'
        `lan` ports (server.nix). Default: the local networks only (RFC 1918, IPv4 link-local,
        IPv6 ULA and link-local). Static: unlike the `lan` app filter (daemon.nix), it does not
        follow the on-link networks, so a home network on public IPv4 or a client on a global
        IPv6 address is not let in until its prefix is added here. sshd's own
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
            assertion =
              dev || (config.security.sudo.wheelNeedsPassword && config.security.sudo-rs.wheelNeedsPassword);
            message = "hinteros hardening: passwordless wheel sudo without hinteros.dev.enable.";
          }
          {
            assertion =
              dev || !(lib.elem "NOPASSWD" sudoRuleOptions || lib.hasInfix "NOPASSWD" sudoExtraConfig);
            message = "hinteros hardening: NOPASSWD sudo rule without hinteros.dev.enable.";
          }
          {
            assertion = !config.security.sudo.enable;
            message = "hinteros hardening: classic sudo is on; HinterOS uses sudo-rs (security.sudo-rs).";
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
            assertion = extraProfileGroups == [ ];
            message = "hinteros hardening: profile accounts in groups they must not have (${lib.concatStringsSep ", " extraProfileGroups}), even in dev; allowed: ${lib.concatStringsSep ", " profileGroupsOk}.";
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

        # No setuid sudo at all without the admin (or dev). sudo-rs, never classic sudo (on by
        # default in NixOS): memory safe, far fewer features, the same `sudo` command and
        # SUDO_USER (the audit log reads it).
        security = {
          sudo.enable = lib.mkDefault false;
          sudo-rs.enable = lib.mkDefault admin;
        };

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

        # The firewall on nftables, not iptables (the LAN filter's table already is): no iptables
        # tools or legacy rule path. NixOS deletes only its own tables on reload, so the LAN
        # filter's `inet hinteros_lan` stays.
        networking.nftables.enable = lib.mkDefault true;
      }

      (lib.mkIf cfg.ssh.enable { services.openssh.enable = true; })

      # SSH, whoever enabled it (state.json, the installer plan, or dev). Plain username + password
      # for now, so the firewall lets only the local networks (hinteros.ssh.allowFrom) reach it;
      # key-only, key import and rate limiting are backlog.
      (lib.mkIf config.services.openssh.enable {
        assertions = [
          {
            assertion = lib.all localNets.isCidr cfg.ssh.allowFrom;
            message = "hinteros hardening: hinteros.ssh.allowFrom: every entry must be an IPv4 or IPv6 CIDR (e.g. 192.168.0.0/16, fe80::/10).";
          }
          {
            assertion = !config.services.openssh.openFirewall && sshOpenToAll == [ ];
            message = "hinteros hardening: the SSH port is open to all sources (services.openssh.openFirewall or networking.firewall allowed ports${
              lib.optionalString (sshOpenToAll != [ ]) ": ${lib.concatMapStringsSep ", " toString sshOpenToAll}"
            }); set hinteros.ssh.allowFrom instead.";
          }
        ];

        # The port is open only to hinteros.ssh.allowFrom, never to all sources.
        networking.firewall = lib.mkMerge [
          (lib.mkIf config.networking.nftables.enable {
            extraInputRules = localNets.nftRules sshRule;
          })
          (lib.mkIf (!config.networking.nftables.enable) {
            extraCommands = localNets.iptablesRules (sshRule // { ipv6 = config.networking.enableIPv6; });
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
        # Every account is declared. With mutable users NixOS applies hashedPasswordFile only when
        # it creates the account, so a new hash in the file would never reach /etc/shadow. (Not
        # without the admin: NixOS then refuses a system where no wheel user can log in.)
        users.mutableUsers = lib.mkDefault false;
        security.sudo-rs.enable = true;
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

        security.sudo-rs = {
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
