# The installer ISO: the NixOS installation CD base (UEFI and BIOS bootable, hybrid for USB) plus
# the installer environment (default.nix).
{
  lib,
  modulesPath,
  ...
}:
{
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-base.nix"
  ];

  image.baseName = lib.mkForce "hinteros-installer";
  isoImage = {
    volumeID = "HINTEROS";
    edition = "hinteros";
    # Level 19 shaves a few hundred MB off but doubles the build time; level 15 is the middle.
    squashfsCompression = "zstd -Xcompression-level 15";
  };

  # Flakes only: the nixos channel copy would add a second nixpkgs source.
  system.installer.channel.enable = false;

  # No ZFS (kernel module builds, size); ext4 and vfat are all the installer needs.
  boot.supportedFilesystems.zfs = lib.mkForce false;
  networking.hostName = "hinteros-installer";

  # Man pages and docs cost size; the console notice says what to run.
  documentation = {
    enable = lib.mkForce false;
    nixos.enable = lib.mkForce false;
    man.enable = lib.mkForce false;
    doc.enable = lib.mkForce false;
  };
}
