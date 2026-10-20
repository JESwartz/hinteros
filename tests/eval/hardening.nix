# Eval-level tests for hardening.nix: the dev-off assertions fire (wheel member, NOPASSWD,
# extra trusted user, session user in wheel/trusted even in dev), dev adds only the deploy user,
# the baseline options are set, and the devbox warns. Nothing is built.
{ self, pkgs }:
let
  inherit (pkgs) lib;

  state = {
    schemaVersion = 1;
    profiles = [
      {
        id = "p1";
        name = "T";
        user = "tester";
      }
    ];
  };

  mk =
    extra:
    (self.lib.mkDevice {
      inherit state;
      extraModules = [ { system.stateVersion = "25.11"; } ] ++ extra;
    }).config;

  # Failing "hinteros hardening" assertion messages (as one string).
  failures =
    c:
    lib.concatStringsSep "\n" (
      map (a: a.message) (
        lib.filter (a: !a.assertion && lib.hasPrefix "hinteros hardening:" a.message) c.assertions
      )
    );
  failed = c: failures c != "";

  mkS =
    st: extra:
    (self.lib.mkDevice {
      state = st;
      extraModules = [ { system.stateVersion = "25.11"; } ] ++ extra;
    }).config;
  sshState = state // {
    settings.ssh.enable = true;
  };
  adminOn = {
    hinteros.admin = {
      enable = true;
      hashedPasswordFile = "/run/admin-pw";
    };
  };

  c = mk [ ];
  dev = mk [ { hinteros.dev.enable = true; } ];
  devbox = self.nixosConfigurations.devbox.config;

  results = lib.runTests {
    testCleanBuildPasses = {
      expr = failures c;
      expected = "";
    };
    testDevBuildPasses = {
      expr = failures dev;
      expected = "";
    };
    testDevboxPasses = {
      expr = failures devbox;
      expected = "";
    };
    testWheelMemberFails = {
      expr = failed (mk [ { users.users.tester.extraGroups = [ "wheel" ]; } ]);
      expected = true;
    };
    testWheelGroupMemberFails = {
      expr = failed (mk [ { users.groups.wheel.members = [ "tester" ]; } ]);
      expected = true;
    };
    testOtherWheelMemberFails = {
      expr = failed (mk [
        {
          users.users.bob = {
            isNormalUser = true;
            extraGroups = [ "wheel" ];
          };
        }
      ]);
      expected = true;
    };
    testWheelMemberOkInDevExceptSession = {
      expr = [
        (failed (mk [
          { hinteros.dev.enable = true; }
          { users.users.tester.extraGroups = [ "wheel" ]; }
        ]))
        (failed (mk [
          { hinteros.dev.enable = true; }
          {
            users.users.bob = {
              isNormalUser = true;
              extraGroups = [ "wheel" ];
            };
          }
        ]))
      ];
      expected = [
        true
        false
      ];
    };
    testNopasswdRuleFails = {
      expr = failed (mk [
        {
          security.sudo-rs.extraRules = [
            {
              users = [ "tester" ];
              commands = [
                {
                  command = "ALL";
                  options = [ "NOPASSWD" ];
                }
              ];
            }
          ];
        }
      ]);
      expected = true;
    };
    testNopasswdExtraConfigFails = {
      expr = failed (mk [ { security.sudo-rs.extraConfig = "tester ALL=(ALL) NOPASSWD: ALL"; } ]);
      expected = true;
    };
    testPasswordlessWheelFails = {
      expr = failed (mk [ { security.sudo-rs.wheelNeedsPassword = false; } ]);
      expected = true;
    };
    testClassicSudoFails = {
      expr = [
        (failed (mk [ { security.sudo.enable = true; } ]))
        (failed (mk [
          adminOn
          { security.sudo.extraConfig = "tester ALL=(ALL) NOPASSWD: ALL"; }
        ]))
      ];
      expected = [
        true
        true
      ];
    };
    testExtraTrustedUserFails = {
      expr = failed (mk [ { nix.settings.trusted-users = [ "@wheel" ]; } ]);
      expected = true;
    };
    testSessionTrustedFailsEvenInDev = {
      expr = failed (mk [
        { hinteros.dev.enable = true; }
        { nix.settings.trusted-users = [ "tester" ]; }
      ]);
      expected = true;
    };

    testAdminAllowedWheelWithPassword = {
      expr = failed (mk [ adminOn ]);
      expected = false;
    };
    testAdminNeedsPassword = {
      expr = failed (mk [ { hinteros.admin.enable = true; } ]);
      expected = true;
    };
    testAdminSudoPasswordRequired = {
      expr =
        let
          a = mk [ adminOn ];
        in
        [
          a.security.sudo-rs.enable
          a.security.sudo-rs.wheelNeedsPassword
          a.users.users.hinteros-admin.extraGroups
          a.security.polkit.adminIdentities
          (lib.elem "hinteros-admin" a.nix.settings.trusted-users)
          (mkS sshState [ adminOn ]).services.openssh.settings.AllowUsers
        ];
      expected = [
        true
        true
        [ "wheel" ]
        [
          "unix-user:0"
          "unix-user:hinteros-admin"
        ]
        false
        [ "hinteros-admin" ]
      ];
    };
    testAdminNopasswdStillFails = {
      expr = failed (mk [
        adminOn
        { security.sudo-rs.wheelNeedsPassword = false; }
      ]);
      expected = true;
    };
    testAdminDoesNotLicenseOtherWheel = {
      expr = failed (mk [
        adminOn
        { users.users.tester.extraGroups = [ "wheel" ]; }
      ]);
      expected = true;
    };
    testSshNeedsAdmin = {
      expr = [
        (failed (mkS sshState [ ]))
        (failed (mkS sshState [ adminOn ]))
        (failed (mkS sshState [ { hinteros.admin.enable = true; } ]))
      ];
      expected = [
        true
        false
        true
      ];
    };
    testSessionNeverAllowedOverSsh = {
      expr = lib.elem "tester" (mkS sshState [ adminOn ]).services.openssh.settings.AllowUsers;
      expected = false;
    };
    testSshAdminPolkitAction = {
      expr = lib.any (
        p: p ? name && lib.hasInfix "hinteros-system-share" p.name
      ) c.environment.systemPackages;
      expected = true;
    };

    testBaseline = {
      expr = [
        (lib.unique c.nix.settings.trusted-users)
        c.nix.settings.allowed-users
        c.boot.loader.systemd-boot.editor
        c.security.polkit.adminIdentities
        c.security.sudo-rs.enable
        (c.users.users ? deploy)
        (c.warnings == [ ])
      ];
      expected = [
        [ "root" ]
        [ "root" ]
        false
        [ "unix-user:0" ]
        false
        false
        true
      ];
    };
    testKernelSysctls = {
      expr = lib.getAttrs [
        "kernel.kptr_restrict"
        "kernel.dmesg_restrict"
        "kernel.perf_event_paranoid"
        "kernel.unprivileged_bpf_disabled"
        "net.core.bpf_jit_harden"
        "kernel.io_uring_disabled"
        "kernel.yama.ptrace_scope"
        "fs.protected_hardlinks"
        "fs.protected_symlinks"
        "fs.protected_fifos"
        "fs.protected_regular"
      ] c.boot.kernel.sysctl;
      expected = {
        "kernel.kptr_restrict" = 2;
        "kernel.dmesg_restrict" = 1;
        "kernel.perf_event_paranoid" = 3;
        "kernel.unprivileged_bpf_disabled" = 1;
        "net.core.bpf_jit_harden" = 2;
        "kernel.io_uring_disabled" = 2;
        "kernel.yama.ptrace_scope" = 1;
        "fs.protected_hardlinks" = 1;
        "fs.protected_symlinks" = 1;
        "fs.protected_fifos" = 2;
        "fs.protected_regular" = 2;
      };
    };
    testJournalPersistent = {
      expr = [
        c.services.journald.settings.Journal.Storage
        (c.services.journald.settings.Journal ? SystemMaxUse)
      ];
      expected = [
        "persistent"
        true
      ];
    };
    testSshPolicy = {
      expr =
        let
          s = (mkS sshState [ adminOn ]).services.openssh;
        in
        [
          s.enable
          s.settings.PermitRootLogin
          s.settings.PasswordAuthentication
          s.settings.AllowUsers
        ];
      expected = [
        true
        "no"
        true
        [ "hinteros-admin" ]
      ];
    };
    # Port 22 only from the local networks, with the backend the box uses; never to all sources.
    testSshFirewallLocalOnly = {
      expr =
        lib.all
          (
            cfg:
            let
              fw = cfg.networking.firewall;
              rules = if cfg.networking.nftables.enable then fw.extraInputRules else fw.extraCommands;
            in
            !cfg.services.openssh.openFirewall
            && !(lib.elem 22 fw.allowedTCPPorts)
            && lib.all (n: lib.hasInfix n rules) [
              "10.0.0.0/8"
              "172.16.0.0/12"
              "192.168.0.0/16"
              "169.254.0.0/16"
              "fc00::/7"
              "fe80::/10"
            ]
            && !lib.hasInfix "0.0.0.0/0" rules
            && !lib.hasInfix "::/0" rules
          )
          [
            (mkS sshState [ adminOn ])
            dev
            devbox
          ];
      expected = true;
    };
    testSshFirewallIptablesRule = {
      expr =
        lib.hasInfix
          "iptables -w -A nixos-fw -p tcp --dport 22 -s 192.168.0.0/16 -m comment --comment hinteros-ssh -j nixos-fw-accept"
          (mkS sshState [
            adminOn
            { networking.nftables.enable = false; }
          ]).networking.firewall.extraCommands;
      expected = true;
    };
    testSshFirewallNftablesRule = {
      expr =
        lib.hasInfix "ip6 saddr { fc00::/7, fe80::/10 } tcp dport { 22 } accept"
          (mkS sshState [ adminOn ]).networking.firewall.extraInputRules;
      expected = true;
    };
    testSshFirewallNoRuleWhenOff = {
      expr = lib.hasInfix "hinteros-ssh" (
        c.networking.firewall.extraCommands + c.networking.firewall.extraInputRules
      );
      expected = false;
    };
    testSshAllowFromOverride = {
      expr =
        lib.hasInfix "ip saddr { 0.0.0.0/0 } tcp dport"
          (mkS sshState [
            adminOn
            {
              hinteros.ssh.allowFrom = [
                "0.0.0.0/0"
                "::/0"
              ];
            }
          ]).networking.firewall.extraInputRules;
      expected = true;
    };
    testSshAllowFromBadFails = {
      expr = failed (
        mkS sshState [
          adminOn
          { hinteros.ssh.allowFrom = [ "10.0.0.0/8 -j ACCEPT; true" ]; }
        ]
      );
      expected = true;
    };
    testLessSoftware = {
      expr = [
        c.security.sudo.enable
        c.networking.nftables.enable
        c.networking.networkmanager.wifi.backend
        c.networking.modemmanager.enable
        c.services.speechd.enable
        c.programs.nano.enable
        (lib.sort (a: b: a < b) (
          lib.attrNames (lib.filterAttrs (_: w: w.enable) (mk [ adminOn ]).security.wrappers)
        ))
      ];
      expected = [
        false
        true
        "iwd"
        false
        false
        true
        [
          "mount"
          "passwd"
          "sudo"
          "sudoedit"
          "umount"
          "unix_chkpwd"
        ]
      ];
    };
    testSshOffByDefault = {
      expr = c.services.openssh.enable;
      expected = false;
    };

    testDevDeployUser = {
      expr = [
        dev.users.users.deploy.extraGroups
        dev.security.sudo-rs.wheelNeedsPassword
        dev.security.sudo-rs.enable
        (lib.sort (a: b: a < b) (lib.unique dev.nix.settings.trusted-users))
        dev.services.openssh.settings.AllowUsers
        (lib.sort (a: b: a < b) dev.users.users.tester.extraGroups)
        (builtins.length dev.warnings > 0)
      ];
      expected = [
        [ "wheel" ]
        false
        true
        [
          "deploy"
          "root"
        ]
        [ "deploy" ]
        [
          "hinteros"
          "inputplumber"
          "uinput"
          "video"
        ]
        true
      ];
    };
    testDevboxNoSessionPrivileges = {
      expr = [
        devbox.hinteros.dev.enable
        (lib.elem "wheel" devbox.users.users.hinteros.extraGroups)
        (lib.elem "hinteros" devbox.nix.settings.trusted-users)
      ];
      expected = [
        true
        false
        false
      ];
    };
    testDeployKeysWired = {
      expr =
        (mk [
          {
            hinteros.dev = {
              enable = true;
              deployKeys = [ "ssh-ed25519 AAAATEST deploy" ];
            };
          }
        ]).users.users.deploy.openssh.authorizedKeys.keys;
      expected = [ "ssh-ed25519 AAAATEST deploy" ];
    };
  };
in
pkgs.runCommand "hinteros-hardening-eval" { } (
  if results == [ ] then
    "touch $out"
  else
    ''
      cat >&2 <<'EOT'
      ${builtins.toJSON results}
      EOT
      exit 1
    ''
)
