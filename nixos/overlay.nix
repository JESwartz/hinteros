# HinterOS' own packages. The component packages (hinteros-launcher, hinteros-session,
# hinteros-system) come from the component flakes' overlays, composed with this one in
# flake.nix's `overlays.default`.
final: prev: {
  hinteros-placeholder-home = final.callPackage ./pkgs/placeholder-home.nix { };
  hinteros-fake-steam = final.callPackage ./pkgs/fake-steam { };
  hinteros-firefox-kiosk = final.callPackage ./pkgs/firefox-kiosk.nix { };

  # gamescope turned the output off when it exited (finish_drm: CRTC inactive) and set the
  # HDMI "content type" to Game, which the console's framebuffer does not. Each change between
  # the console splash and a gamescope (boot -> picker, picker -> session) then needed a full
  # modeset: a blank and an HDMI resync on a TV (i915 debug: "fastset requirement not met in
  # avi infoframe"). keep-output-on-exit.patch leaves the output running at exit (its on-screen
  # framebuffers closed with CLOSEFB, kernel 6.8+, which unlike RmFB keeps them up) and leaves
  # "content type" as the kernel has it, so the next DRM master takes over with a fastset.
  # While running gamescope still frees buffers with RmFB: it relies on that turning off the
  # plane of a window that went away (CLOSEFB there left a dead Steam frame on screen).
  gamescope = prev.gamescope.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./pkgs/gamescope/keep-output-on-exit.patch ];
  });

  # InputPlumber 0.81.0 panics in its D-Bus method CompositeDevice.SendEvent (`blocking_send`
  # inside the tokio runtime, src/input/composite_device/client.rs:463) and never answers it, so
  # the session daemon's RT click hung (and, before the daemon's fix, all controller input with
  # it). Not fixed upstream (https://github.com/ShadowBlip/InputPlumber, master = v0.81.0 as of
  # 2026-10); drop the patch once a release awaits the command instead. Checked by `input-layer`
  # (the click answers and reaches the virtual mouse) and `daemon-eval` (the patch is applied).
  # pointer-response-curve.patch (HinterOS-only) makes stick->mouse speed = speed_pps * m^k, k from
  # INPUTPLUMBER_POINTER_CURVE (`hinteros.input.pointerCurve`).
  inputplumber = prev.inputplumber.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      ./pkgs/inputplumber/send-event-no-blocking-send.patch
      ./pkgs/inputplumber/pointer-response-curve.patch
    ];
  });
}
