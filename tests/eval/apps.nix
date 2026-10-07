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

  appsOf = c: map (a: a.id) (c.config.hinteros.daemon.session.settings.apps or [ ]);
  base = mk { };
  noOsk = mk {
    hinteros.daemon.osk.enable = false;
    hinteros.daemon.osk.summon = "none";
  };
  cage = mk { hinteros.session.compositor = "cage"; };
  settings = c: c.config.hinteros.daemon.session.settings;
  plex = mk { hinteros.apps.plex-htpc.enable = true; };
  forbidden = mk {
    hinteros.apps.plex-htpc.enable = true;
    hinteros.forbidUnfree = true;
  };
  entry = c: id: lib.findFirst (a: a.id == id) null c.config.hinteros.daemon.session.settings.apps;
  failedAssertions = c: map (a: a.message) (lib.filter (a: !a.assertion) c.config.assertions);

  catalogEntries = self.inputs.hinteros-catalog.catalog;
  liveIds = builtins.attrNames (lib.filterAttrs (_: e: e.status != "removed") catalogEntries);
  mkApps =
    ids: extra:
    self.lib.mkDevice {
      state = {
        schemaVersion = 1;
        apps = ids;
        disk.layout = "gpt-esp-ext4";
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
  # A device with every catalog entry enabled (nothing built: the drv paths below force evaluation).
  every = mkApps liveIds { };
  iso = self.nixosConfigurations.installer;
  cacheable = self.inputs.hinteros-catalog.lib.cacheableUnfree;
  # What the cache job builds: everything but unfree-and-not-redistributable.
  cacheJob = mkApps (lib.filter (id: !(lib.elem id [ "plex-htpc" ])) liveIds) {
    hinteros.forbidUnfree = true;
    hinteros.unfreeExceptions = cacheable;
  };
  sessionCmd = c: c.config.services.greetd.settings.initial_session.command;
  gs = mk { hinteros.session.compositor = "gamescope"; };

  fx = c: c.config.programs.firefox;
  oskOff = mk { hinteros.firefoxKiosk.oskExtension = "off"; };
  oskEsr = mk { hinteros.firefoxKiosk.oskExtension = "esr-unsigned"; };
  oskSigned = mk {
    hinteros.firefoxKiosk.oskExtension = "signed";
    hinteros.firefoxKiosk.oskExtensionXpi = "/nix/store/00000000000000000000000000000000-signed/osk.xpi";
  };
  oskSignedNoXpi = mk { hinteros.firefoxKiosk.oskExtension = "signed"; };
  extId = "hinteros-osk@hinteros";
  oskFailures = c: lib.filter (lib.hasInfix "oskExtension") (failedAssertions c);
  hasSub = s: sub: lib.hasInfix sub (toString s);

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
    testPlexAllowlisted = {
      expr = [
        (appsOf plex)
        (lib.elem "plex-htpc" plex.config.hinteros.unfreeAllowlist)
      ];
      expected = [
        [
          "jellyfin"
          "plex-htpc"
          "youtube"
          "crunchyroll"
          "firefox"
        ]
        true
      ];
    };
    # Icons: the catalog's fields reach session.toml; no generated icon files.
    testIconFields = {
      expr = [
        (entry base "jellyfin").desktop_id
        (entry base "youtube").firefox_profile
        (entry base "youtube").site_url
        (lib.hasPrefix "https://" (entry base "youtube").icon_url)
        (entry base "crunchyroll" ? icon_url)
        (lib.any (a: a ? icon) (settings base).apps)
      ];
      expected = [
        "org.jellyfin.JellyfinDesktop"
        "~/.local/share/hinteros/firefox/youtube"
        "https://www.youtube.com"
        true
        false
        false
      ];
    };
    # The catalog index and vendor terms are installed.
    testIndexInstalled = {
      expr = lib.elem base.config.hinteros.catalog.index base.config.environment.systemPackages;
      expected = true;
    };
    # Steam only adds system config (its tile is the daemon's built-in one) and is cached: allowed by name.
    testSteamNotListed = {
      expr =
        let
          s = mkApps [ "steam" ] { };
        in
        [
          (appsOf s)
          s.config.programs.steam.enable
          s.config.hinteros.unfreeAllowlist
          s.config.hardware.graphics.enable32Bit
        ];
      expected = [
        [ ]
        true
        [
          "steam"
          "steam-unwrapped"
        ]
        true
      ];
    };
    # Unfree for the cache job: only the catalog's cacheable names (Steam), never Plex.
    testCacheableIsSteamOnly = {
      expr = cacheable;
      expected = [
        "steam"
        "steam-unwrapped"
      ];
    };
    testCacheJobPasses = {
      expr = failedAssertions cacheJob;
      expected = [ ];
    };
    testCacheJobRefusesPlex = {
      expr = lib.any (lib.hasInfix "plex-htpc") (
        failedAssertions (
          mkApps [ "plex-htpc" ] {
            hinteros.forbidUnfree = true;
            hinteros.unfreeExceptions = cacheable;
          }
        )
      );
      expected = true;
    };
    # The ISO is fully free: no allowlist, no exceptions, Steam not on it (it is cached, not shipped).
    testIsoFullyFree = {
      expr = [
        iso.config.hinteros.unfreeAllowlist
        iso.config.hinteros.unfreeExceptions
        iso.config.hinteros.forbidUnfree
        (lib.any (a: !a.assertion) iso.config.assertions)
      ];
      expected = [
        [ ]
        [ ]
        true
        false
      ];
    };
    testEveryEntryEnabled = {
      expr = lib.all (id: every.config.hinteros.apps.${id}.enable) liveIds;
      expected = true;
    };
    # gamescope: mode files for the runtime display settings, no fixed output size.
    testGamescopeModeFiles = {
      expr = [
        (lib.hasInfix "hinteros-display-env" (sessionCmd gs))
        (lib.hasInfix " -W" (sessionCmd gs))
        (lib.hasInfix " -H" (sessionCmd gs))
        (lib.hasInfix " -r " (sessionCmd gs))
        (lib.hasInfix "hinteros-display-env" gs.config.systemd.user.services.hinteros-session.serviceConfig.ExecStart)
      ];
      expected = [
        true
        false
        false
        false
        true
      ];
    };
    # gamescope: apps on Xwayland sized to the output (README "Display size"), output logged.
    testGamescopeAppSize = {
      expr = [
        (lib.hasInfix "--xwayland-count 2 --force-windows-fullscreen" (sessionCmd gs))
        (lib.hasInfix "GDK_BACKEND=x11" (sessionCmd gs))
        gs.config.systemd.user.services.hinteros-session.environment.GDK_BACKEND
        (lib.hasInfix "systemd-cat --identifier hinteros-compositor" (sessionCmd gs))
        (cage.config.hinteros.session.environment.GDK_BACKEND or "unset")
        (cage.config.systemd.user.services.hinteros-session.environment.GDK_BACKEND or "unset")
      ];
      expected = [
        true
        true
        "x11"
        true
        "unset"
        "unset"
      ];
    };
    testPactl = {
      expr = lib.hasSuffix "/bin/pactl" (settings base).audio.pactl;
      expected = true;
    };
    testForbidUnfreeFails = {
      expr = lib.any (lib.hasInfix "forbidUnfree") (failedAssertions forbidden);
      expected = true;
    };
    # Firefox auto-OSK extension: the native-messaging host is always installed.
    # The default is the owner's choice: Firefox ESR with the extension force-installed.
    testOskExtensionDefault = {
      expr = [
        base.config.hinteros.firefoxKiosk.oskExtension
        (lib.hasSuffix "esr" (fx base).finalPackage.version)
        ((fx base).policies.ExtensionSettings ? "${extId}")
      ];
      expected = [
        "esr-unsigned"
        true
        true
      ];
    };
    testOskExtensionOff = {
      expr = [
        oskOff.config.hinteros.firefoxKiosk.oskExtension
        ((fx oskOff).policies.ExtensionSettings ? "${extId}")
        (fx oskOff).autoConfig
        (lib.hasSuffix "esr" (fx oskOff).package.version)
        (map lib.getName (fx oskOff).nativeMessagingHosts.packages)
        (settings oskOff).osk.auto_show
        (settings oskOff).input.xbox_label_swap
      ];
      expected = [
        "off"
        false
        ""
        false
        [ "hinteros-session" ]
        true
        "auto"
      ];
    };
    testOskExtensionEsrUnsigned = {
      expr = [
        (lib.hasSuffix "esr" (fx oskEsr).package.version)
        (hasSub (fx oskEsr).autoConfig ''lockPref("xpinstall.signatures.required", false);'')
        (fx oskEsr).policies.ExtensionSettings.${extId}.installation_mode
        (hasSub (fx oskEsr).policies.ExtensionSettings.${extId}.install_url
          "hinteros-osk-firefox-extension"
        )
        (lib.hasPrefix "file:///nix/store/" (fx oskEsr).policies.ExtensionSettings.${extId}.install_url)
        (lib.hasSuffix "/hinteros-osk@hinteros.xpi"
          (fx oskEsr).policies.ExtensionSettings.${extId}.install_url
        )
        (oskFailures oskEsr)
      ];
      expected = [
        true
        true
        "force_installed"
        true
        true
        true
        [ ]
      ];
    };
    testOskExtensionSigned = {
      expr = [
        (lib.hasSuffix "esr" (fx oskSigned).package.version)
        (fx oskSigned).autoConfig
        (fx oskSigned).policies.ExtensionSettings.${extId}.install_url
        (oskFailures oskSigned)
      ];
      expected = [
        false
        ""
        "file:///nix/store/00000000000000000000000000000000-signed/osk.xpi"
        [ ]
      ];
    };
    testOskExtensionSignedNeedsXpi = {
      expr = lib.any (lib.hasInfix "oskExtensionXpi") (oskFailures oskSignedNoXpi);
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
pkgs.runCommand "hinteros-apps-eval"
  {
    # Evaluation only: every catalog entry in one device config, and the ISO (which throws on any
    # unfree package, as it allows none).
    everyDrv = builtins.unsafeDiscardStringContext every.config.system.build.toplevel.drvPath;
    cacheDrv = builtins.unsafeDiscardStringContext cacheJob.config.system.build.toplevel.drvPath;
    isoDrv = builtins.unsafeDiscardStringContext iso.config.system.build.isoImage.drvPath;
  }
  (
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
