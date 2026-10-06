# Generic Intel iGPU mini PC bits, until the facter report and a hardware profile exist (M1).
{ pkgs, ... }:
{
  networking.hostName = "hinteros-devbox";
  system.stateVersion = "25.11";

  hinteros.session.gamescope.backend = "drm";

  # Start Steam (-silent, never under a reaper) with the session daemon.
  hinteros.daemon.session.settings.steam.autostart = true;

  # Dev box only: the deploy user (the session user) can sudo without a password, and
  # nixos-rebuild may copy unsigned closures to it. Boxes #2 and #3 do not get this.
  security.sudo.wheelNeedsPassword = false;
  users.users.hinteros.extraGroups = [ "wheel" ];
  nix.settings.trusted-users = [ "@wheel" ];

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

  # HDMI audio through PipeWire.
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

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
