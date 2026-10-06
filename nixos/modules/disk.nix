# The disk layout the installer creates (nixos/pkgs/hinteros-install, disko): GPT with a 1 GiB
# EFI system partition and an ext4 root, both found by partition label so the config does not
# depend on device names or UUIDs. UEFI only, systemd-boot. Enabled by state.json `disk`.
#
# ext4 on purpose: nothing here needs snapshots (generations and /etc/hinteros snapshots are the
# rollback story), it is the best-tested NixOS root, and `fsck` after a power cut at the TV is
# boring. No encryption (threat-model.md, decided).
{ config, lib, ... }:
let
  cfg = config.hinteros.disk;
in
{
  options.hinteros.disk = {
    enable = lib.mkEnableOption "the installer's disk layout: ESP and ext4 root by partition label, systemd-boot";

    espLabel = lib.mkOption {
      type = lib.types.str;
      default = "hinteros-esp";
      description = "GPT partition label of the EFI system partition (mounted at /boot).";
    };

    rootLabel = lib.mkOption {
      type = lib.types.str;
      default = "hinteros-root";
      description = "GPT partition label of the root file system.";
    };
  };

  config = lib.mkIf cfg.enable {
    fileSystems = {
      "/" = {
        device = "/dev/disk/by-partlabel/${cfg.rootLabel}";
        fsType = "ext4";
        options = [ "noatime" ];
      };
      "/boot" = {
        device = "/dev/disk/by-partlabel/${cfg.espLabel}";
        fsType = "vfat";
        # The ESP holds the boot loader's random seed: root only.
        options = [ "umask=0077" ];
      };
    };

    boot.loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
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
