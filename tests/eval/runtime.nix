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
        (has "--delete-generations +5" c.systemd.services.nix-gc.preStart)
        c.systemd.timers.hinteros-disk-check.timerConfig.OnUnitActiveSec
      ];
      expected = [
        true
        true
        true
        "1h"
      ];
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
