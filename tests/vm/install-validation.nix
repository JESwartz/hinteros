# hinteros-install refuses bad plans and unsuitable machines before touching the disk: missing
# admin password, an app that needs a network while offline, a disk that does not exist, is in
# use, is the system disk or is too small, a BIOS-booted machine, malformed fields, a `rev` that
# is malformed or needs a network (the installer's own revision validates offline), a plan whose
# diskSeq is missing or not the disk's, and a disk replaced (unplugged and plugged in again, so it
# gets a new disk sequence number under the same name) after the plan was made or after the plan
# was checked, just before erasing. Every refusal exits 2 with an error line; a marker file system
# on the target disk survives them all.
# Also `--info` (the installer's revision, version and channel; offline, no root).
{ self, pkgs }:
let
  plan =
    extra:
    pkgs.writeText "plan.json" (
      builtins.toJSON (
        {
          disk = "/dev/vdb";
          hostname = "livingroom";
          admin = {
            user = "james";
            password = "hunter2";
          };
          ssh.enable = true;
          channel = "stable";
          apps = [
            "youtube"
            "firefox"
          ];
        }
        // extra
      )
    );

  # As nixos/installer sets hinteros.installer.isoRev.
  isoRev = self.rev or "0000000000000000000000000000000000000000";

  cases = {
    ok = plan { };
    no-password = plan {
      admin.user = "james";
    };
    empty-password = plan {
      admin = {
        user = "james";
        password = "";
      };
    };
    bad-hash = plan {
      admin = {
        user = "james";
        hashedPassword = "not a hash";
      };
    };
    no-admin = plan { admin = null; };
    steam-offline = plan {
      apps = [
        "youtube"
        "steam"
      ];
      acceptedTerms.steam = "2026-09-10";
    };
    steam-no-terms = plan { apps = [ "steam" ]; };
    steam-old-terms = plan {
      apps = [ "steam" ];
      acceptedTerms.steam = "2020-01-01";
    };
    steam-terms = plan {
      apps = [ "steam" ];
      acceptedTerms.steam = "2026-09-10";
    };
    terms-invalid = plan { acceptedTerms.steam = 5; };
    steam-forced-offline = plan {
      network = "offline";
      apps = [ "steam" ];
      acceptedTerms.steam = "2026-09-10";
    };
    forced-online = plan { network = "online"; };
    missing-disk = plan { disk = "/dev/vdz"; };
    system-disk = plan { disk = "/dev/vda"; };
    small-disk = plan { disk = "/dev/vdc"; };
    bad-hostname = plan { hostname = "Living Room"; };
    bad-user = plan {
      admin = {
        user = "root";
        password = "x1";
      };
    };
    unknown-app = plan {
      apps = [
        "youtube"
        "doom"
      ];
    };
    bad-channel = plan { channel = "nightly"; };
    unknown-field = plan { wallpaper = "blue"; };
    bad-rev = plan { rev = "HEAD"; };
    # The installer's own revision installs offline as without `rev`; another one needs a network.
    iso-rev = plan { rev = isoRev; };
    other-rev = plan { rev = "1111111111111111111111111111111111111111"; };
    in-use-disk = plan { };
    no-disk-seq = plan { diskSeq = null; };
    bad-disk-seq = plan { diskSeq = "2"; };
    wrong-disk-seq = plan { diskSeq = 9999; };
  };
in
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-install-validation";

  nodes.installer =
    { ... }:
    {
      imports = [ (import ./install/installer-node.nix { inherit self pkgs; }) ];
      # vdc: too small to install on (the node adds vdb, the 20 GiB target).
      virtualisation.emptyDiskImages = [ 2048 ];
    };

  testScript =
    { nodes, ... }:
    ''
      import json

      ${builtins.readFile ./install/copy-plan.py}
      CASES = {${
        builtins.concatStringsSep ", " (pkgs.lib.mapAttrsToList (n: v: ''"${n}": "${v}"'') cases)
      }}

      installer.start()
      installer.wait_for_unit("multi-user.target")
      installer.succeed("udevadm settle")
      copy_plan(CASES["ok"], "/tmp/ok.json")

      # A marker on the target disk: any partitioning or formatting would destroy it.
      installer.succeed("mkfs.ext4 -q -L marker /dev/vdb")

      def run(name, extra_env="", seq=None, validate_only=True):
          copy_plan(CASES[name], f"/tmp/{name}.json", seq)
          flag = " --validate-only" if validate_only else ""
          status, out = installer.execute(
              f"{extra_env} hinteros-install --plan /tmp/{name}.json{flag} 2>/tmp/{name}.err"
          )
          lines = [json.loads(l) for l in out.splitlines() if l.strip()]
          return status, lines

      def refused(name, code, extra_env="HINTEROS_INSTALL_ALLOW_BIOS=1", seq=None, validate_only=True):
          status, lines = run(name, extra_env, seq, validate_only)
          errors = [l for l in lines if l["level"] == "error"]
          print(name, status, errors)
          assert status == 2, (name, status, lines)
          assert code in [e["code"] for e in errors], (name, code, errors)
          assert lines[-1]["level"] == "error", lines[-1]
          assert not any(l["stage"] in ("partition", "packages", "build", "bootloader", "done") for l in lines), lines
          # Untouched: the marker file system, no partitions, no mounts, no device config.
          assert 'LABEL="marker"' in installer.succeed("blkid /dev/vdb"), name
          installer.succeed("test -z \"$(lsblk -nro NAME /dev/vdb | tail -n +2)\"")
          installer.fail("mountpoint -q /mnt")
          installer.fail("test -e /dev/hinteros-target")

      with subtest("a good plan validates (and only validates)"):
          status, lines = run("ok", "HINTEROS_INSTALL_ALLOW_BIOS=1")
          assert status == 0, lines
          assert lines[-1]["stage"] == "done" and lines[-1]["percent"] == 100, lines[-1]
          assert all(l["level"] != "error" for l in lines), lines
          assert [l["percent"] for l in lines] == sorted(l["percent"] for l in lines), lines
          assert 'LABEL="marker"' in installer.succeed("blkid /dev/vdb")

      with subtest("a BIOS-booted machine is refused"):
          refused("ok", "not-uefi", extra_env="")

      with subtest("admin password"):
          refused("no-password", "admin-password-missing")
          refused("empty-password", "admin-password-missing")
          refused("bad-hash", "admin-hash-invalid")
          refused("no-admin", "admin-missing")

      with subtest("apps that need a network"):
          refused("steam-offline", "app-needs-network")
          refused("steam-forced-offline", "app-needs-network")
          # Vendor terms: acceptance of exactly the catalog's version is required first.
          refused("steam-no-terms", "terms-not-accepted")
          refused("steam-old-terms", "terms-not-accepted")
          refused("terms-invalid", "terms-invalid")
          status, lines = run("steam-terms", "HINTEROS_INSTALL_ALLOW_BIOS=1")
          codes = [l.get("code") for l in lines if l["level"] == "error"]
          assert "terms-not-accepted" not in codes and "app-needs-network" in codes, lines
          refused("forced-online", "no-network")

      with subtest("the disk"):
          refused("missing-disk", "disk-not-found")
          refused("system-disk", "disk-in-use")
          refused("small-disk", "disk-too-small")
          installer.succeed("mkdir -p /tmp/target && mount /dev/vdb /tmp/target")
          refused("in-use-disk", "disk-in-use")
          installer.succeed("umount /tmp/target")

      with subtest("another disk with HinterOS partition labels is refused"):
          # The system finds its disks by partition label; a second disk with the same labels (an old
          # install, a USB stick) would be ambiguous, also for the partitioning script.
          installer.succeed("parted -s /dev/vdc mklabel gpt mkpart hinteros-root ext4 1MiB 100%")
          installer.succeed("udevadm settle")
          refused("ok", "other-hinteros-disk")
          installer.succeed("wipefs -a /dev/vdc")
          installer.succeed("udevadm settle")
          status, lines = run("ok", "HINTEROS_INSTALL_ALLOW_BIOS=1")
          assert status == 0, lines
          # Every line says which phase it is in; validation is the system stage.
          assert all(l.get("phase") == "system" for l in lines), lines
          assert lines[-1]["failed_apps"] == [], lines[-1]

      with subtest("malformed fields"):
          refused("bad-hostname", "hostname-invalid")
          refused("bad-user", "admin-user-reserved")
          refused("unknown-app", "app-unknown")
          refused("bad-channel", "channel-invalid")
          refused("unknown-field", "unknown-field")
          refused("bad-rev", "rev-invalid")

      with subtest("plan.rev: the installer's own revision, or a newer one (online only)"):
          status, lines = run("iso-rev", "HINTEROS_INSTALL_ALLOW_BIOS=1")
          assert status == 0 and lines[-1]["stage"] == "done", lines
          refused("other-rev", "rev-needs-network")

      with subtest("--info: what the installer carries, offline and without root"):
          out = installer.succeed("runuser -u nobody -- hinteros-install --info")
          lines = [l for l in out.splitlines() if l.strip()]
          assert len(lines) == 1, out
          assert json.loads(lines[0]) == {
              "iso": {"rev": "${nodes.installer.hinteros.installer.isoRev}", "version": "${nodes.installer.hinteros.release.version}"},
              "channel": "${nodes.installer.hinteros.installer.channel}",
          }, lines
          status, _ = installer.execute("hinteros-install --info --plan /tmp/ok.json 2>/dev/null")
          assert status == 2, status

      with subtest("the disk is the one the plan names: its disk sequence number"):
          refused("no-disk-seq", "disk-seq-invalid")
          refused("bad-disk-seq", "disk-seq-invalid")
          refused("wrong-disk-seq", "disk-changed")

          def seq():
              return int(installer.succeed("cat /sys/class/block/vdb/diskseq"))

          # Unplug the target and plug it in again: the same name (vdb), a new disk sequence number.
          # A virtio disk is a PCI device; removing it and rescanning the bus does this.
          REPLUG = (
              "d=$(readlink -f /sys/block/vdb/device/..) && echo 1 > $d/remove && udevadm settle && "
              "test ! -e /sys/block/vdb && echo 1 > /sys/bus/pci/rescan && udevadm settle && test -b /dev/vdb"
          )
          old = seq()
          installer.succeed(REPLUG)
          new = seq()
          assert new != old, (old, new)
          # The plan was made before: refused when it is checked.
          refused("ok", "disk-changed", seq=old)
          refused("ok", "disk-changed", seq=old, validate_only=False)
          status, lines = run("ok", "HINTEROS_INSTALL_ALLOW_BIOS=1", seq=new)
          assert status == 0, lines

          # Replaced after the plan was checked, just before erasing (a test hook runs then): the
          # install stops before it touches the disk.
          status, lines = run(
              "ok",
              f"HINTEROS_INSTALL_ALLOW_BIOS=1 HINTEROS_INSTALL_BEFORE_WIPE='{REPLUG}'",
              validate_only=False,
          )
          print("replaced before erasing", status, lines)
          assert status == 2, (status, lines)
          assert lines[-1]["level"] == "error" and lines[-1]["code"] == "disk-changed", lines[-1]
          assert any(l["stage"] == "validate" and l["percent"] == 8 for l in lines), lines
          assert not any(l["stage"] in ("partition", "packages", "build", "bootloader", "done") for l in lines), lines
          assert seq() != new
          assert 'LABEL="marker"' in installer.succeed("blkid /dev/vdb")
          installer.succeed("test -z \"$(lsblk -nro NAME /dev/vdb | tail -n +2)\"")
          installer.fail("mountpoint -q /mnt")
          installer.fail("test -e /dev/hinteros-target")

      with subtest("without --validate-only a refused plan still touches nothing"):
          copy_plan(CASES["no-password"], "/tmp/np.json")
          status, _ = installer.execute("HINTEROS_INSTALL_ALLOW_BIOS=1 hinteros-install --plan /tmp/np.json 2>/dev/null")
          assert status == 2, status
          assert 'LABEL="marker"' in installer.succeed("blkid /dev/vdb")
          installer.fail("mountpoint -q /mnt")
    '';
}
