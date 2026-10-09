# Eval-level tests for profiles.nix and the per-profile session wiring (profiles.md, apps.md
# "The session side"): accounts from a schema-2 state, the guest, the greeter mode with its PAM
# stack, uaccess instead of static groups, group-based grants, and what stays as it was in
# autologin mode. Nothing is built.
{ self, pkgs }:
let
  inherit (pkgs) lib;

  state = {
    schemaVersion = 2;
    settings.ssh.enable = false;
    profiles = [
      {
        id = "p1";
        user = "hinteros";
      }
      {
        id = "p2";
        user = "hinteros-p2";
      }
    ];
    requirements = [ ];
    services = [ ];
  };

  mk =
    extra:
    (self.lib.mkDevice {
      inherit state;
      extraModules = [ { system.stateVersion = "25.11"; } ] ++ extra;
    }).config;

  auto = mk [ { hinteros.profiles.greeter.enable = false; } ];
  greeter = mk [ { hinteros.profiles.greeter.enable = true; } ];
  # Schema 2's default is the greeter; schema 1 (not migrated yet) keeps autologin.
  schema2Default = mk [ ];
  schema1Default =
    (self.lib.mkDevice {
      state = {
        schemaVersion = 1;
        settings.ssh.enable = false;
        apps = [ ];
      };
      extraModules = [ { system.stateVersion = "25.11"; } ];
    }).config;
  greeterDev = mk [
    {
      hinteros.profiles.greeter.enable = true;
      hinteros.dev.enable = true;
    }
  ];

  failed =
    c:
    map (a: a.message) (
      lib.filter (a: !a.assertion && lib.hasPrefix "hinteros hardening:" a.message) c.assertions
    );
  pam = c: name: c.security.pam.services.${name}.text;
  polkit = c: c.security.polkit.extraConfig;
  hasLine = s: l: lib.any (x: lib.hasInfix l x) (lib.splitString "\n" s);
  console = c: c.system.systemBuilderCommands;

  results = lib.runTests {
    testGreeterDefault = {
      expr = {
        schema2 = schema2Default.hinteros.profiles.greeter.enable;
        schema1 = schema1Default.hinteros.profiles.greeter.enable;
        schema1Autologin = schema1Default.services.greetd.settings ? initial_session;
      };
      expected = {
        schema2 = true;
        schema1 = false;
        schema1Autologin = true;
      };
    };
    # Test VMs point kiosk apps at local pages in every env that has them.
    testEnvOverrides = {
      expr =
        let
          c = mk [ { hinteros.appEnv.overrides.youtube.kiosk.url = "file:///etc/test/yt.html"; } ];
        in
        lib.last (lib.head (c.hinteros.appEnv.build [ "youtube" ]).manifest.apps).command;
      expected = "file:///etc/test/yt.html";
    };
    # Autologin (the default until the greeter ships): the first account logs in, holds the
    # devices by group, and its daemon is the user unit (now for any member of `hinteros`).
    testAutologin = {
      expr = [
        auto.services.greetd.settings.initial_session.user
        (lib.hasSuffix "/hinteros-console/session" auto.services.greetd.settings.initial_session.command)
        (lib.sort lib.lessThan (lib.unique auto.users.users.hinteros.extraGroups))
        auto.users.users.hinteros-p2.extraGroups
        auto.users.users.hinteros-p2.uid
        (auto.users.users ? hinteros-greeter)
        (lib.hasInfix "/hinteros-console/greeter" (console auto))
        (auto.hinteros.daemon.session.settings ? greeter)
        (failed auto)
      ];
      expected = [
        "hinteros"
        true
        [
          "hinteros"
          "input"
          "inputplumber"
          "uinput"
          "video"
        ]
        [ "hinteros" ]
        20002
        false
        false
        false
        [ ]
      ];
    };
    # Grants are written against the group in both modes (profiles.md, "Device access per seat").
    testGroupGrants = {
      expr = [
        (lib.hasInfix ''subject.isInGroup("hinteros") && subject.local && subject.active'' (polkit auto))
        (lib.hasInfix ''subject.user == "hinteros"'' (polkit auto))
      ];
      expected = [
        true
        false
      ];
    };
    # Greeter mode: greetd runs the picker as hinteros-greeter, no autologin.
    testGreeterSession = {
      expr = [
        (greeter.services.greetd.settings ? initial_session)
        greeter.services.greetd.settings.default_session.user
        greeter.services.greetd.settings.default_session.command
        greeter.users.users.hinteros-greeter.isSystemUser
        greeter.users.users.hinteros-greeter.home
        (lib.hasInfix "/hinteros-console/greeter" (console greeter))
        (lib.hasInfix "/hinteros-console/picker" (console greeter))
        greeter.hinteros.daemon.session.settings.greeter.session_command
        greeter.systemd.services.greetd.after
        # The console font from the initrd: no font change (and fbcon redraw) mid-boot.
        greeter.console.earlySetup
        greeter.console.font
      ];
      expected = [
        false
        "hinteros-greeter"
        "/run/current-system/hinteros-console/greeter"
        true
        "/var/lib/hinteros-greeter"
        true
        true
        [ "/run/current-system/hinteros-console/session" ]
        [
          "hinteros-system.service"
          "systemd-vconsole-setup.service"
        ]
        true
        "ter-v32b"
      ];
    };
    # The PAM stack (profiles.md, "PAM: where the PIN and the kill are enforced").
    testGreeterPam =
      let
        p = pam greeter "greetd";
        g = pam greeter "greetd-greeter";
      in
      {
        expr = [
          (hasLine p "auth     requisite  pam_succeed_if.so user ingroup hinteros")
          (hasLine p "auth     [success=done default=ignore] pam_exec.so quiet ")
          (hasLine p "/bin/hinteros-system pin unlocked")
          (hasLine p "auth     required   pam_exec.so quiet stdout expose_authtok ")
          (hasLine p "/bin/hinteros-system pin verify")
          (hasLine p "auth     required   pam_permit.so")
          (hasLine p "session  required   pam_exec.so quiet ")
          (hasLine p "/bin/hinteros-system pin end-others")
          # end-others before pam_systemd opens the session
          (
            lib.findFirst (lib.hasInfix "end-others") null (lib.splitString "\n" p) != null
            && lib.hasInfix "end-others" (lib.head (lib.splitString "pam_systemd" p))
          )
          (hasLine g "session  optional   pam_exec.so quiet ")
          (hasLine g "/bin/hinteros-system pin end-others")
          (hasLine g "pam_systemd.so")
          (hasLine (pam auto "greetd") "hinteros-system pin")
        ];
        expected = [
          true
          true
          true
          true
          true
          true
          true
          true
          true
          true
          true
          true
          false
        ];
      };
    # The handover splash: optional, before end-others, in both stacks, drawn in the launcher's
    # typeface; a console font that reads on a TV; a quiet kernel console.
    testGreeterSplash =
      let
        before =
          s:
          let
            parts = lib.splitString "pin end-others" s;
          in
          lib.length parts == 2
          && lib.hasInfix "session  optional   pam_exec.so quiet " (lib.head parts)
          && lib.hasInfix "/bin/hinteros-system pin splash" (lib.head parts)
          && lib.hasInfix "pin splash --font /nix/store/" (lib.head parts)
          && lib.hasInfix "-atkinson-hyperlegible-" (lib.head parts)
          && lib.hasInfix "/share/fonts/opentype/AtkinsonHyperlegible-Bold.otf\n" (lib.head parts);
      in
      {
        expr = [
          (before (pam greeter "greetd"))
          (before (pam greeter "greetd-greeter"))
          greeter.console.font
          (greeter.boot.consoleLogLevel <= 3)
        ];
        expected = [
          true
          true
          "ter-v32b"
          true
        ];
      };
    # Kill on switch and no lingering.
    testGreeterLogind = {
      expr = [
        greeter.services.logind.settings.Login.KillUserProcesses
        greeter.services.logind.settings.Login.UserStopDelaySec
        (lib.hasInfix "org.freedesktop.login1.set-self-linger" (polkit greeter))
        (lib.hasInfix "org.freedesktop.login1.set-self-linger" (polkit auto))
      ];
      expected = [
        true
        0
        true
        false
      ];
    };
    # uaccess replaces the static groups; InputPlumber and power go to the active session.
    testGreeterDevices = {
      expr = [
        (lib.unique greeter.users.users.hinteros.extraGroups)
        greeter.users.users.hinteros-p2.extraGroups
        (lib.hasInfix ''KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess"'' greeter.services.udev.extraRules)
        (lib.hasInfix ''action.id.indexOf("org.shadowblip.") === 0'' (polkit greeter))
        (lib.hasInfix ''subject.user == "hinteros-greeter"'' (polkit greeter))
        greeter.systemd.services.hinteros-system.serviceConfig.SupplementaryGroups
        (lib.hasInfix "hinteros-greeter" greeter.environment.etc."polkit-1/rules.d/50-hinteros.rules".text)
        (failed greeter)
        (failed greeterDev)
      ];
      expected = [
        [ "hinteros" ]
        [ "hinteros" ]
        true
        true
        true
        [ "hinteros-greeter" ]
        true
        [ ]
        [ ]
      ];
    };
    # Hardening: a device group in greeter mode, or a profile in wheel, is an error.
    testHardeningPerAccount = {
      expr = [
        (lib.any (lib.hasInfix "device groups") (
          failed (mk [
            { hinteros.profiles.greeter.enable = true; }
            { users.users.hinteros-p2.extraGroups = [ "video" ]; }
          ])
        ))
        (lib.any (lib.hasInfix "wheel") (
          failed (mk [ { users.users.hinteros-p2.extraGroups = [ "wheel" ]; } ])
        ))
        (lib.any (lib.hasInfix "trusted user") (
          failed (mk [
            {
              hinteros.dev.enable = true;
              nix.settings.trusted-users = [ "hinteros-p2" ];
            }
          ])
        ))
      ];
      expected = [
        true
        true
        true
      ];
    };
  };
in
pkgs.runCommand "hinteros-profiles-eval" { } (
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
