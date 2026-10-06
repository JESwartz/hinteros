# Eval-level tests for lib.mkDevice and the state.json translation: good states evaluate and
# map to the expected options; bad ones fail evaluation with a clear message. Nothing is built.
{ self, pkgs }:
let
  inherit (pkgs) lib;

  good = {
    schemaVersion = 1;
    settings.ssh = {
      enable = true;
      authorizedKeys = [ "ssh-ed25519 AAAATESTKEY test" ];
    };
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

  results = lib.runTests {
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
    testSshEnabledKeyOnly = {
      expr = [
        c.services.openssh.enable
        c.services.openssh.settings.PasswordAuthentication
        c.users.users.tester.openssh.authorizedKeys.keys
      ];
      expected = [
        true
        false
        [ "ssh-ed25519 AAAATESTKEY test" ]
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
    testUnknownApp = {
      expr = lib.hasInfix "unknown app id(s): plex-htpc" (failures (good // { apps = [ "plex-htpc" ]; }));
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
