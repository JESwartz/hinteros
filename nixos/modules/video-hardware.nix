# Hardware video decoding (VA-API) on Intel GPUs. Mesa has no VA-API driver for Intel, so without
# this every app decoded video on the CPU, although the Firefox kiosk asks for hardware decoding.
# Intel's media driver (iHD) covers Broadwell and newer; on Skylake (the Lenovo M900's HD 530)
# that is H.264, HEVC 8-bit, VP8, MPEG-2 and VC-1, not VP9 or AV1. It helps streaming into the
# box (Moonlight, Steam Remote Play), Jellyfin and local video; DRM services in Firefox decode
# in Widevine anyway. libva picks the driver itself (i915: iHD, then i965), so no
# LIBVA_DRIVER_NAME: an older GPU still falls back. Sandboxed apps see it through
# /run/opengl-driver.
#
# On when the hardware report (nixos-facter) shows a GPU on i915 or xe, the way nixos-facter's
# own graphics modules detect cards. The generic system (no report yet) does without.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cards = config.hardware.facter.report.hardware.graphics_card or [ ];
  drivers = lib.concatMap (
    c: lib.toList (c.driver or [ ]) ++ lib.toList (c.driver_module or [ ])
  ) cards;
  intelGpu = lib.any (
    d:
    lib.elem d [
      "i915"
      "xe"
    ]
  ) drivers;
in
{
  options.hinteros.hardware.intelVideo.enable =
    lib.mkEnableOption "Intel's VA-API driver (intel-media-driver) for hardware video decoding"
    // {
      default = intelGpu;
      defaultText = lib.literalMD "on when the hardware report shows a GPU on `i915` or `xe`";
    };

  config = lib.mkIf (config.hinteros.hardware.intelVideo.enable && config.hardware.graphics.enable) {
    hardware.graphics.extraPackages = [ pkgs.intel-media-driver ];
  };
}
