# HinterOS test system: boots straight into the console session.
# Shared by the interactive VM (nixosConfigurations.vm) and the nixosTest checks.
# gamescope cannot start on the VM's software Vulkan (llvmpipe: no DRM format
# modifiers, no dma-buf export), so the VM uses the cage fallback by default.
{ lib, ... }:
{
  hinteros.daemon.enable = true;

  hinteros.session = {
    enable = true;
    compositor = lib.mkDefault "cage";
    environment = {
      WLR_RENDERER = "pixman";
      WLR_NO_HARDWARE_CURSORS = "1";
      # Flutter GTK app on cage: Wayland, software GL (no GPU in the VM).
      GDK_BACKEND = "wayland";
      LIBGL_ALWAYS_SOFTWARE = "1";
      GALLIUM_DRIVER = "llvmpipe";
    };
  };

  networking.hostName = "hinteros-vm";
  system.stateVersion = "25.11";

  virtualisation = {
    memorySize = 3072;
    cores = 2;
  };
}
