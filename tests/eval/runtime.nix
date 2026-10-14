# Eval-level tests for the runtime, power, device-config and maintenance modules: polkit rules
# are present and scoped to the session user, services are enabled with the session, snapshots
# are wired, boot counting and GC are configured. Nothing is built.
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
      configDir = ../vm/fixtures/config-sync;
      extraModules = [ { system.stateVersion = "25.11"; } ] ++ extra;
    }).config;

  # The automatic clean-up from state.json `settings.cleanup` (storage.md).
  state2 = cleanup: {
    schemaVersion = 2;
    settings = lib.optionalAttrs (cleanup != null) { inherit cleanup; };
    profiles = [
      {
        id = "p1";
        user = "hinteros";
      }
    ];
    requirements = [ ];
    services = [ ];
  };
  mkClean =
    cleanup:
    (self.lib.mkDevice {
      state = state2 cleanup;
      extraModules = [ { system.stateVersion = "25.11"; } ];
    }).config;
  # What the clean-up does, as configured: [ timer on, calendar, trim command, boot entries ].
  cleanupOf =
    cfg:
    let
      script = cfg.systemd.services.nix-gc.script;
    in
    [
      cfg.nix.gc.automatic
      (cfg.systemd.timers.nix-gc.timerConfig.OnCalendar or null)
      (lib.last (lib.splitString "/bin/hinteros-cleanup " (lib.trim script)))
      cfg.boot.loader.systemd-boot.configurationLimit
    ];
  # The failing state assertions of a cleanup setting (one string), or "EVAL ERROR".
  cleanupFailures =
    cleanup:
    let
      msgs = map (a: a.message) (
        builtins.filter (a: !a.assertion && lib.hasPrefix "hinteros state:" a.message)
          (mkClean cleanup).assertions
      );
      r = builtins.tryEval (builtins.deepSeq msgs msgs);
    in
    if r.success then lib.concatStringsSep "\n" r.value else "EVAL ERROR";

  # A schema-2 device with `settings.timeZone` (null: absent), and its failing state assertions.
  mkTz =
    timeZone:
    (self.lib.mkDevice {
      state = state2 null // {
        settings = lib.optionalAttrs (timeZone != null) { inherit timeZone; };
      };
      extraModules = [ { system.stateVersion = "25.11"; } ];
    }).config;
  tzFailures =
    timeZone:
    let
      msgs = map (a: a.message) (
        builtins.filter (a: !a.assertion && lib.hasPrefix "hinteros state:" a.message)
          (mkTz timeZone).assertions
      );
      r = builtins.tryEval (builtins.deepSeq msgs msgs);
    in
    if r.success then lib.concatStringsSep "\n" r.value else "EVAL ERROR";

  c = mk [ ];
  off = mk [ { hinteros.runtime.enable = false; } ];
  devbox = self.nixosConfigurations.devbox.config;
  polkit = c.security.polkit.extraConfig;
  has = lib.hasInfix;

  results = lib.runTests {
    testServicesWithSession = {
      expr = [
        c.networking.networkmanager.enable
        c.hardware.bluetooth.enable
        c.hardware.bluetooth.settings.General.Experimental
        c.services.pipewire.enable
        c.services.pipewire.wireplumber.enable
      ];
      expected = [
        true
        true
        true
        true
        true
      ];
    };
    testRuntimeOffWithoutSession = {
      expr = [
        off.networking.networkmanager.enable
        off.hardware.bluetooth.enable
      ];
      expected = [
        false
        false
      ];
    };
    testPowerKeySuspends = {
      expr = [
        c.services.logind.settings.Login.HandlePowerKey
        c.services.logind.settings.Login.HandleLidSwitch
      ];
      expected = [
        "suspend"
        "ignore"
      ];
    };
    testPolkitPowerRule = {
      expr = lib.all (a: has "org.freedesktop.login1.${a}" polkit) [
        "suspend"
        "reboot"
        "power-off"
      ];
      expected = true;
    };
    testPolkitNetworkRule = {
      expr = has "NetworkManager.settings.modify.own" polkit;
      expected = true;
    };
    testPolkitSystemConnectionsAccepted = {
      expr = has "settings.modify.system" polkit;
      expected = true;
    };
    testSecurityHardening = {
      expr = [
        c.hardware.bluetooth.settings.General.ClassicBondedOnly
        c.networking.networkmanager.plugins
        c.boot.loader.systemd-boot.editor
        devbox.boot.loader.systemd-boot.editor
      ];
      expected = [
        true
        [ ]
        false
        false
      ];
    };
    # Profiles (any member of `hinteros`), only in an active local session.
    testPolkitScopedToProfiles = {
      expr = has ''subject.isInGroup("hinteros") && subject.local && subject.active'' polkit;
      expected = true;
    };
    testPolkitNotBlanket = {
      expr = [
        (has "systemd1.manage-units" polkit)
        (has "polkit.Result.YES" polkit)
      ];
      expected = [
        false
        true
      ];
    };
    testSnapshotManagedFilesOnly = {
      expr = builtins.attrNames (builtins.readDir c.hinteros.deviceConfig.configDir);
      expected = [
        "README"
        "flake.lock"
        "flake.nix"
        "state.json"
      ];
    };
    testSnapshotWired = {
      expr = [
        (c.hinteros.deviceConfig.snapshot != null)
        (has "hinteros" c.system.systemBuilderCommands)
        c.systemd.services.hinteros-config-sync.serviceConfig.Type
      ];
      expected = [
        true
        true
        "oneshot"
      ];
    };
    testSyncCanBeDisabled = {
      expr = (mk [ { hinteros.deviceConfig.enable = false; } ]).systemd.services ? hinteros-config-sync;
      expected = false;
    };
    # No configDir: the snapshot is generated from the state.
    testDefaultSnapshot = {
      expr =
        (self.lib.mkDevice {
          inherit state;
          extraModules = [ { system.stateVersion = "25.11"; } ];
        }).config.hinteros.deviceConfig.snapshot != null;
      expected = true;
    };
    testDevboxBootCounting = {
      expr = [
        devbox.boot.loader.systemd-boot.bootCounting.enable
        devbox.boot.loader.systemd-boot.bootCounting.tries
        devbox.boot.loader.systemd-boot.configurationLimit
        devbox.systemd.targets.boot-complete.requires
        # Runs every boot: it marks the boot good itself when the firmware drops the
        # loader's volatile variables (no LoaderBootCountPath for systemd-bless-boot).
        devbox.systemd.services.hinteros-boot-health.wantedBy
      ];
      expected = [
        true
        3
        5
        [ "hinteros-boot-health.service" ]
        [ "multi-user.target" ]
      ];
    };
    testGcKeepsGenerations = {
      expr = [
        c.nix.gc.automatic
        c.nix.optimise.automatic
        (has "--system 5 --profiles 5" c.systemd.services.nix-gc.script)
        c.systemd.timers.hinteros-disk-check.timerConfig.OnUnitActiveSec
      ];
      expected = [
        true
        true
        true
        "1h"
      ];
    };
    # Absent (or empty): today's policy, weekly, 5 system generations; app profiles keep 5.
    testCleanupDefaults = {
      expr = [
        (cleanupOf (mkClean null))
        (cleanupOf (mkClean { }))
        (cleanupFailures null)
      ];
      expected = [
        (cleanupOf (mkClean {
          enable = true;
          frequency = "weekly";
          keepSystem = 5;
          keepProfiles = 5;
        }))
        [
          true
          [ "weekly" ]
          "--system 5 --profiles 5"
          5
        ]
        ""
      ];
    };
    testCleanupFrequencies = {
      expr =
        map
          (
            frequency:
            cleanupOf (mkClean {
              inherit frequency;
            })
          )
          [
            "daily"
            "weekly"
            "monthly"
          ];
      expected =
        map
          (f: [
            true
            [ f ]
            "--system 5 --profiles 5"
            5
          ])
          [
            "daily"
            "weekly"
            "monthly"
          ];
    };
    testCleanupKeepCounts = {
      expr = [
        (cleanupOf (mkClean {
          keepSystem = 2;
          keepProfiles = 9;
        }))
        (cleanupOf (mkClean {
          keepSystem = 10;
          keepProfiles = 1;
        }))
      ];
      expected = [
        [
          true
          [ "weekly" ]
          "--system 2 --profiles 9"
          2
        ]
        [
          true
          [ "weekly" ]
          "--system 10 --profiles 1"
          10
        ]
      ];
    };
    # Off: no timer; the boot menu still follows keepSystem.
    testCleanupOff =
      let
        cfg = mkClean {
          enable = false;
          keepSystem = 3;
        };
      in
      {
        expr = [
          cfg.nix.gc.automatic
          (cfg.systemd.timers ? nix-gc)
          cfg.boot.loader.systemd-boot.configurationLimit
        ];
        expected = [
          false
          false
          3
        ];
      };
    testCleanupInvalid = {
      expr = map (s: lib.hasInfix s.msg (cleanupFailures s.cleanup)) [
        {
          msg = "settings.cleanup.frequency must be one of daily, weekly, monthly, not \"hourly\"";
          cleanup.frequency = "hourly";
        }
        {
          msg = "settings.cleanup.keepSystem must be a whole number from 1 to 10, not 0";
          cleanup.keepSystem = 0;
        }
        {
          msg = "settings.cleanup.keepSystem must be a whole number from 1 to 10, not 11";
          cleanup.keepSystem = 11;
        }
        {
          msg = "settings.cleanup.keepProfiles must be a whole number from 1 to 10, not \"5\"";
          cleanup.keepProfiles = "5";
        }
        {
          msg = "settings.cleanup.enable must be a bool";
          cleanup.enable = "yes";
        }
        {
          msg = "unknown field(s) in settings.cleanup: keep";
          cleanup.keep = 5;
        }
        {
          msg = "settings.cleanup must be an object";
          cleanup = true;
        }
      ];
      expected = lib.genList (_: true) 7;
    };

    # The time zone (time-zone.md): NixOS does not own /etc/localtime; the activation script
    # reads the live state.json after `etc`, whatever the state says at evaluation.
    testTimeZoneWiring =
      let
        cfg = mkTz null;
        snippet = cfg.system.activationScripts.hinteros-time-zone;
      in
      {
        expr = [
          cfg.time.timeZone
          (cfg.environment.etc ? localtime)
          snippet.deps
          (has "/etc/hinteros/state.json" snippet.text)
          (has "mv -fT /etc/.localtime.hinteros-tmp /etc/localtime" snippet.text)
          (has "zone=UTC" snippet.text)
        ];
        expected = [
          null
          false
          [ "etc" ]
          true
          true
          true
        ];
      };
    # Absent, UTC and real zones (also a link name and one three parts deep) evaluate cleanly.
    testTimeZoneValid = {
      expr = map tzFailures [
        null
        "UTC"
        "America/Chicago"
        "America/Argentina/Buenos_Aires"
        "Etc/GMT+5"
        "US/Central"
      ];
      expected = lib.genList (_: "") 6;
    };
    testTimeZoneInvalid = {
      expr =
        map
          (
            z:
            has "settings.timeZone must be a time zone name of tzdata (e.g. \"Europe/Berlin\" or \"UTC\"), not ${builtins.toJSON z}" (
              tzFailures z
            )
          )
          [
            "Mars/Olympus_Mons"
            "utc"
            "America"
            "../../etc/shadow"
            "/etc/zoneinfo/UTC"
            "America/../UTC"
            "posix/America/Chicago"
            "zone1970.tab"
            "tzdata.zi"
            ""
            5
            { }
          ];
      expected = lib.genList (_: true) 12;
    };
  };
in
pkgs.runCommand "hinteros-runtime-eval" { } (
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
