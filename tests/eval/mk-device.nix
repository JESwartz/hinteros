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
    testFacterM900NoSecondDhcp = {
      expr = noDhcp (self + "/tests/vm/fixtures/facter-lenovo-m900.json");
      expected = noDhcpExpected;
    };
    testFacterIntelMinipcNoSecondDhcp = {
      expr = noDhcp (self + "/tests/vm/fixtures/facter-intel-minipc.json");
      expected = noDhcpExpected;
    };
    testGoodHasNoFailures = {
      expr = failures good;
      expected = "";
    };
    testSteamEnabled = {
      expr = c.programs.steam.enable;
      expected = true;
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
      expr = lib.hasInfix "unsupported schemaVersion 2" (failures (good // { schemaVersion = 2; }));
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
