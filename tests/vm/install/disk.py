# The installed disk's layout (included in the install tests' scripts, after copy-plan.py, whose
# `_json` it uses). `installer` and the machine passed in are the test's nodes.


def mount_target():
    """The installer VM: the installed system's root and store at /mnt, as far as a test needs."""
    if installer.execute("mountpoint -q /mnt")[0] == 0:
        return
    part = "/dev/disk/by-partlabel/hinteros-root"
    installer.succeed(f"mkdir -p /mnt && mount -o subvol=root {part} /mnt && mount -o subvol=nix {part} /mnt/nix")


def check_layout(machine, state):
    """The running box: subvolumes and options, and state.json `disk` as the disk says it."""
    disk = state["disk"]
    assert sorted(disk) == ["espUuid", "layout", "rootUuid"] and disk["layout"] == "gpt-esp-btrfs", disk
    root = machine.succeed("readlink -f /dev/disk/by-partlabel/hinteros-root").strip()
    esp = machine.succeed("readlink -f /dev/disk/by-partlabel/hinteros-esp").strip()
    assert machine.succeed(f"blkid -o value -s UUID {root}").strip() == disk["rootUuid"], disk
    assert machine.succeed(f"blkid -o value -s UUID {esp}").strip() == disk["espUuid"], disk
    assert machine.succeed(f"blkid -o value -s TYPE {root}").strip() == "btrfs"
    mounts = _json.loads(machine.succeed("findmnt -J -o TARGET,SOURCE,FSTYPE,OPTIONS,FSROOT --list"))["filesystems"]
    by_target = {m["target"]: m for m in mounts}
    for target, subvol in (("/", "root"), ("/nix", "nix"), ("/home", "home"), ("/srv", "srv")):
        m = by_target[target]
        opts = m["options"].split(",")
        print(target, m)
        assert m["fstype"] == "btrfs" and m["fsroot"] == f"/{subvol}", m
        assert m["source"].startswith(f"{root}["), m
        assert f"subvol=/{subvol}" in opts and "compress=zstd:1" in opts and "noatime" in opts, m
        # A subvolume's root directory has this inode number.
        assert machine.succeed(f"stat -c %i {target}").strip() == "256", target
    boot = by_target["/boot"]
    assert boot["fstype"] == "vfat" and boot["source"] == esp and "fmask=0077" in boot["options"], boot
    # /var is part of the root subvolume, not a mount of its own.
    assert "/var" not in by_target
