# Eval-level tests for lib.mkDevice and the state.json translation: good states evaluate and
# map to the expected options; bad ones fail evaluation with a clear message. Nothing is built.
{
  self,
  pkgs,
  nixpkgs ? self.inputs.nixpkgs,
}:
let
  inherit (pkgs) lib;

  good = {
    schemaVersion = 1;
    settings.ssh.enable = true;
    apps = [ "steam" ];
    profiles = [
      {
        id = "p1";
        name = "T";
        user = "tester";
      }
    ];
  };

  mk =
    state:
    self.lib.mkDevice {
      inherit state;
      extraModules = [ { system.stateVersion = "25.11"; } ];
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
  good2 = {
    schemaVersion = 2;
    settings.ssh.enable = false;
    settings.guest.enable = true;
    profiles = [
      {
        id = "p1";
        user = "hinteros";
      }
      {
        id = "p3";
        user = "hinteros-p3";
      }
    ];
    requirements = [ "graphics32" ];
    services = [ ];
  };
  c2 = (mk good2).config;
  c2nog = (mk (good2 // { settings.guest.enable = false; })).config;
  minimal = (mk { schemaVersion = 1; }).config;

  # A device with a real hardware report: facter must not add a second DHCP client.
  withFixture =
    f:
    (self.lib.mkDevice {
      state = good;
      facterReport = f;
      extraModules = [ { system.stateVersion = "25.11"; } ];
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
          msg = "unknown field(s) in state: apps";
          patch.apps = [ "youtube" ];
        }
        {
          msg = "p3 must be user hinteros-p3";
          patch.profiles = [
            {
              id = "p1";
              user = "hinteros";
            }
            {
              id = "p3";
              user = "sam";
            }
          ];
        }
        {
          msg = "bad id";
          patch.profiles = [
            {
              id = "admin";
              user = "hinteros-admin";
            }
          ];
        }
        {
          msg = "duplicate ids";
          patch.profiles = [
            {
              id = "p1";
              user = "hinteros";
            }
            {
              id = "p1";
              user = "hinteros";
            }
          ];
        }
        {
          msg = "1 to 8 accounts";
          patch.profiles = map (n: {
            id = "p${toString n}";
            user = if n == 1 then "hinteros" else "hinteros-p${toString n}";
          }) (lib.range 1 9);
        }
        {
          msg = "1 to 8 accounts";
          patch.profiles = [ ];
        }
        {
          msg = "unknown field(s) in profiles[]: name";
          patch.profiles = [
            {
              id = "p1";
              user = "hinteros";
              name = "Dev";
            }
          ];
        }
        {
          msg = "unknown box feature(s) in requirements: opengl";
          patch.requirements = [ "opengl" ];
        }
        {
          msg = "unknown service id(s): youtube";
          patch.services = [ "youtube" ];
        }
        {
          msg = "unknown field(s) in settings.guest: pin";
          patch.settings.guest.pin = "1234";
        }
      ];
      expected = lib.genList (_: true) 10;
    };
    # Schema 2: accounts, the guest, box features from `requirements`, apps per profile.
    testSchema2Accounts = {
      expr = [
        (map (a: a.user) c2.hinteros.profiles.accounts)
        c2.users.users.hinteros-p3.uid
        (c2.users.users.hinteros.uid or null)
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
          "hinteros"
          "hinteros-p3"
        ]
        20003
        null
        [ "hinteros" ]
        "700"
        20000
        [
          "hinteros"
          "hinteros-p3"
          "hinteros-guest"
        ]
        "hinteros"
        true
        false
      ];
    };
    testSchema2Apps = {
      expr = [
        c2.hinteros.appEnv.perProfile
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
        true
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
    # Schema 1 with `profiles: []` (the installer, every pre-M7 box) is p1 = hinteros.
    testSchema1EmptyProfiles = {
      expr = [
        minimal.hinteros.profiles.accounts
        minimal.hinteros.session.user
        minimal.hinteros.appEnv.perProfile
      ];
      expected = [
        [
          {
            id = "p1";
            user = "hinteros";
          }
        ]
        "hinteros"
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
            extraModules = [ { system.stateVersion = "25.11"; } ];
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
    testGoodHasNoFailures = {
      expr = failures good;
      expected = "";
    };
    # Schema 1, box-wide Steam: stock pkgs.steam installed, its box features on, no programs.steam.
    testSteamEnabled = {
      expr = [
        c.programs.steam.enable
        c.hinteros.boxFeatures
        c.hardware.graphics.enable32Bit
        c.hardware.steam-hardware.enable
        c.services.pipewire.alsa.support32Bit
        (lib.any (p: lib.getName p == "steam") c.environment.systemPackages)
        (lib.hasSuffix "/bin/steam" c.hinteros.daemon.session.settings.steam.path)
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
      expected = "tester";
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
        "hinteros"
      ];
    };
    testBadSchemaVersion = {
      expr = lib.hasInfix "unsupported schemaVersion 3" (failures (good // { schemaVersion = 3; }));
      expected = true;
    };
    testMissingSchemaVersion = {
      expr = lib.hasInfix "unsupported schemaVersion null" (
        failures (removeAttrs good [ "schemaVersion" ])
      );
      expected = true;
    };
    testUnknownTopLevel = {
      expr = lib.hasInfix "unknown field(s) in state: wifi" (failures (good // { wifi = { }; }));
      expected = true;
    };
    testUnknownSetting = {
      expr = lib.hasInfix "unknown field(s) in settings: bluetooth" (
        failures (
          good
          // {
            settings = good.settings // {
              bluetooth = { };
            };
          }
        )
      );
      expected = true;
    };
    # A tombstoned catalog id is known: a state may still list it and it does nothing.
    testTombstoneAccepted = {
      expr =
        let
          cat = {
            gone = {
              status = "removed";
              name = "Gone";
            };
          };
          sys = nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            modules = [
              (self + "/nixos/modules")
              self.nixosModules.overlay
              (import (self + "/nixos/modules/catalog.nix") {
                entries = cat;
                cacheableUnfree = [ ];
                index = pkgs.hello;
              })
              {
                hinteros.state = {
                  schemaVersion = 1;
                  apps = [ "gone" ];
                };
                system.stateVersion = "25.11";
              }
            ];
          };
          msgs = map (a: a.message) (
            builtins.filter (a: !a.assertion && lib.hasPrefix "hinteros state:" a.message) sys.config.assertions
          );
        in
        [
          msgs
          (sys.config.hinteros.apps ? gone)
        ];
      expected = [
        [ ]
        false
      ];
    };
    testUnknownApp = {
      expr = lib.hasInfix "unknown app id(s): bogus" (failures (good // { apps = [ "bogus" ]; }));
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
    # Default apps are exactly the selected ones once a state exists; the rest stay off.
    testDefaultAppsFollowState = {
      expr =
        let
          a =
            (mk (
              good
              // {
                apps = [
                  "youtube"
                  "firefox"
                ];
              }
            )).config.hinteros.apps;
        in
        lib.mapAttrs (_: x: x.enable) (
          lib.getAttrs [ "jellyfin" "youtube" "crunchyroll" "firefox" "plex-htpc" "moonlight" ] a
        );
      expected = {
        jellyfin = false;
        youtube = true;
        crunchyroll = false;
        firefox = true;
        plex-htpc = false;
        moonlight = false;
      };
    };
    testOnlineOnlyApps = {
      expr =
        let
          a =
            (mk (
              good
              // {
                apps = [
                  "plex-htpc"
                  "moonlight"
                ];
              }
            )).config;
        in
        [
          a.hinteros.apps.plex-htpc.enable
          a.hinteros.apps.moonlight.enable
          a.hinteros.unfreeAllowlist
        ];
      expected = [
        true
        true
        [ "plex-htpc" ]
      ];
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
    testUnknownAdminField = {
      expr = lib.hasInfix "unknown field(s) in settings.admin: password" (
        failures (
          good
          // {
            settings = good.settings // {
              admin = {
                user = "a";
                password = "x";
              };
            };
          }
        )
      );
      expected = true;
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
