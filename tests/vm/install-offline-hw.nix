# An offline install must never build: it installs the generic system that is prebuilt on the
# installer. The regression this guards: on real hardware nixos-facter's report changes the
# system (bare-metal firmware and microcode, the initrd's modules, ...), so installing "the
# machine's" system needed builds (even bash) that the installer's store cannot provide; the VM
# tests never saw it because a VM's report changes nothing. Here the installer gets the report of
# a typical Intel mini PC (fixtures/facter-intel-minipc.json: bare metal, Intel CPU, i915, NVMe,
# Realtek and Intel NICs) through the HINTEROS_INSTALL_FACTER hook and installs the default apps
# with a real hostname and admin, with no network:
#   - the install succeeds and builds only small configuration derivations (names checked against
#     what the installer's offline closure promises), none of the heavy kind (bash, kernel,
#     firmware or microcode packages; the initrd and /etc assemblies are small);
#   - the report is written next to a `facter.deferred` marker, so the flake does not apply it;
#   - control: with the marker removed the flake reads the report (a different system)
#     (`nix build --dry-run`), so the marker is what keeps it out.
# The installed disk is not booted here (install-offline does that, with another hook module).
{ self, pkgs }:
let
  fixture = ./fixtures/facter-intel-minipc.json;
  facterStub = pkgs.writeShellScript "facter-stub" ''
    [ "$1" = -o ] && cp ${fixture} "$2"
  '';
  plan = pkgs.writeText "plan.json" (
    builtins.toJSON {
      disk = "/dev/vdc";
      hostname = "mini-pc-7";
      admin = {
        user = "james";
        password = "hunter22";
      };
      ssh.enable = true;
      channel = "stable";
      base = "unstable";
      apps =
        (import ../../nixos/lib/app-ids.nix self.nixosConfigurations.vm.config.hinteros.catalog.entries)
        .onIso;
      acceptedTerms = { };
    }
  );
in
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-install-offline-hw";
  meta.timeout = 5400;

  nodes.installer =
    { pkgs, ... }:
    {
      imports = [
        (import ./install/installer-node.nix {
          inherit self pkgs;
          isolatedStore = true;
        })
      ];
    };

  testScript = ''
    import json

    ${builtins.readFile ./install/copy-plan.py}
    installer.start()
    installer.wait_for_unit("multi-user.target")
    installer.succeed("udevadm settle")
    installer.fail("curl -sS --max-time 3 https://cache.nixos.org/nix-cache-info")
    # Nothing but lo: this is what turns nix's substitution off on a box without a network.
    installer.succeed("test \"$(ls /sys/class/net)\" = lo")
    copy_plan("${plan}", "/tmp/plan.json")

    with subtest("the install with an Intel mini PC's hardware report succeeds"):
        rc, _ = installer.execute(
            "HINTEROS_INSTALL_ALLOW_BIOS=1 HINTEROS_INSTALL_FACTER=${facterStub} "
            "timeout 3000 hinteros-install --plan /tmp/plan.json >/tmp/install.out 2>/tmp/install.stderr"
        )
        out = installer.succeed("cat /tmp/install.out")
        lines = [json.loads(l) for l in out.splitlines() if l.strip()]
        print(lines[-3:])
        if rc != 0:
            print(installer.execute("tail -n 60 /tmp/install.stderr")[1])
        assert rc == 0 and lines[-1]["stage"] == "done", (rc, lines[-3:])
        assert any(l["stage"] == "facter" and "first rebuild" in l["message"] for l in lines), lines

    with subtest("it built only small configuration derivations"):
        built = installer.succeed(
            "grep -ao \"building '/nix/store/[^']*\\.drv\" /var/log/hinteros-install.log | sed 's|.*/[a-z0-9]\\{32\\}-||; s|\\.drv$||' | sort -u"
        ).split()
        print("built:", built)
        # Package builds (a name with a version and no -env/-modules/-bin suffix), as opposed to the
        # file and environment assemblies (etc-*, unit-*, initrd-*, buildEnvs) that any install builds.
        import re
        heavy = [b for b in built if re.match(r"^(bash|glibc|gcc|binutils|coreutils|perl|python3|systemd|linux|linux-firmware|microcode-[a-z]+|wireless-regdb|mesa|nix|openssh|util-linux|kmod|intel-[a-z-]+|libva[a-z-]*)-[0-9][0-9a-z._]*$", b)]
        assert not heavy, heavy

    with subtest("the report is there, deferred, and not applied"):
        installer.succeed("mkdir -p /mnt && mount /dev/disk/by-partlabel/hinteros-root /mnt")
        installer.succeed("cmp ${fixture} /mnt/etc/hinteros/facter.json")
        installer.succeed("test -e /mnt/etc/hinteros/facter.deferred")
        installer.succeed("grep -q 'facter.deferred' /mnt/etc/hinteros/flake.nix")
        # The installed generation is the generic system: no microcode in its initrd/firmware setup.
        sysdir = installer.succeed("readlink -f /mnt/nix/var/nix/profiles/system").strip()
        installer.fail(f"test -e /mnt{sysdir}/kernel-modules/lib/firmware/intel-ucode")
        installer.succeed("test -d /mnt/var/lib/hinteros && umount -R /mnt")

    with subtest("control: the flake does read the report once the marker is gone"):
        installer.succeed("mkdir -p /mnt && mount /dev/disk/by-partlabel/hinteros-root /mnt")
        installer.succeed("rm -rf /tmp/cfg && cp -r /mnt/etc/hinteros /tmp/cfg && umount -R /mnt")
        ref = "path:/tmp/cfg#nixosConfigurations.hinteros.config.system.build.toplevel"
        opts = "--extra-experimental-features 'nix-command flakes' --no-update-lock-file --option substituters 'auto?trusted=1' --dry-run"
        with_marker = installer.succeed(f"nix build {opts} {ref} 2>&1")
        installer.succeed("rm /tmp/cfg/facter.deferred")
        applied = installer.succeed(f"nix build {opts} {ref} 2>&1")
        print(applied[-3000:])
        assert "will be built" in applied, applied[-2000:]
        assert any(w in applied for w in ("firmware", "microcode", "initrd")), applied[-2000:]
        assert applied != with_marker
  '';
}
