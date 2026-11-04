# Firefox for the TV apps (apps.md, "Firefox kiosk apps"; spike 8 item 3):
#   - box-wide: the enterprise policies at /etc/firefox/policies/policies.json (telemetry off,
#     DRM and VA-API prefs, the force-installed OSK extension, and on ESR the locked
#     `xpinstall.signatures.required = false`). Firefox reads that file whichever binary runs, so
#     a Firefox from a profile's app env gets them. No Firefox package is in the system for it
#     (no `programs.firefox`); the OSK .xpi it names is a store path in the system closure.
#   - per app env: `mkFirefox pkgs`, Firefox (ESR by default) wrapped with the autoConfig (the
#     OSK's privileged address-bar reporter) and the `hinteros-session` native-messaging host
#     (the nixpkgs wrapper points Firefox at its own lib/mozilla only), and `mkWrapper pkgs`, the
#     `hinteros-firefox-kiosk` wrapper around it (a profile per app, see
#     nixos/pkgs/firefox-kiosk.nix). app-env.nix passes `mkWrapper <env pkgs>` to the catalog as
#     `box.firefoxKiosk`; box-wide apps (test VMs) use `wrapper` (= `mkWrapper pkgs`).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hinteros.firefoxKiosk;
  ext = "hinteros-osk@hinteros";
  oskXpi =
    if cfg.oskExtension == "signed" then
      cfg.oskExtensionXpi
    else
      "${pkgs.hinteros-osk-firefox-extension}/share/hinteros/firefox/${ext}.xpi";
  lock = value: {
    Value = value;
    Status = "locked";
  };
  json = pkgs.formats.json { };

  # With the extension, autoConfig also runs privileged code (firefox-osk-chrome.js: the address
  # bar and other browser fields, which the extension cannot see), so it must not be sandboxed;
  # that pref only counts in a default-prefs file, hence extraAutoConfig.
  autoConfig = lib.concatStrings [
    (lib.optionalString (cfg.oskExtension == "esr-unsigned") ''
      lockPref("xpinstall.signatures.required", false);
    '')
    (lib.optionalString (cfg.oskExtension != "off") ''
      // The OSK extension also works in private windows and on sites Mozilla marks as
      // restricted (its own hard-blocked domains, extensions.webextensions.restrictedDomains,
      // stay blocked).
      lockPref("extensions.quarantineIgnoredByUser.${ext}", true);
      ${builtins.readFile ./firefox-osk-chrome.js}
    '')
  ];

  # What programs.firefox.finalPackage was, from any package set `p` (the system's or an app
  # env's): the same derivation for the same nixpkgs and settings.
  mkFirefox =
    p:
    let
      base =
        if cfg.oskExtension == "off" then
          p.firefox
        else
          (if cfg.oskExtension == "esr-unsigned" then p.firefox-esr else p.firefox).override {
            extraAutoConfig = ''pref("general.config.sandbox_enabled", false);'';
          };
    in
    base.override (old: {
      extraPrefsFiles = (old.extraPrefsFiles or [ ]) ++ [
        (p.writeText "firefox-autoconfig.js" autoConfig)
      ];
      # The OSK extension's host manifest, in Firefox's own MOZ_SYSTEM_DIR (spike 8: the only
      # system place the wrapped Firefox looks).
      nativeMessagingHosts = (old.nativeMessagingHosts or [ ]) ++ [ p.hinteros-session ];
    });

  mkWrapper = p: p.hinteros-firefox-kiosk.override { firefox = mkFirefox p; };
in
{
  options.hinteros.firefoxKiosk = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.hinteros.session.enable;
      defaultText = lib.literalExpression "config.hinteros.session.enable";
      description = ''
        Write the box-wide Firefox enterprise policies (`/etc/firefox/policies/policies.json`).
        Any profile may install a Firefox kiosk app, so this is on with the session. It installs no
        Firefox: the wrapped Firefox is part of the app envs (or of systemPackages for box-wide
        schema-1 apps, apps.nix).
      '';
    };

    oskExtension = lib.mkOption {
      type = lib.types.enum [
        "off"
        "esr-unsigned"
        "signed"
      ];
      default = "esr-unsigned";
      description = ''
        The Firefox extension behind the automatic on-screen keyboard (a text field getting
        focus in a kiosk app shows the keyboard; see the hinteros-daemon README). The
        native-messaging host manifest is always in the wrapped Firefox; it does nothing without
        the extension.

        - `off`: no extension, no automatic keyboard (Guide+Y still works).
        - `esr-unsigned`: Firefox ESR for the kiosk apps and plain Firefox, with extension
          signature checks switched off (`xpinstall.signatures.required = false`, locked in the
          policies and in autoConfig), and the daemon's unsigned .xpi force-installed through
          policy. Signature checks are off for every extension in that Firefox, not only ours.
        - `signed`: stock Firefox with signature checks on, force-installing the .xpi named by
          `oskExtensionXpi`, which must be signed (an unlisted add-on signed on addons.mozilla.org).
      '';
    };

    oskExtensionXpi = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Signed .xpi of the on-screen keyboard extension; required (and only used) when `oskExtension = \"signed\"`.";
    };

    policies = lib.mkOption {
      inherit (json) type;
      default = { };
      description = "Firefox enterprise policies (the `policies` object of policies.json), shared by every profile and every Firefox.";
    };

    autoConfig = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      internal = true;
      default = autoConfig;
      description = "The autoConfig (mozilla.cfg) of the wrapped Firefox.";
    };

    mkFirefox = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      internal = true;
      default = mkFirefox;
      description = "pkgs -> the wrapped Firefox (autoConfig and native-messaging host).";
    };

    mkWrapper = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      internal = true;
      default = mkWrapper;
      description = "pkgs -> `hinteros-firefox-kiosk` around `mkFirefox pkgs` (the catalog's `box.firefoxKiosk`).";
    };

    firefox = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = mkFirefox pkgs;
      defaultText = lib.literalMD "`mkFirefox pkgs`";
      description = "The wrapped Firefox built from the system's pkgs.";
    };

    wrapper = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = mkWrapper pkgs;
      defaultText = lib.literalMD "`mkWrapper pkgs`";
      description = "The `hinteros-firefox-kiosk` wrapper built from the system's pkgs (box-wide apps).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.oskExtension != "signed" || cfg.oskExtensionXpi != null;
        message = "hinteros.firefoxKiosk.oskExtension = \"signed\" needs hinteros.firefoxKiosk.oskExtensionXpi.";
      }
    ];

    environment.etc."firefox/policies/policies.json".source = json.generate "firefox-policies.json" {
      inherit (cfg) policies;
    };

    # Enterprise policies (policies.json), shared by all profiles including plain Firefox.
    hinteros.firefoxKiosk.policies = {
      DisableTelemetry = lib.mkDefault true;
      DisableFirefoxStudies = lib.mkDefault true;
      DisablePocket = lib.mkDefault true;
      DisableAppUpdate = lib.mkDefault true;
      DontCheckDefaultBrowser = lib.mkDefault true;
      NoDefaultBookmarks = lib.mkDefault true;
      DisableProfileImport = lib.mkDefault true;
      OverrideFirstRunPage = lib.mkDefault "";
      OverridePostUpdatePage = lib.mkDefault "";
      UserMessaging = lib.mkDefault {
        WhatsNew = false;
        ExtensionRecommendations = false;
        FeatureRecommendations = false;
        UrlbarInterventions = false;
        SkipOnboarding = true;
        MoreFromMozilla = false;
      };
      # No search box on about:home / about:newtab (the catalog's Firefox app starts there).
      # Firefox runs no extension in its about: pages, so the OSK never opens for that box; the
      # address bar (View: Ctrl+L and the on-screen keyboard) is the one place to type.
      FirefoxHome = lib.mkDefault { Search = false; };
      # No "save password?" prompts (the controller cannot dismiss them reliably).
      PasswordManagerEnabled = lib.mkDefault false;
      OfferToSaveLogins = lib.mkDefault false;
      Preferences = lib.mapAttrs (_: lib.mkDefault) (
        {
          "browser.aboutwelcome.enabled" = lock false;
          "browser.shell.checkDefaultBrowser" = lock false;
          "browser.startup.homepage_override.mstone" = lock "ignore";
          "datareporting.policy.dataSubmissionEnabled" = lock false;
          "datareporting.healthreport.uploadEnabled" = lock false;
          "toolkit.telemetry.enabled" = lock false;
          # DRM (Widevine): Firefox downloads the CDM into the profile on first use, so the
          # unfree blob is neither in the closure nor in any cache. Needs network.
          "media.eme.enabled" = lock true;
          "media.gmp-provider.enabled" = lock true;
          "media.gmp-widevinecdm.enabled" = lock true;
          "media.gmp-widevinecdm.visible" = lock true;
          "browser.eme.ui.enabled" = lock false; # no DRM info bar
          # Hardware video decoding (VA-API); the Intel driver comes from video-hardware.nix
          # (hardware.graphics, when the hardware report shows an Intel GPU).
          "media.ffmpeg.vaapi.enabled" = lock true;
          "media.hardware-video-decoding.force-enabled" = lock true;
          "media.rdd-ffmpeg.enabled" = lock true;
          "gfx.x11-egl.force-enabled" = lock true;
          # Autoplay without a mouse click, for TV UIs.
          "media.autoplay.default" = lock 0;
        }
        # Spike 8: on ESR this locked policy pref is enough for the unsigned OSK extension, so a
        # Firefox from any env gets it from this box-wide file.
        // lib.optionalAttrs (cfg.oskExtension == "esr-unsigned") {
          "xpinstall.signatures.required" = lock false;
        }
      );
      ExtensionSettings = lib.mkIf (cfg.oskExtension != "off") {
        ${ext} = {
          installation_mode = "force_installed";
          install_url = "file://${oskXpi}";
          private_browsing = true;
        };
      };
    };
  };
}
