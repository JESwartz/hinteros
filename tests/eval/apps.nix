# Eval-level tests for the app registry and the unfree allowlist. Nothing is built.
{ self, pkgs }:
let
  inherit (pkgs) lib;

  mk =
    extra:
    self.lib.mkDevice {
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
      extraModules = [
        { system.stateVersion = "25.11"; }
        extra
      ];
    };

  appsOf = c: map (a: a.id) c.config.hinteros.daemon.session.settings.apps;
  base = mk { };
  withInput = mk { hinteros.daemon.session.emitInputKeys = true; };
  vacuum = mk { hinteros.apps.youtube.backend = "vacuumtube"; };
  plex = mk { hinteros.apps.plex.enable = true; };
  forbidden = mk {
    hinteros.apps.plex.enable = true;
    hinteros.forbidUnfree = true;
  };
  entry = c: id: lib.findFirst (a: a.id == id) null c.config.hinteros.daemon.session.settings.apps;
  failedAssertions = c: map (a: a.message) (lib.filter (a: !a.assertion) c.config.assertions);

  results = lib.runTests {
    testDefaultApps = {
      expr = appsOf base;
      expected = [
        "jellyfin"
        "youtube"
        "crunchyroll"
        "firefox"
      ];
    };
    testNoUnfreeByDefault = {
      expr = base.config.hinteros.unfreeAllowlist;
      expected = [ ];
    };
    # The daemon locked at API 0.3 rejects unknown [[apps]] keys.
    testInputKeysOffByDefault = {
      expr = lib.any (a: a ? input || a ? back_key) base.config.hinteros.daemon.session.settings.apps;
      expected = false;
    };
    testInputKeysWhenEnabled = {
      expr = [
        (entry withInput "youtube").input
        (entry withInput "youtube").back_key
        (entry withInput "jellyfin" ? input)
      ];
      expected = [
        "keyboard"
        "Escape"
        false
      ];
    };
    testYoutubeKioskUserAgent = {
      expr = lib.elem "--user-agent" (entry base "youtube").command;
      expected = true;
    };
    testCrunchyrollNoUserAgent = {
      expr = lib.elem "--user-agent" (entry base "crunchyroll").command;
      expected = false;
    };
    testVacuumTubeBackend = {
      expr = lib.hasSuffix "/bin/VacuumTube" (lib.head (entry vacuum "youtube").command);
      expected = true;
    };
    testPlexAllowlisted = {
      expr = [
        (appsOf plex)
        (lib.elem "plex-htpc" plex.config.hinteros.unfreeAllowlist)
      ];
      expected = [
        [
          "jellyfin"
          "plex"
          "youtube"
          "crunchyroll"
          "firefox"
        ]
        true
      ];
    };
    testForbidUnfreeFails = {
      expr = lib.any (lib.hasInfix "forbidUnfree") (failedAssertions forbidden);
      expected = true;
    };
    testForbidUnfreeOkWithoutUnfree = {
      expr = lib.any (lib.hasInfix "forbidUnfree") (
        failedAssertions (mk {
          hinteros.forbidUnfree = true;
        })
      );
      expected = false;
    };
  };
in
pkgs.runCommand "hinteros-apps-eval" { } (
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
