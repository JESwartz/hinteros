# Eval-level tests for lib.mkDevice and the state.json translation: good states evaluate and
# map to the expected options; bad ones fail evaluation with a clear message. Nothing is built.
{
  self,
  pkgs,
}:
let
  inherit (pkgs) lib;

  good = {
    schemaVersion = 2;
    base = "unstable";
    stateVersion = "25.11";
    settings.ssh.enable = true;
    profiles = [ { id = "p1"; } ];
    requirements = [ ];
    services = [ ];
  };

  mk =
    state:
    self.lib.mkDevice {
      inherit state;
    };

  # Evaluates the failing assertion messages (as one string) of a state, or the eval error.
  failures =
    state:
    let
      cfg = (mk state).config;
      msgs = map (a: a.message) (
        builtins.filter (a: !a.assertion && lib.hasPrefix "hinteros state:" a.message) cfg.assertions
      );
      r = builtins.tryEval (builtins.deepSeq msgs msgs);
    in
    if r.success then lib.concatStringsSep "\n" r.value else "EVAL ERROR";

  report = builtins.toFile "facter.json" "{}";

  c = (mk good).config;
  good2 = good // {
    settings = {
      ssh.enable = false;
      guest.enable = true;
    };
    profiles = [
      { id = "p1"; }
      { id = "p3"; }
    ];
    requirements = [ "graphics32" ];
  };
  c2 = (mk good2).config;
  c2nog = (mk (good2 // { settings.guest.enable = false; })).config;
  minimal = (mk (removeAttrs good [ "settings" ])).config;
  # A test VM's device: no state, box-wide apps.
  boxSteam =
    (self.lib.mkDevice {
      state = null;
      extraModules = [
        {
          system.stateVersion = "25.11";
          hinteros.apps.steam.enable = true;
        }
      ];
    }).config;

  # A device with a real hardware report: facter must not add a second DHCP client.
  withFixture =
    f:
    (self.lib.mkDevice {
      state = good;
      facterReport = f;
    }).config;
  noDhcp =
    f:
    let
      cfg = withFixture f;
    in
    [
      cfg.networking.networkmanager.enable
      cfg.networking.useDHCP
      cfg.networking.dhcpcd.enable
      (cfg.systemd.services ? dhcpcd)
      (lib.filterAttrs (_: i: i.useDHCP != null) cfg.networking.interfaces)
    ];
  noDhcpExpected = [
    true
    false
    false
    false
    { }
  ];

  results = lib.runTests {
    testSchema2Good = {
      expr = failures good2;
      expected = "";
    };
    testSchema2Bad = {
      expr = map (s: lib.hasInfix s.msg (failures (good2 // s.patch))) [
        {
          msg = "bad id";
          patch.profiles = [ { id = "admin"; } ];
        }
        {
          msg = "duplicate ids";
          patch.profiles = [
            { id = "p1"; }
            { id = "p1"; }
          ];
        }
        {
          msg = "1 to 8 accounts";
          patch.profiles = map (n: { id = "p${toString n}"; }) (lib.range 1 9);
        }
        {
          msg = "1 to 8 accounts";
          patch.profiles = [ ];
        }
        {
          msg = "unknown box feature(s) in requirements: opengl";
          patch.requirements = [ "opengl" ];
        }
        {
          msg = "unknown service id(s): youtube";
          patch.services = [ "youtube" ];
        }
      ];
      expected = lib.genList (_: true) 6;
    };
    testRequiredFields = {
      expr = map (f: lib.hasInfix "${f} must be" (failures (removeAttrs good2 [ f ]))) [
        "base"
        "stateVersion"
        "requirements"
        "services"
      ];
      expected = [
        true
        true
        true
        true
      ];
    };
    # Unknown fields are ignored (a box on an older channel evaluates a newer state.json).
    testUnknownFieldsIgnored =
      let
        newer = good2 // {
          apps = [ "youtube" ];
          wifi = { };
          settings = good2.settings // {
            bluetooth = { };
            guest.pin = "1234";
            cleanup.future = true;
          };
          profiles = [
            {
              id = "p1";
              user = "sam";
              name = "Dev";
            }
          ];
        };
      in
      {
        expr = [
          (failures newer)
          (mk newer).config.hinteros.session.user
        ];
        expected = [
          ""
          "hinteros-p1"
        ];
      };
    # Accounts, the guest, box features from `requirements`, apps per profile.
    testSchema2Accounts = {
      expr = [
        (map (a: a.id) c2.hinteros.profiles.accounts)
        c2.users.users.hinteros-p3.uid
        c2.users.users.hinteros-p1.uid
        c2.users.users.hinteros-p3.extraGroups
        c2.users.users.hinteros-p3.homeMode
        c2.users.users.hinteros-guest.uid
        c2.hinteros.profiles.users
        c2.hinteros.session.user
        (lib.elem "D! /home/hinteros-guest 0700 hinteros-guest users -" c2.systemd.tmpfiles.rules)
        (c2nog.users.users ? hinteros-guest)
      ];
      expected = [
        [
          "p1"
          "p3"
        ]
        20003
        20001
        [ "hinteros" ]
        "700"
        20000
        [
          "hinteros-p1"
          "hinteros-p3"
          "hinteros-guest"
        ]
        "hinteros-p1"
        true
        false
      ];
    };
    testSchema2Apps = {
      expr = [
        c2.hinteros.daemon.session.settings.apps
        (c2.hinteros.daemon.session.settings ? steam && c2.hinteros.daemon.session.settings.steam ? path)
        c2.hinteros.boxFeatures
        c2.hardware.graphics.enable32Bit
        c2.hardware.steam-hardware.enable
        c2.hinteros.unfreeAllowlist
        # No app package in the system (the OSK and the session's own packages are not apps).
        (lib.filter (
          n:
          lib.elem n [
            "jellyfin-desktop"
            "firefox"
            "firefox-esr"
            "steam"
            "hinteros-firefox-kiosk"
          ]
        ) (map lib.getName c2.environment.systemPackages))
        # The profile's app env is on no search path of the session (no wrapper; only the daemon reads it).
        (lib.hasInfix "hinteros-profile-env" c2.hinteros.session.command)
        (lib.hasInfix "hinteros-profile-env" c.hinteros.session.command)
        # Firefox policies stay box-wide.
        (c2.environment.etc ? "firefox/policies/policies.json")
        c2.programs.firefox.enable
      ];
      expected = [
        { profile = "/run/hinteros/apps/%u"; }
        false
        [ "graphics32" ]
        true
        false
        [ ]
        [ ]
        false
        false
        true
        false
      ];
    };
    # Every flake input's source stays with the system (offline env evaluation after a GC).
    testFlakeSourcesKept = {
      expr = map (s: lib.elem s c.system.extraDependencies) [
        self.outPath
        self.inputs.nixpkgs.outPath
        self.inputs.hinteros-catalog.outPath
        self.inputs.hinteros-daemon.outPath
        self.inputs.hinteros-launcher.outPath
      ];
      expected = [
        true
        true
        true
        true
        true
      ];
    };
    # The dev box embeds a device flake (flake.nix and flake.lock naming this repo by store path).
    testDevboxEmbeddedFlake =
      let
        d = self.nixosConfigurations.devbox.config.hinteros.deviceConfig;
        lock = builtins.fromJSON (builtins.unsafeDiscardStringContext d.embeddedFlake.lock);
      in
      {
        expr = [
          (lib.hasInfix "hinteros.lib.devices.devbox" d.embeddedFlake.flake)
          (lib.hasInfix "path:${builtins.unsafeDiscardStringContext self.outPath}" (
            builtins.unsafeDiscardStringContext d.embeddedFlake.flake
          ))
          lock.nodes.hinteros.locked.type
          lock.nodes.hinteros.locked.narHash
          (lock.nodes ? hinteros-catalog)
          (c.hinteros.deviceConfig.embeddedFlake == null)
        ];
        expected = [
          true
          true
          "path"
          self.narHash
          true
          true
        ];
      };
    testFacterM900NoSecondDhcp = {
      expr = noDhcp (self + "/tests/vm/fixtures/facter-lenovo-m900.json");
      expected = noDhcpExpected;
    };
    testFacterIntelMinipcNoSecondDhcp = {
      expr = noDhcp (self + "/tests/vm/fixtures/facter-intel-minipc.json");
      expected = noDhcpExpected;
    };
    # VA-API: Intel's driver when the report shows an Intel GPU (video-hardware.nix); the generic
    # system (no report) and a report without one go without.
    testIntelVideoFromReport =
      let
        vaDrivers = cfg: map lib.getName cfg.hardware.graphics.extraPackages;
        noGpu = builtins.toFile "facter-no-gpu.json" (
          builtins.toJSON (
            lib.recursiveUpdate (lib.importJSON (self + "/tests/vm/fixtures/facter-lenovo-m900.json")) {
              hardware.graphics_card = [ ];
            }
          )
        );
        generic =
          (self.lib.mkDevice {
            state = good;
          }).config;
      in
      {
        expr = [
          (vaDrivers (withFixture (self + "/tests/vm/fixtures/facter-lenovo-m900.json")))
          (vaDrivers (withFixture noGpu))
          (vaDrivers generic)
        ];
        expected = [
          [ "intel-media-driver" ]
          [ ]
          [ ]
        ];
      };
    testNoBoxWideAppsWithState = {
      expr = lib.attrNames (lib.filterAttrs (_: a: a.enable) c2.hinteros.apps);
      expected = [ ];
    };
    testGoodHasNoFailures = {
      expr = failures good;
      expected = "";
    };
    # Box-wide Steam: stock pkgs.steam installed, its box features on, no programs.steam.
    testSteamEnabled = {
      expr = [
        boxSteam.programs.steam.enable
        boxSteam.hinteros.boxFeatures
        boxSteam.hardware.graphics.enable32Bit
        boxSteam.hardware.steam-hardware.enable
        boxSteam.services.pipewire.alsa.support32Bit
        (lib.any (p: lib.getName p == "steam") boxSteam.environment.systemPackages)
        (lib.hasSuffix "/bin/steam" boxSteam.hinteros.daemon.session.settings.steam.path)
      ];
      expected = [
        false
        [
          "graphics32"
          "steam-devices"
        ]
        true
        true
        true
        true
        true
      ];
    };
    testSessionUser = {
      expr = c.hinteros.session.user;
      expected = "hinteros-p1";
    };
    testSshEnabled = {
      expr = [
        c.hinteros.ssh.enable
        c.services.openssh.enable
        c.services.openssh.settings.PermitRootLogin
      ];
      expected = [
        true
        true
        "no"
      ];
    };
    testMinimalSshOff = {
      expr = [
        minimal.services.openssh.enable
        minimal.programs.steam.enable
        minimal.hinteros.session.user
      ];
      expected = [
        false
        false
        "hinteros-p1"
      ];
    };
    testBadSchemaVersion = {
      expr =
        map
          (
            v:
            lib.hasInfix "unsupported schemaVersion ${toString v}" (failures (good // { schemaVersion = v; }))
          )
          [
            1
            3
          ];
      expected = [
        true
        true
      ];
    };
    testMissingSchemaVersion = {
      expr = lib.hasInfix "unsupported schemaVersion null" (
        failures (removeAttrs good [ "schemaVersion" ])
      );
      expected = true;
    };
    testUnavailableBase = {
      expr =
        (builtins.tryEval (
          builtins.deepSeq
            (self.lib.mkDevice {
              state = good;
              base = "stable";
            }).config.system.name
            true
        )).success;
      expected = false;
    };
    testInstallerFields =
      let
        c2 =
          (mk (
            good
            // {
              stateVersion = "25.11";
              settings = good.settings // {
                hostname = "livingroom";
                admin.user = "james";
              };
              disk.layout = "gpt-esp-ext4";
            }
          )).config;
      in
      {
        expr = [
          c2.system.stateVersion
          c2.networking.hostName
          c2.hinteros.admin.enable
          c2.hinteros.admin.user
          c2.hinteros.admin.hashedPasswordFile
          c2.users.users.james.isNormalUser
          c2.fileSystems."/".device
          c2.boot.loader.systemd-boot.enable
        ];
        expected = [
          "25.11"
          "livingroom"
          true
          "james"
          "/var/lib/hinteros/admin-password-hash"
          true
          "/dev/disk/by-partlabel/hinteros-root"
          true
        ];
      };
    # Boot counting (automatic fallback after a failed boot) is on for every installed box:
    # systemd-boot (the disk layout) turns it on, with the boot-health gate.
    testInstalledBoxBootCounting =
      let
        i = (mk (good // { disk.layout = "gpt-esp-ext4"; })).config;
        v = (mk good).config;
      in
      {
        expr = [
          i.boot.loader.systemd-boot.bootCounting.enable
          i.hinteros.maintenance.bootCounting.enable
          i.systemd.targets.boot-complete.requires
          v.boot.loader.systemd-boot.enable
          v.boot.loader.systemd-boot.bootCounting.enable
        ];
        expected = [
          true
          true
          [ "hinteros-boot-health.service" ]
          false
          false
        ];
      };
    testUnknownDiskLayout = {
      expr = lib.hasInfix "unsupported disk.layout" (failures (good // { disk.layout = "zfs"; }));
      expected = true;
    };
    # The device flake's outputs (nixos/lib/device-outputs.nix): the report unless deferred, an
    # optional extra.nix, the config dir as the snapshot.
    testDeviceOutputs =
      let
        out = d: (self.lib.deviceOutputs d).nixosConfigurations.hinteros.config;
        full = ./fixtures/device-outputs;
        deferred = ./fixtures/device-outputs-deferred;
        bare = ../vm/fixtures/config-sync;
      in
      {
        expr = [
          (out full).networking.hostName
          ((out full).hardware.facter.reportPath == full + "/facter.json")
          (out full).hinteros.deviceConfig.configDir
          (out full).hinteros.maintenance.keepGenerations
          (out deferred).hardware.facter.reportPath
          (out bare).hardware.facter.reportPath
          (out bare).hinteros.maintenance.keepGenerations
        ];
        expected = [
          "fixture"
          true
          full
          3
          null
          null
          5
        ];
      };
    testFacterReportPath = {
      expr =
        (self.lib.mkDevice {
          state = good;
          facterReport = report;
        }).config.hardware.facter.reportPath;
      expected = report;
    };
  };
in
pkgs.runCommand "hinteros-mk-device-eval" { } (
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
