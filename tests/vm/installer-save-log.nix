# hinteros-save-log: copies the diagnostics to a second stick. Attached to the installer VM are an
# exFAT stick (whole disk given), a FAT32 stick (partition given) and an NTFS stick, plus a tiny
# full stick, a stick labelled HINTEROS (the installer's label), a swap disk (unsupported) and an
# unformatted disk. Each success is verified by mounting the stick and reading the folder; each
# failure must give a clear message and leave nothing mounted.
{ self, pkgs }:
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-installer-save-log";

  nodes.installer =
    { lib, ... }:
    {
      imports = [ (import ./install/installer-node.nix { inherit self pkgs; }) ];
      # vdb is the install target (installer-node); vdc.. are the sticks.
      virtualisation = {
        emptyDiskImages = [
          256 # vdc: exFAT
          256 # vdd: FAT32
          256 # vde: NTFS
          4 # vdf: FAT, filled up below
          64 # vdg: FAT labelled HINTEROS
          64 # vdh: swap
          64 # vdi: nothing on it
        ];
        memorySize = lib.mkForce 3072;
        cores = lib.mkForce 2;
      };
    };

  testScript = ''
    installer.start()
    installer.wait_for_unit("multi-user.target")

    installer.succeed("""
      set -e
      parted -s /dev/vdc mklabel gpt mkpart stick 1MiB 100%
      parted -s /dev/vdd mklabel gpt mkpart stick 1MiB 100%
      parted -s /dev/vde mklabel gpt mkpart stick 1MiB 100%
      udevadm settle
      mkfs.exfat -L LOGEXFAT /dev/vdc1
      mkfs.vfat -n LOGVFAT /dev/vdd1
      mkfs.ntfs -F -Q -L LOGNTFS /dev/vde1
      mkfs.vfat -n TINY /dev/vdf
      mkfs.vfat -n HINTEROS /dev/vdg
      mkswap /dev/vdh
      udevadm settle
      echo 'fake install log line' > /var/log/hinteros-install.log
      mkdir -p /fill
      mount /dev/vdf /fill
      dd if=/dev/zero of=/fill/full bs=64k 2>/dev/null || true
      umount /fill
    """)

    def saved(dev, fstype):
        # Mount the stick again and return the saved folder's listing.
        installer.succeed(f"mkdir -p /verify && mount -t {fstype} -o ro {dev} /verify")
        folders = installer.succeed("ls -d /verify/hinteros-diagnostics-*").split()
        assert len(folders) == 1, folders
        files = installer.succeed(f"ls {folders[0]}").split()
        for f in ["hinteros-install.log", "journal.txt", "dmesg.txt", "hinteros-diagnose.txt",
                  "lspci.txt", "lsusb.txt", "nmcli-device.txt", "network-storage.txt"]:
            assert f in files, (f, files)
        assert "facter.json" in files or "facter.log" in files, files
        assert "fake install log line" in installer.succeed(f"cat {folders[0]}/hinteros-install.log")
        assert "HinterOS diagnose" in installer.succeed(f"cat {folders[0]}/hinteros-diagnose.txt")
        installer.succeed("umount /verify")

    def run(dev):
        status, out = installer.execute(f"hinteros-save-log {dev} 2>&1")
        assert status == 0, (dev, out)
        return out

    def nothing_mounted():
        installer.fail("findmnt -rno SOURCE | grep -E '^/dev/vd[c-i]'")

    # A whole disk: the first partition with a filesystem (exFAT).
    out = run("/dev/vdc")
    assert "/dev/vdc1" in out and "safe to remove" in out, out
    nothing_mounted()
    saved("/dev/vdc1", "exfat")

    # A partition (FAT32): the stick itself is a partition table plus one partition.
    out = run("/dev/vdd1")
    assert "safe to remove" in out, out
    nothing_mounted()
    saved("/dev/vdd1", "vfat")

    # NTFS through the kernel's ntfs3 driver.
    out = run("/dev/vde")
    assert "safe to remove" in out, out
    nothing_mounted()
    saved("/dev/vde1", "ntfs3")

    # Failures: the message says what is wrong, nothing stays mounted.
    def refused(dev, *words):
        status, out = installer.execute(f"hinteros-save-log {dev} 2>&1")
        assert status != 0, (dev, out)
        for w in words:
            assert w in out, (dev, w, out)
        nothing_mounted()

    refused("/dev/nope", "no such device")
    refused("/dev/vdi", "no partition with a filesystem")
    refused("/dev/vdh", "unsupported filesystem 'swap'", "vfat, exfat, ntfs, ext4")
    refused("/dev/vdg", "HINTEROS", "SECOND USB stick")
    refused("/dev/vdf", "not enough space")
    # The disk being installed to is refused (vdb is the target; hinteros-install links it).
    installer.succeed("ln -s /dev/vdb /dev/hinteros-target")
    refused("/dev/vdb", "installer stick or the disk being installed to")
    # A write-protected stick.
    installer.succeed("blockdev --setro /dev/vdd")
    status, out = installer.execute("hinteros-save-log /dev/vdd1 2>&1")
    assert status != 0 and ("read-only" in out or "could not mount" in out or "cannot write" in out), out
    nothing_mounted()
    installer.succeed("blockdev --setrw /dev/vdd")
  '';
}
