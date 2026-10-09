# HinterOS' own packages. The component packages (hinteros-launcher, hinteros-session,
# hinteros-system) come from the component flakes' overlays, composed with this one in
# flake.nix's `overlays.default`.
final: prev: {
  hinteros-placeholder-home = final.callPackage ./pkgs/placeholder-home.nix { };
  hinteros-fake-steam = final.callPackage ./pkgs/fake-steam { };
  hinteros-firefox-kiosk = final.callPackage ./pkgs/firefox-kiosk.nix { };

  # InputPlumber 0.81.0 panics in its D-Bus method CompositeDevice.SendEvent (`blocking_send`
  # inside the tokio runtime, src/input/composite_device/client.rs:463) and never answers it, so
  # the session daemon's RT click hung (and, before the daemon's fix, all controller input with
  # it). Not fixed upstream (https://github.com/ShadowBlip/InputPlumber, master = v0.81.0 as of
  # 2026-10); drop the patch once a release awaits the command instead. Checked by `input-layer`
  # (the click answers and reaches the virtual mouse) and `daemon-eval` (the patch is applied).
  # pointer-response-curve.patch (HinterOS-only) makes stick->mouse speed = speed_pps * m^k, k from
  # INPUTPLUMBER_POINTER_CURVE (`hinteros.input.pointerCurve`).
  # gamescope turns the output off when it exits (finish_drm: CRTC inactive, "content type"
  # reset) and removes on-screen framebuffers with RmFB, which also turns it off. Each session
  # change (greeter -> console splash -> session) then needed full modesets: a blank and an HDMI
  # resync on a TV (i915 debug: "fastset requirement not met in avi infoframe", content type
  # Game vs Graphics). keep-output-on-exit.patch leaves the output running and closes its
  # framebuffers with CLOSEFB (kernel 6.8+), so the next DRM master takes over with a fastset.
  gamescope = prev.gamescope.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./pkgs/gamescope/keep-output-on-exit.patch ];
  });

  inputplumber = prev.inputplumber.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      ./pkgs/inputplumber/send-event-no-blocking-send.patch
      ./pkgs/inputplumber/pointer-response-curve.patch
    ];
  });
}
