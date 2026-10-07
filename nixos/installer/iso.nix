# The installer ISO: the NixOS installation CD base (UEFI and BIOS bootable, hybrid for USB) plus
# the installer environment (default.nix).
{
  lib,
  pkgs,
  modulesPath,
  ...
}:
{
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-base.nix"
  ];

  # The controller-driven installer screens (the launcher in installer mode) on tty1.
  hinteros.installer.ui.command = [
    (lib.getExe' pkgs.hinteros-launcher "hinteros-launcher")
    "--installer"
  ];

  image.baseName = lib.mkForce "hinteros-installer";
  isoImage = {
    volumeID = "HINTEROS";
    edition = "hinteros";
    # Level 19 shaves a few hundred MB off but doubles the build time; level 15 is the middle.
    squashfsCompression = "zstd -Xcompression-level 15";
    # Boot menu: "HinterOS <version> Installer" (the name is system.nixos.distroName, branding.nix).
    appendToMenuLabel = " Installer";
  };

  boot = {
    initrd = {
      # The stick is read through USB storage: make sure stage 1 has every common controller and
      # the storage drivers (the installation CD base lists only some of them).
      availableKernelModules = [
        "xhci_pci"
        "xhci_hcd"
        "ehci_pci"
        "ehci_hcd"
        "ohci_pci"
        "ohci_hcd"
        "uhci_hcd"
        "usb_storage"
        "uas"
        "sd_mod"
        "sr_mod"
      ];
      # A slow or sleepy stick can take longer than systemd's 90 s to show up: give the live
      # medium five minutes before stage 1 gives up on /dev/disk/by-label/HINTEROS.
      systemd.settings.Manager.DefaultDeviceTimeoutSec = "300s";
    };
    # No ZFS (kernel module builds, size); ext4 and vfat are all the installer needs.
    supportedFilesystems.zfs = lib.mkForce false;
  };

  # A "debug" entry in the boot menu: the same system with verbose kernel, udev and stage 1 logs.
  specialisation.debug.configuration = {
    hinteros.boot.quiet = false;
    isoImage.configurationName = "(debug: verbose boot)";
  };

  # Flakes only: the nixos channel copy would add a second nixpkgs source.
  system.installer.channel.enable = false;

  networking.hostName = "hinteros-installer";

  # Man pages and docs cost size; the console notice says what to run.
  documentation = {
    enable = lib.mkForce false;
    nixos.enable = lib.mkForce false;
    man.enable = lib.mkForce false;
    doc.enable = lib.mkForce false;
  };
}
