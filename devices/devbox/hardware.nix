# Generic Intel iGPU mini PC bits, until the facter report and a hardware profile exist (M1).
{
  config,
  lib,
  pkgs,
  ...
}:
{
  networking.hostName = "hinteros-devbox";
  system.stateVersion = "25.11";

  hinteros = {
    session.gamescope.backend = "drm";
    # Start Steam (-silent, never under a reaper) with the session daemon.
    daemon.session.settings.steam.autostart = true;
  };

  # The session user is unprivileged here too (no wheel, no sudo, not a nix trusted user); deploys
  # go through the `deploy` user from hinteros.dev (see default.nix).

  # Intel graphics: Mesa plus VA-API (iHD) and QSV runtime.
  hardware.graphics = {
    enable = true;
    enable32Bit = true; # Steam/Proton
    extraPackages = with pkgs; [
      intel-media-driver
      vpl-gpu-rt
    ];
  };
  environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";

  # HDMI audio through PipeWire (enabled by hinteros.runtime).
  services.pipewire.alsa.support32Bit = true;

  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };

  # Placeholder disks for the checked-in state.json, which has no `disk` (default.nix). A state
  # with one (an installed box's, through the snapshot) gets the installer's layout instead.
  fileSystems = lib.mkIf (!config.hinteros.disk.enable) {
    "/" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
    };
    "/boot" = {
      device = "/dev/disk/by-label/BOOT";
      fsType = "vfat";
    };
  };
}
