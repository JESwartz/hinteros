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
  lock = value: {
    Value = value;
    Status = "locked";
  };
in
{
  options.hinteros.firefoxKiosk = {
    enable = lib.mkEnableOption "Firefox with TV policies and the hinteros-firefox-kiosk wrapper";

    wrapper = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "The `hinteros-firefox-kiosk` wrapper, built against the policy-configured Firefox.";
    };
  };

  config = lib.mkIf cfg.enable {
    hinteros.firefoxKiosk.wrapper = pkgs.hinteros-firefox-kiosk.override {
      firefox = config.programs.firefox.finalPackage;
    };

    programs.firefox = {
      enable = true;
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
      };
    };

    environment.systemPackages = [ cfg.wrapper ];
  };
}
