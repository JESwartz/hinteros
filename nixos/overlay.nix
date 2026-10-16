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
  #
  # The app sandbox's display split (design/sandbox.md, step 3: home app and OSK on Xwayland
  # #0, Steam games on #1, apps on #2):
  # xwayland-no-abstract-socket.patch: gamescope's wlroots opened each Xwayland on the socket
  #   file *and* the abstract socket @/tmp/.X11-unix/X<n>. Abstract sockets belong to the network
  #   namespace, so a sandboxed app (bwrap --share-net, only its display's socket file bound)
  #   could still connect to #0 and read the home app's keys. Now only the socket file.
  # xwayland-size-all.patch: only #0 followed the output (at start and on every mode change);
  #   the others kept the nested size. Now every Xwayland but #1 does (Steam sizes #1 itself).
  # xwayland-apps-no-input-emulation.patch: each Xwayland sent XTEST input to gamescope (libei,
  #   LIBEI_SOCKET), which gave it to the focused window on any Xwayland: an app on #2 could type
  #   into the home app. #2 now starts without LIBEI_SOCKET, so XTEST stays inside #2.
  # xwayland-apps-no-control.patch: gamescope read Steam's and its own control properties on every
  #   Xwayland: an app on #2 could set GAMESCOPECTRL_BASELAYER_APPID on its root (which app has
  #   focus), claim the home app's id with STEAM_GAME, make itself an overlay (STEAM_OVERLAY,
  #   GAMESCOPE_EXTERNAL_OVERLAY, STEAM_INPUT_FOCUS) or change global settings (FPS, VRR,
  #   scaling, modes, screenshots). On #2 and later (any number of app displays) only the window
  #   properties of ordinary X11 apps count now; their app id comes from the process tree.
  gamescope = prev.gamescope.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      ./pkgs/gamescope/keep-output-on-exit.patch
      ./pkgs/gamescope/xwayland-no-abstract-socket.patch
      ./pkgs/gamescope/xwayland-size-all.patch
      ./pkgs/gamescope/xwayland-apps-no-input-emulation.patch
      ./pkgs/gamescope/xwayland-apps-no-control.patch
    ];
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
