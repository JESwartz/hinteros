# HinterOS branding and a quiet boot, for devices and the installer ISO.
#
# The name comes from `system.nixos.distroName`: it shows in the boot menu entries (systemd-boot,
# GRUB, the ISO's menu), /etc/os-release and the login banner. `distroId` stays `nixos` on purpose:
# other NixOS modules and tools test for it.
#
# Quiet boot: `quiet`, `udev.log_level=3` and console log level 3 hide the kernel and udev
# chatter. `hinteros.boot.quiet = false` gives the verbose boot; the ISO has a boot menu entry
# for it ("debug"), see nixos/installer/iso.nix.
{ config, lib, ... }:
let
  cfg = config.hinteros.boot;
in
{
  options.hinteros.boot.quiet = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Quiet boot: no kernel and udev messages on the console, only errors. Off: verbose logs.";
  };

  config = {
    system.nixos.distroName = lib.mkDefault "HinterOS";

    boot = {
      consoleLogLevel = lib.mkDefault (if cfg.quiet then 3 else 7);
      kernelParams = lib.optionals cfg.quiet [
        "quiet"
        "udev.log_level=3"
      ];
      initrd.verbose = lib.mkDefault (!cfg.quiet);
    };
  };
}
