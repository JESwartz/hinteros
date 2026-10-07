# Generic Intel iGPU mini PC bits, until the facter report and a hardware profile exist (M1).
{ pkgs, ... }:
{
  networking.hostName = "hinteros-devbox";
  system.stateVersion = "25.11";

  hinteros = {
    session.gamescope.backend = "drm";
    # Plex HTPC (unfree, never cached or on the ISO): enabled here until the App Store (M8).
    apps.plex-htpc.enable = true;
    # Start Steam (-silent, never under a reaper) with the session daemon.
    daemon.session.settings.steam.autostart = true;
    # A broken deploy falls back to the previous generation by itself.
    maintenance.bootCounting.enable = true;
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

  # TODO(M1): placeholder disks. Replace with the real partition layout (or let the
  # installer/facter report decide); this only has to evaluate and build for now.
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/BOOT";
    fsType = "vfat";
  };
}
