# Generic hardware support for a device whose hardware report is not applied (yet): the system
# every offline install gets, which is the one prebuilt on the installer ISO. It has to boot
# whatever the machine is (storage, USB and card readers in the initrd), carry the redistributable
# firmware and both CPU microcodes, and must not depend on the machine, so that installing it
# builds nothing. `hinteros.lib.mkDevice` adds it when it gets no facter report; with a report,
# nixos-facter's own modules decide (and the system is then a different, bigger build).
{ lib, ... }:
{
  boot.initrd.availableKernelModules = [
    # SATA, NVMe (incl. Intel VMD), eMMC and card readers
    "ahci"
    "ata_piix"
    "ata_generic"
    "nvme"
    "vmd"
    "sd_mod"
    "sr_mod"
    "mmc_block"
    "sdhci_pci"
    "rtsx_pci_sdmmc"
    # USB host controllers, storage and keyboards (to type a disk password or reach a rescue shell)
    "xhci_pci"
    "xhci_hcd"
    "ehci_pci"
    "ehci_hcd"
    "ohci_pci"
    "uhci_hcd"
    "usb_storage"
    "uas"
    "usbhid"
    "hid_generic"
    # Virtual machines
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
  ];

  hardware = {
    enableRedistributableFirmware = lib.mkDefault true;
    cpu.intel.updateMicrocode = lib.mkDefault true;
    cpu.amd.updateMicrocode = lib.mkDefault true;
  };
}
