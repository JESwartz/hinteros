# A reinstall that keeps the data (`keepData`): the installer installs on an empty disk with no
# network, the box boots and gets marker files in /home, /srv and /var/lib/hinteros and a
# profile's permissions.json, its ESP is damaged, and a `keepData` plan repairs it in place. The
# plan gives the admin user and SSH on, but no hostname and no password: the box keeps its own
# hostname and password (sudo takes the old one). The box boots: the markers, permissions.json
# and everything in /var/lib/hinteros are as they were, the ESP has its volume id again,
# SSH is on, and a new generation exists (state.json changed on the box first: from the same
# installer and the same state the system is the same, and Nix makes no new generation).
# Also what is refused, with the disk untouched, and `hinteros-install --list-disks` on the way.
{ self, pkgs }:
let
  # As in install-offline: the test driver's backdoor and a session that runs in a VM.
  extraModule = pkgs.writeText "extra-module.nix" ''
    { modulesPath, lib, ... }:
    {
      imports = [
        (modulesPath + "/testing/test-instrumentation.nix")
        (modulesPath + "/profiles/qemu-guest.nix")
      ];
      boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
      hinteros.session = {
        compositor = "cage";
        environment = {
          WLR_RENDERER = "pixman";
          WLR_NO_HARDWARE_CURSORS = "1";
          GDK_BACKEND = "wayland";
          LIBGL_ALWAYS_SOFTWARE = "1";
          GALLIUM_DRIVER = "llvmpipe";
        };
      };
      users.users.root.hashedPasswordFile = lib.mkForce null;
    }
  '';

  plan = pkgs.writeText "plan.json" (
    builtins.toJSON {
      disk = "/dev/vdc";
      hostname = "livingroom";
      admin = {
        user = "james";
        password = "hunter22";
      };
      channel = "stable";
      apps = [ "youtube" ];
    }
  );
  keepPlan = pkgs.writeText "keep-plan.json" (
    builtins.toJSON {
      disk = "/dev/vdc";
      keepData = true;
      admin.user = "james";
      ssh.enable = true;
      channel = "stable";
      network = "offline";
    }
  );

  # What the box holds that a reinstall must leave as it is.
  kept = [
    "/home/hinteros-p1/marker"
    "/home/hinteros-p1/.local/state/hinteros/permissions.json"
    "/srv/media/marker"
    "/var/lib/hinteros/marker"
    "/var/lib/hinteros/profiles.json"
    "/var/lib/hinteros/admin-password-hash"
    "/var/lib/hinteros/starter.json"
    "/var/lib/hinteros/terms-accepted.json"
    "/etc/machine-id"
  ];
  sums = "sha256sum ${pkgs.lib.concatStringsSep " " kept}; stat -c '%n %a %U %G' /var/lib/hinteros; readlink -f /nix/var/nix/profiles/hinteros/starter";
in
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-install-keep-data";
  meta.timeout = 5400;

  nodes = {
    installer =
      { pkgs, ... }:
      {
        imports = [
          (import ./install/installer-node.nix {
            inherit self pkgs;
            isolatedStore = true;
          })
        ];
        system.extraDependencies = [ pkgs.cage ];
      };

    # The installed disk, booted via UEFI. As in install-offline.
    target = {
      virtualisation = {
        diskImage = "./empty0.qcow2";
        useBootLoader = true;
        useEFIBoot = true;
        useDefaultFilesystems = false;
        efi.keepVariables = false;
        memorySize = 3072;
        cores = 2;
        fileSystems."/" = {
          device = "/dev/disk/by-label/this-is-not-real-and-will-never-be-used";
          fsType = "ext4";
        };
      };
    };
  };

  testScript = ''
    import json
    import shlex

    ${builtins.readFile ./install/system-steps.py}
    ${builtins.readFile ./install/copy-plan.py}
    ${builtins.readFile ./install/disk.py}

    def run_install(path, env=""):
        installer.succeed(
            f"({env} HINTEROS_INSTALL_ALLOW_BIOS=1 "
            f"timeout 1500 hinteros-install --plan {path} >/tmp/install.out 2>/tmp/install.stderr; "
            "echo $? >/tmp/install.rc) </dev/null >/dev/null 2>&1 &"
        )
        installer.sleep(5)
        for _ in range(60):
            if installer.execute("pgrep -f '[l]ibexec/hinteros-install'")[0] != 0:
                break
            installer.sleep(30)
            print(installer.execute("tail -n 2 /tmp/install.out")[1])
        lines = [json.loads(l) for l in installer.succeed("cat /tmp/install.out").splitlines() if l.strip()]
        for l in lines:
            print(l)
        rc = int(installer.succeed("cat /tmp/install.rc").strip())
        if rc != 0:
            print("INSTALL-LOG:", installer.execute("tail -n 40 /var/log/hinteros-install.log; dmesg | tail -n 15")[1])
        return rc, lines

    def disk_listed():
        disks = json.loads(installer.succeed("hinteros-install --list-disks"))["blockdevices"]
        return {d["name"]: d for d in disks}["vdc"]

    def superblock():
        return installer.succeed("btrfs inspect-internal dump-super /dev/disk/by-partlabel/hinteros-root | grep -E '^(generation|uuid)'")

    def refused(code):
        copy_plan("${keepPlan}", "/tmp/keep.json")
        before = superblock()
        status, out = installer.execute(
            "HINTEROS_INSTALL_ALLOW_BIOS=1 hinteros-install --plan /tmp/keep.json 2>/dev/null"
        )
        lines = [json.loads(l) for l in out.splitlines() if l.strip()]
        print(code, status, lines[-1])
        assert status == 2 and lines[-1]["level"] == "error" and lines[-1]["code"] == code, lines
        assert not any(l["stage"] in ("mount", "partition", "packages", "build", "bootloader", "done") for l in lines), lines
        assert superblock() == before
        installer.fail("mountpoint -q /mnt")

    def edit_state(jq):
        mount_target()
        installer.succeed(f"cp /mnt/etc/hinteros/state.json /tmp/state.json && jq {shlex.quote(jq)} /tmp/state.json > /mnt/etc/hinteros/state.json")
        installer.succeed("sync && umount -R /mnt")

    def restore_state():
        mount_target()
        installer.succeed("cp /tmp/state.json /mnt/etc/hinteros/state.json && sync && umount -R /mnt")

    installer.start()
    installer.wait_for_unit("multi-user.target")
    installer.succeed("udevadm settle")
    installer.succeed("test \"$(ls /sys/class/net)\" = lo")

    with subtest("a disk without an install: nothing to keep, nothing listed"):
        copy_plan("${keepPlan}", "/tmp/keep.json")
        status, out = installer.execute("HINTEROS_INSTALL_ALLOW_BIOS=1 hinteros-install --plan /tmp/keep.json 2>/dev/null")
        lines = [json.loads(l) for l in out.splitlines() if l.strip()]
        assert status == 2 and lines[-1]["code"] == "keep-no-install", lines
        assert disk_listed()["existing"] is None
        installer.succeed("test -z \"$(lsblk -nro NAME /dev/vdc | tail -n +2)\"")

    with subtest("the first install"):
        copy_plan("${plan}", "/tmp/plan.json")
        installer.copy_from_host("${extraModule}", "/tmp/extra-module.nix")
        rc, lines = run_install("/tmp/plan.json", "HINTEROS_INSTALL_EXTRA_MODULE=/tmp/extra-module.nix")
        assert rc == 0 and lines[-1]["stage"] == "done", lines[-3:]
        print("BUILT:", installer.succeed(
            "grep -ao \"building '/nix/store/[^']*\\.drv\" /var/log/hinteros-install.log | sed 's|.*/[a-z0-9]\\{32\\}-||; s|\\.drv$||' | sort -u"
        ).split())

    with subtest("--list-disks: the install, read-only"):
        before = superblock()
        existing = disk_listed()["existing"]
        print(existing)
        assert existing == {"version": "${self.nixosConfigurations.installer.config.hinteros.release.version}", "channel": "stable", "profiles": 1, "hostname": "livingroom", "admin": "james", "ssh": False, "schemaOk": True}, existing
        assert superblock() == before
        installer.fail("findmnt -rn | grep -q vdc")

    with subtest("refused: an install this installer cannot keep"):
        edit_state(".schemaVersion = 3")
        refused("keep-schema-newer")
        assert disk_listed()["existing"]["schemaOk"] is False
        restore_state()
        edit_state(".disk.layout = \"gpt-esp-ext4\"")
        refused("keep-layout")
        restore_state()
        edit_state(".disk.rootUuid = \"11111111-2222-3333-4444-555555555555\"")
        refused("keep-uuid-mismatch")
        restore_state()
        mount_target()
        installer.succeed("echo broken > /mnt/etc/hinteros/state.json && sync && umount -R /mnt")
        refused("keep-state-unreadable")
        assert disk_listed()["existing"] is None
        restore_state()
        assert disk_listed()["existing"]["schemaOk"] is True

    installer.succeed("sync")
    installer.shutdown()

    target.state_dir = installer.state_dir
    target.start()
    target.wait_for_unit("multi-user.target")
    target.wait_for_unit("greetd.service")
    target.wait_until_succeeds("pgrep -u hinteros-p1 -f hinteros-launcher")

    with subtest("the box, as it was left"):
        state = json.loads(target.succeed("cat /etc/hinteros/state.json"))
        check_layout(target, state)
        target.succeed(
            "echo home > /home/hinteros-p1/marker",
            # A profile's app permission choice (an opt-out), as apps.set_permission writes it.
            "mkdir -p /home/hinteros-p1/.local/state/hinteros && echo '{\"version\":1,\"denied\":{\"youtube\":[\"mic\"]}}' > /home/hinteros-p1/.local/state/hinteros/permissions.json && chown -R hinteros-p1: /home/hinteros-p1/.local",
            "mkdir -p /srv/media && echo srv > /srv/media/marker",
            "echo var > /var/lib/hinteros/marker",
            # A profile file, if first boot has not made one.
            "test -e /var/lib/hinteros/profiles.json || echo '{\"version\":1,\"next\":1,\"profiles\":{}}' > /var/lib/hinteros/profiles.json",
        )
        # A settings change whose rebuild never happened: the reinstall applies it.
        new_state = json.loads(json.dumps(state))
        new_state["settings"]["hostname"] = "den"
        target.succeed(f"printf %s {shlex.quote(json.dumps(new_state))} > /etc/hinteros/state.json")
        was = target.succeed("${sums}")
        generations = len(target.succeed("ls -d /nix/var/nix/profiles/system-*-link").split())
        target.succeed("sync")
    target.shutdown()

    installer.start()
    installer.wait_for_unit("multi-user.target")
    installer.succeed("udevadm settle")

    with subtest("reinstall with keepData on a damaged ESP"):
        installer.succeed("dd if=/dev/zero of=/dev/disk/by-partlabel/hinteros-esp bs=1M count=16 && sync && udevadm settle")
        installer.succeed("test -z \"$(blkid -p -o value -s TYPE /dev/disk/by-partlabel/hinteros-esp)\"")
        assert disk_listed()["existing"]["schemaOk"] is True
        copy_plan("${keepPlan}", "/tmp/keep.json")
        rc, lines = run_install("/tmp/keep.json")
        assert rc == 0 and lines[-1]["stage"] == "done" and lines[-1]["percent"] == 100, lines[-3:]
        assert all(l["level"] != "error" for l in lines), lines
        pct = [l["percent"] for l in lines]
        assert pct == sorted(pct), pct
        stages = []
        for l in lines:
            if l["stage"] not in stages:
                stages.append(l["stage"])
        assert stages == ["validate", "mount", "facter", "config", "packages", "build", "bootloader", "snapshot", "finalize", "done"], stages
        assert lines[-1]["failed_apps"] == [], lines[-1]
        check_system_steps(lines, "copy")
        print("BUILT:", installer.succeed(
            "tac /var/log/hinteros-install.log | sed '/hinteros-install/q' | grep -ao \"building '/nix/store/[^']*\\.drv\" | sed 's|.*/[a-z0-9]\\{32\\}-||; s|\\.drv$||' | sort -u"
        ).split())

    installer.succeed("sync")
    installer.shutdown()

    target.start()
    target.wait_for_unit("multi-user.target")
    target.wait_for_unit("greetd.service")
    target.wait_until_succeeds("pgrep -u hinteros-p1 -f hinteros-launcher")

    with subtest("the box boots, with everything it had"):
        now = target.succeed("${sums}")
        assert now == was, (was, now)
        assert target.succeed("cat /home/hinteros-p1/marker /srv/media/marker /var/lib/hinteros/marker").split() == ["home", "srv", "var"]
        assert target.succeed("stat -c '%U' /home/hinteros-p1").strip() == "hinteros-p1"
        assert target.succeed("hostname").strip() == "den"
        state = json.loads(target.succeed("cat /etc/hinteros/state.json"))
        new_state["settings"]["ssh"] = {"enable": True}
        assert state == new_state, (state, new_state)
        target.wait_for_unit("sshd.service")
        check_layout(target, state)
        for f in ("flake.nix", "flake.lock", "state.json"):
            target.succeed(f"cmp /run/current-system/hinteros/{f} /etc/hinteros/{f}")
        # The kept extra.nix: the test's own backdoor is why this script reaches the box at all.
        target.succeed("test -e /etc/hinteros/extra.nix -a -e /etc/hinteros/extra-module.nix")
        assert target.succeed("getent shadow james").split(":")[1].startswith("$6$")
        # The kept password still logs in (the plan gave none).
        target.succeed("printf 'hunter22\\n' | runuser -u james -- sudo -S -k true")
        target.fail("printf 'wrong\\n' | runuser -u james -- sudo -S -k true")

    with subtest("a new generation, and the old ones still boot"):
        assert len(target.succeed("ls -d /nix/var/nix/profiles/system-*-link").split()) == generations + 1
        entries = target.succeed("ls /boot/loader/entries").split()
        print(entries)
        assert len(entries) == generations + 1, entries
        target.succeed("test -e /boot/EFI/BOOT/BOOTX64.EFI")

    target.shutdown()
  '';
}
