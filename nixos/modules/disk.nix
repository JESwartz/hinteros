# The disk layout the installer creates (nixos/pkgs/hinteros-install, disko): GPT with a 1 GiB
# EFI system partition and one btrfs file system with the subvolumes `root` (/, with /var in it),
# `nix`, `home` and `srv`. UEFI only, systemd-boot. Enabled by state.json `disk`.
#
# Both are found by UUID (state.json `disk.rootUuid`, `disk.espUuid`, written by the installer), so
# a second HinterOS disk in the box cannot confuse the boot. The subvolumes let a reinstall replace
# the system and keep the data (`keepData`). No snapshots and no scrub service; generations and
# /etc/hinteros snapshots are the rollback story. No encryption (threat-model.md, decided).
{ config, lib, ... }:
let
  cfg = config.hinteros.disk;

  # The same options as the installer's disko config (nixos/installer).
  subvolume = name: {
    device = "/dev/disk/by-uuid/${cfg.rootUuid}";
    fsType = "btrfs";
    options = [
      "subvol=${name}"
      "compress=zstd:1"
      "noatime"
    ];
  };
in
{
  options.hinteros.disk = {
    enable = lib.mkEnableOption "the installer's disk layout: ESP and btrfs subvolumes by UUID, systemd-boot";

    rootUuid = lib.mkOption {
      type = lib.types.str;
      description = "UUID of the btrfs file system (state.json `disk.rootUuid`).";
    };

    espUuid = lib.mkOption {
      type = lib.types.str;
      description = "Volume id of the EFI system partition, mounted at /boot (state.json `disk.espUuid`).";
    };
  };

  config = lib.mkIf cfg.enable {
    fileSystems = {
      "/" = subvolume "root";
      "/nix" = subvolume "nix";
      "/home" = subvolume "home";
      "/srv" = subvolume "srv";
      "/boot" = {
        device = "/dev/disk/by-uuid/${cfg.espUuid}";
        fsType = "vfat";
        # The ESP holds the boot loader's random seed: root only.
        options = [ "umask=0077" ];
      };
    };

    boot.loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
      # No generation menu: the default (newest good) generation boots at once. Generations are
      # managed from the launcher, and boot counting falls back by itself. Holding Space (or any
      # key) while the box starts still shows systemd-boot's menu, for recovery.
      timeout = lib.mkDefault 0;
    };

    # The hardware report (facter.json) adds what it detects; these cover the common mini PC
    # storage paths if the report is missing, so the box still finds its root.
    boot.initrd.availableKernelModules = [
      "ahci"
      "nvme"
      "sd_mod"
      "usb_storage"
      "xhci_pci"
      "sdhci_pci"
      "virtio_pci"
      "virtio_blk"
    ];

    # A 4-8 GB box evaluating and building a rebuild should not hit the OOM killer.
    zramSwap.enable = lib.mkDefault true;
  };
}
