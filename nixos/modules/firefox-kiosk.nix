# Firefox for the TV apps: one enterprise policy set shared by every profile, plus the
# `hinteros-firefox-kiosk` wrapper (a profile per app, see nixos/pkgs/firefox-kiosk.nix).
# Enabled automatically when an app in hinteros.apps uses a kiosk URL.
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
in
{
  options.hinteros.firefoxKiosk = {
    enable = lib.mkEnableOption "Firefox with TV policies and the hinteros-firefox-kiosk wrapper";

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
        native-messaging host manifest is always installed; it does nothing without the extension.

        - `off`: no extension, no automatic keyboard (Guide+Y still works).
        - `esr-unsigned`: Firefox ESR for the kiosk apps and plain Firefox, with extension
          signature checks switched off (`xpinstall.signatures.required = false` in autoConfig),
          and the daemon's unsigned .xpi force-installed through policy. Signature checks are off
          for every extension in that Firefox, not only ours.
        - `signed`: stock Firefox with signature checks on, force-installing the .xpi named by
          `oskExtensionXpi`, which must be signed (an unlisted add-on signed on addons.mozilla.org).
      '';
    };

    oskExtensionXpi = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Signed .xpi of the on-screen keyboard extension; required (and only used) when `oskExtension = \"signed\"`.";
    };

    wrapper = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "The `hinteros-firefox-kiosk` wrapper, built against the policy-configured Firefox.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.oskExtension != "signed" || cfg.oskExtensionXpi != null;
        message = "hinteros.firefoxKiosk.oskExtension = \"signed\" needs hinteros.firefoxKiosk.oskExtensionXpi.";
      }
    ];

    hinteros.firefoxKiosk.wrapper = pkgs.hinteros-firefox-kiosk.override {
      firefox = config.programs.firefox.finalPackage;
    };

    programs.firefox = {
      enable = true;
      # The OSK extension's host manifest, linked into Firefox's own native-messaging dir.
      nativeMessagingHosts.packages = [ pkgs.hinteros-session ];
      package = lib.mkIf (cfg.oskExtension == "esr-unsigned") pkgs.firefox-esr;
      autoConfig = lib.mkIf (cfg.oskExtension == "esr-unsigned") ''
        lockPref("xpinstall.signatures.required", false);
      '';
      # Enterprise policies (policies.json), shared by all profiles including plain Firefox.
      policies = {
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
        # No "save password?" prompts (the controller cannot dismiss them reliably).
        PasswordManagerEnabled = lib.mkDefault false;
        OfferToSaveLogins = lib.mkDefault false;
        Preferences = lib.mapAttrs (_: lib.mkDefault) {
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
          # Hardware video decoding (VA-API); the Intel driver comes from hardware.graphics.
          "media.ffmpeg.vaapi.enabled" = lock true;
          "media.hardware-video-decoding.force-enabled" = lock true;
          "media.rdd-ffmpeg.enabled" = lock true;
          "gfx.x11-egl.force-enabled" = lock true;
          # Autoplay without a mouse click, for TV UIs.
          "media.autoplay.default" = lock 0;
        };
        ExtensionSettings = lib.mkIf (cfg.oskExtension != "off") {
          ${ext} = {
            installation_mode = "force_installed";
            install_url = "file://${oskXpi}";
          };
        };
      };
    };

    environment.systemPackages = [ cfg.wrapper ];
  };
}
