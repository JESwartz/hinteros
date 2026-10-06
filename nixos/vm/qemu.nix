# Interactive VM hardware: virtio-vga window, software rendering.
{ modulesPath, ... }:
{
  imports = [ "${modulesPath}/virtualisation/qemu-vm.nix" ];

  virtualisation = {
    resolution = {
      x = 1280;
      y = 720;
    };
    qemu.options = [
      "-vga none"
      "-device virtio-vga"
    ];
  };
}
