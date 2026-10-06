# Eval-level tests for the app registry and the unfree allowlist. Nothing is built.
{ self, pkgs }:
let
  inherit (pkgs) lib;

  mk =
    extra:
    self.lib.mkDevice {
      state = {
        schemaVersion = 1;
        # A state selects its default apps; this test wants all four.
        apps = [
          "jellyfin"
          "youtube"
          "crunchyroll"
          "firefox"
        ];
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
  noOsk = mk {
    hinteros.daemon.osk.enable = false;
    hinteros.daemon.osk.summon = "none";
  };
  cage = mk { hinteros.session.compositor = "cage"; };
  settings = c: c.config.hinteros.daemon.session.settings;
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
    testInputKeysEmitted = {
      expr = [
        (entry base "youtube").input
        (entry base "youtube").back_key
        (entry base "jellyfin" ? input)
      ];
      expected = [
        "keyboard"
        "escape"
        false
      ];
    };
    testOskDefaults = {
      expr = [
        (settings base).osk.enable
        (settings base).osk.summon
        (lib.hasSuffix "/bin/hinteros-osk" (lib.head (settings base).osk.command))
      ];
      expected = [
        true
        "guide+context"
        true
      ];
    };
    testOskOff = {
      expr = [
        (settings noOsk).osk.enable
        (settings noOsk).osk.summon
      ];
      expected = [
        false
        "none"
      ];
    };
    testUsKeyboardLayout = {
      expr = base.config.hinteros.session.environment.XKB_DEFAULT_LAYOUT;
      expected = "us";
    };
    # cage: apps and the daemon find cage's sockets without per-test overrides.
    testCageSockets = {
      expr = [
        (settings cage).gamescope.wayland_display
        cage.config.systemd.user.services.hinteros-session.environment.DISPLAY
      ];
      expected = [
        "wayland-0"
        ":0"
      ];
    };
    # A gamescope version the daemon's vendored protocol was not reviewed against must not evaluate.
    testGamescopePinFails = {
      expr = lib.any (lib.hasInfix "gamescope is") (
        failedAssertions (mk {
          hinteros.session.compositor = "gamescope";
          hinteros.session.gamescope.reviewedVersion = "0.0.0";
        })
      );
      expected = true;
    };
    testGamescopePinOk = {
      expr = lib.any (lib.hasInfix "gamescope is") (
        failedAssertions (mk {
          hinteros.session.compositor = "gamescope";
        })
      );
      expected = false;
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
