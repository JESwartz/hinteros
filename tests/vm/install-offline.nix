# End-to-end offline install: the installer config boots in a VM with an empty second disk and
# NO network, `hinteros-install` installs apps youtube + firefox, ssh on and an admin account
# from a JSON plan, then the installed disk is booted (UEFI, systemd-boot) in a second VM step
# and checked: the session comes up, /etc/hinteros and its snapshot, sshd with the admin's
# password, no password for the session user or root, and the daemon's app list.
{
  self,
  pkgs,
  # Parameterisation: the installer gets this nixos-facter report through the HINTEROS_INSTALL_FACTER
  # hook (a real machine's report; a VM's own report changes nothing), and the test name.
  facterFixture ? null,
  name ? "hinteros-install-offline",
  # The plan's apps, the ones expected to fail in the apps stage (the rest must be installed), and
  # whether the apps stage is told it is online (HINTEROS_INSTALL_ONLINE_APPS: there is no network
  # here, so an online-only app cannot be downloaded).
  apps ? [
    "youtube"
    "firefox"
  ],
  failedApps ? [ ],
  onlineAppsHook ? false,
  # An earlier HinterOS install (labelled partitions, a file system with files) on the target
  # disk before the installer runs.
  staleTarget ? false,
}:
let
  hookEnv = pkgs.lib.optionalString onlineAppsHook "HINTEROS_INSTALL_ONLINE_APPS=1 ";
  installedApps = builtins.filter (a: !(builtins.elem a failedApps)) apps;
  withReport = facterFixture != null;
  facterStub = pkgs.writeShellScript "facter-stub" ''
    [ "$1" = -o ] && cp ${facterFixture} "$2"
  '';
  facterEnv = pkgs.lib.optionalString withReport "HINTEROS_INSTALL_FACTER=${facterStub} ";

  # The installed system also needs the test driver's backdoor, plus the same software-rendering
  # session settings as nixos/vm. Handed to the installer as its test hook
  # (HINTEROS_INSTALL_EXTRA_MODULE); everything else on the installed system is what the plan
  # produces.
  extraModule = pkgs.writeText "extra-module.nix" ''
    { modulesPath, lib, pkgs, ... }:
    {
      imports = [
        (modulesPath + "/testing/test-instrumentation.nix")
        (modulesPath + "/profiles/qemu-guest.nix")
      ];
      # The installer VM was not booted through UEFI, so it cannot touch EFI variables; the
      # fallback boot path (EFI/BOOT/BOOTX64.EFI) is what OVMF boots.
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
      # test-instrumentation gives root an empty password; the installed system must have the real one.
      users.users.root.hashedPasswordFile = lib.mkForce null;
      environment.systemPackages = [ pkgs.socat pkgs.sshpass ];
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
      ssh.enable = true;
      channel = "stable";
      base = "unstable";
      inherit apps;
      acceptedTerms = pkgs.lib.optionalAttrs (builtins.elem "steam" apps) { steam = "2026-09-10"; };
    }
  );
in
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  inherit name;
  # Installing takes a while even from a ready store.
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
        # What the test hook module adds to the installed system, so it is in the store.
        system.extraDependencies = [
          pkgs.socat
          pkgs.sshpass
          pkgs.cage
        ];
      };

    # The installed disk (the installer's second drive), booted via UEFI. Only the VM hardware
    # of this node matters; its NixOS config is never used.
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
    from datetime import timedelta

    ${builtins.readFile ./install/system-steps.py}
    installer.start()
    installer.wait_for_unit("multi-user.target")
    installer.succeed("udevadm settle")
    installer.succeed("test -b /dev/vdc")
    # No network: the installer must work from its own store.
    installer.fail("curl -sS --max-time 3 https://cache.nixos.org/nix-cache-info")
    # Nothing but lo: this is what turns nix's substitution off on a box without a network.
    installer.succeed("test \"$(ls /sys/class/net)\" = lo")

    installer.copy_from_host("${plan}", "/tmp/plan.json")
    installer.copy_from_host("${extraModule}", "/tmp/extra-module.nix")

    ${
      if staleTarget then
        ''
          with subtest("an old HinterOS install is on the target disk"):
              installer.succeed(
                  "parted -s /dev/vdc mklabel gpt mkpart hinteros-esp fat32 1MiB 1GiB set 1 esp on mkpart hinteros-root ext4 1GiB 100%",
                  "udevadm settle",
                  "mkfs.vfat -n HINTEROSESP /dev/vdc1",
                  "mkfs.ext4 -q -L oldroot /dev/vdc2",
                  "mkdir -p /tmp/old && mount /dev/vdc2 /tmp/old",
                  "mkdir -p /tmp/old/etc/hinteros /tmp/old/nix/store/stale-path",
                  "echo old-box > /tmp/old/etc/hostname; echo stale > /tmp/old/stale-marker",
                  "echo '{\"stale\": true}' > /tmp/old/etc/hinteros/state.json",
                  "umount /tmp/old",
              )
        ''
      else
        ""
    }

    with subtest("hinteros-install runs and reports progress"):
        installer.succeed(
            "(HINTEROS_INSTALL_ALLOW_BIOS=1 ${hookEnv}${facterEnv}HINTEROS_INSTALL_EXTRA_MODULE=/tmp/extra-module.nix "
            "timeout 1500 hinteros-install --plan /tmp/plan.json >/tmp/install.out 2>/tmp/install.stderr; "
            "echo $? >/tmp/install.rc) </dev/null >/dev/null 2>&1 &"
        )
        installer.sleep(5)
        # Watch it, so a stall shows where it is.
        for _ in range(60):
            if installer.execute("pgrep -f '[l]ibexec/hinteros-install'")[0] != 0:
                break
            installer.sleep(30)
            print(installer.execute("tail -n 3 /tmp/install.out; tail -n 2 /var/log/hinteros-install.log | cut -c1-300")[1])
        out = installer.succeed("cat /tmp/install.out")
        rc = int(installer.succeed("cat /tmp/install.rc").strip())
        status = 0 if rc == 0 and '"stage":"done"' in out.splitlines()[-1] else 1
        lines = [json.loads(l) for l in out.splitlines() if l.strip()]
        for l in lines:
            print(l)
        if status != 0:
            print(installer.execute("tail -n 80 /tmp/install.stderr")[1])
            print("FACTER-BEGIN"); print(installer.execute("cat /mnt/etc/hinteros/facter.json")[1]); print("FACTER-END")
        assert status == 0, (status, lines[-3:])
        assert all(l["level"] != "error" for l in lines), lines
        assert lines[-1]["stage"] == "done" and lines[-1]["percent"] == 100, lines[-1]
        pct = [l["percent"] for l in lines]
        assert pct == sorted(pct), pct
        stages = []
        for l in lines:
            if l["stage"] not in stages:
                stages.append(l["stage"])
        assert stages == ["validate", "partition", "facter", "config", "packages", "build", "bootloader", "snapshot", ${
          if apps != [ ] then ''"apps", '' else ""
        }"finalize", "done"], stages
        # Two phases: up to the snapshot is the system stage, then the apps stage.
        assert all(l["phase"] in ("system", "apps") for l in lines), lines
        assert all(l["phase"] == "system" for l in lines if l["stage"] in ("validate", "partition", "facter", "config", "packages", "build", "bootloader", "snapshot")), lines
        # The system stage in its three steps, with their own counts (offline: copied from the installer).
        check_system_steps(lines, "copy")
        assert not any("download" in l["message"].lower() for l in lines if l["stage"] == "packages"), lines
        ${
          if apps != [ ] then
            ''assert any(l["phase"] == "apps" and l["stage"] == "apps" for l in lines), lines''
          else
            "pass"
        }
        expected_failed = json.loads('${builtins.toJSON failedApps}')
        assert lines[-1]["failed_apps"] == expected_failed, lines[-1]
        warned = [l["app"] for l in lines if l.get("code") == "app-failed"]
        assert warned == expected_failed, (warned, lines)
        assert all(l["level"] == "warn" and l["phase"] == "apps" and l.get("message") for l in lines if l.get("code") == "app-failed"), lines
        # A failed build leaves its nix error messages and build log in the install log.
        ${
          if failedApps != [ ] then
            ''assert "=== nix error messages" in installer.succeed("cat /var/log/hinteros-install.log"), "no failure log"''
          else
            "pass"
        }
        assert any("Offline install" in l["message"] for l in lines), lines

    ${
      if withReport then
        ''
          with subtest("the real hardware report: no package built, report written and deferred"):
              import re
              built = installer.succeed(
                  "grep -ao \"building '/nix/store/[^']*\\.drv\" /var/log/hinteros-install.log | sed 's|.*/[a-z0-9]\\{32\\}-||; s|\\.drv$||' | sort -u"
              ).split()
              print("built during the install:", built)
              # Package builds, as opposed to the small file and environment assemblies any install builds.
              heavy = [b for b in built if re.match(r"^(bash|glibc|gcc|binutils|coreutils|perl|python3|systemd|linux|linux-firmware|microcode-[a-z]+|wireless-regdb|mesa|nix|openssh|util-linux|kmod|intel-[a-z-]+|libva[a-z-]*|firefox[a-z-]*|hinteros-[a-z-]+)-[0-9][0-9a-z._]*$", b)]
              assert not heavy, heavy
              installer.succeed("mountpoint -q /mnt || mount /dev/disk/by-partlabel/hinteros-root /mnt")
              installer.succeed("cmp ${facterFixture} /mnt/etc/hinteros/facter.json")
              installer.succeed("test -e /mnt/etc/hinteros/facter.deferred")
              installer.succeed("rm -rf /tmp/cfg && cp -r /mnt/etc/hinteros /tmp/cfg && umount -R /mnt")

          with subtest("control: what the report would build (the first online update)"):
              ref = "path:/tmp/cfg#nixosConfigurations.hinteros.config.system.build.toplevel"
              opts = "--extra-experimental-features 'nix-command flakes' --no-update-lock-file --option substituters 'auto?trusted=1' --dry-run"
              def names(out, header):
                  # The derivation names listed under "<n> derivations will be built:" / "paths will be fetched".
                  sec = out.split(header, 1)[1] if header in out else ""
                  res = []
                  for l in sec.splitlines()[1:]:
                      l = l.strip()
                      if not l.startswith("/nix/store/"):
                          break
                      res.append(l.removeprefix("/nix/store/").removesuffix(".drv"))
                  return res
              with_marker = installer.succeed(f"nix build {opts} {ref} 2>&1")
              installer.succeed("rm /tmp/cfg/facter.deferred")
              applied = installer.succeed(f"nix build {opts} {ref} 2>&1")
              b0 = names(with_marker, "will be built")
              b1 = names(applied, "will be built")
              extra = sorted(set(b1) - set(b0))
              print("M900-CONTROL: derivations that differ or are new once the report is applied (marker removed):")
              for n in extra:
                  print("M900-CONTROL:   ", n[33:])
              print("M900-CONTROL: not built with the marker but in the generic system's closure:", sorted(set(b0))[:40])
              assert applied != with_marker
              # NetworkManager owns networking: facter must not add dhcpcd or per-interface units.
              dhcp = [n for n in b1 + extra if re.search(r"dhcpcd|eno1|network-link|network-addresses", n)]
              assert not dhcp, dhcp
              assert extra, applied[-2000:]
        ''
      else
        ""
    }

    installer.succeed("sync")
    installer.shutdown()

    # The same disk, booted on its own (UEFI).
    target.state_dir = installer.state_dir
    target.start()
    target.wait_for_unit("multi-user.target")

    with subtest("the session comes up"):
        target.wait_for_unit("greetd.service")
        target.wait_until_succeeds("loginctl list-sessions --no-legend | grep -w hinteros")
        target.wait_until_succeeds("pgrep -u hinteros -f '/bin/cage '")
        target.wait_until_succeeds("pgrep -u hinteros -f hinteros-launcher")
        target.wait_for_unit("hinteros-system.service")
        target.sleep(duration=timedelta(seconds=5))
        target.succeed("pgrep -u hinteros -f hinteros-launcher")
        target.screenshot("installed-session")

    ${
      if staleTarget then
        ''
          with subtest("nothing of the old install is left"):
              target.fail("test -e /stale-marker")
              target.fail("test -e /nix/store/stale-path")
              assert target.succeed("hostname").strip() == "livingroom"
        ''
      else
        ""
    }
    with subtest("accepted terms are recorded (none for these apps)"):
        assert target.succeed("stat -c '%a %U' /var/lib/hinteros/terms-accepted.json").strip() == "600 root"
        assert json.loads(target.succeed("cat /var/lib/hinteros/terms-accepted.json")) == {}

    with subtest("/etc/hinteros and its snapshot"):
        files = target.succeed("ls /etc/hinteros").split()
        for f in ("flake.nix", "flake.lock", "state.json", "facter.json", "facter.deferred"):
            assert f in files, files
        ${
          if withReport then
            ''target.succeed("test \"$(sha256sum < /etc/hinteros/facter.json | cut -d' ' -f1)\" = ${builtins.hashFile "sha256" facterFixture}")''
          else
            "pass"
        }
        state = json.loads(target.succeed("cat /etc/hinteros/state.json"))
        # Schema 2: the spare p1 and no apps (the picks are the starter set, below).
        assert state["schemaVersion"] == 2 and "apps" not in state, state
        assert state["profiles"] == [{"id": "p1", "user": "hinteros"}], state
        assert state["services"] == [] and state["settings"]["guest"] == {"enable": True}, state
        # Offline: only the box features of apps on the medium (none; not Steam's graphics32).
        assert state["requirements"] == [], state
        assert state["settings"]["ssh"]["enable"] is True, state
        assert state["settings"]["admin"] == {"user": "james"}, state
        assert state["settings"]["hostname"] == "livingroom", state
        assert state["disk"] == {"layout": "gpt-esp-ext4"}, state
        assert "password" not in json.dumps(state).lower(), state
        for f in ("flake.nix", "flake.lock", "state.json"):
            target.succeed(f"cmp /run/current-system/hinteros/{f} /etc/hinteros/{f}")
        target.succeed("systemctl is-active hinteros-config-sync.service")
        assert target.succeed("hostname").strip() == "livingroom"
        # The flake: the channel ref and the repo; hinteros is pinned to the ISO's revision.
        flake = target.succeed("cat /etc/hinteros/flake.nix")
        assert 'git+https://justsomeshed.com/JSwartz/HinterOS/hinteros.git?ref=stable' in flake, flake
        # The input line is exactly what channels.json says (channel.set rewrites that one string).
        channels = json.loads(target.succeed("cat /run/current-system/sw/share/hinteros/update/channels.json"))
        assert f'inputs.hinteros.url = "git+{channels["repo"]}?ref={channels["branches"]["stable"]}";' in flake, (flake, channels)
        assert json.loads(target.succeed("cat /run/current-system/sw/share/hinteros/release.json"))["dev"] is False
        lock = json.loads(target.succeed("cat /etc/hinteros/flake.lock"))
        node = lock["nodes"]["hinteros"]
        assert node["locked"]["narHash"] == "${self.narHash}", node
        assert node["original"]["ref"] == "stable", node
        assert lock["nodes"]["root"]["inputs"] == {"hinteros": "hinteros"}, lock["nodes"]["root"]
        assert target.succeed("stat -c '%a %U' /etc/hinteros/state.json").strip() == "644 root"
        # Files of the disk layout: ESP and root by partition label.
        target.succeed("test -e /dev/disk/by-partlabel/hinteros-esp && test -e /dev/disk/by-partlabel/hinteros-root")
        target.succeed("findmnt -no FSTYPE / | grep -qx ext4")
        target.succeed("findmnt -no FSTYPE /boot | grep -qx vfat")

    with subtest("the privileged service answers (system API 0.8) and knows its channel"):
        hello = {"jsonrpc": "2.0", "id": 0, "method": "hello",
                 "params": {"api_version": "0.8", "client": {"name": "install-test", "version": "0"}}}
        info = {"jsonrpc": "2.0", "id": 1, "method": "system.info", "params": {}}
        payload = "".join(json.dumps(m) + "\n" for m in (hello, info))
        cmd = f"(printf %s {shlex.quote(payload)}; sleep 2) | socat -t2 - UNIX-CONNECT:/run/hinteros/system.sock"
        out = target.succeed(f"runuser -u hinteros -- sh -c {shlex.quote(cmd)}")
        res = next(json.loads(l) for l in out.splitlines() if '"id":1' in l.replace(" ", ""))
        print(res)
        assert res["result"]["channel"] == "stable" and res["result"]["dev"] is False, res

    with subtest("accounts: admin with a password, the session user and root without"):
        assert target.succeed("passwd -S hinteros").split()[1] == "L", "session user has a password"
        assert target.succeed("passwd -S root").split()[1] == "L", "root has a password"
        assert target.succeed("getent shadow james").split(":")[1].startswith("$6$")
        assert target.succeed("stat -c '%a %U' /var/lib/hinteros/admin-password-hash").strip() == "600 root"
        target.succeed("test \"$(id -nG james | tr ' ' '\\n' | grep -cx wheel)\" = 1")
        target.fail("id -nG hinteros | tr ' ' '\\n' | grep -qx wheel")
        target.fail("runuser -u hinteros -- sudo -n true")
        target.succeed("printf 'hunter22\\n' | runuser -u james -- sudo -S -k true")
        target.fail("printf 'wrong\\n' | runuser -u james -- sudo -S -k true")
        # The hash is not in the config the generation embeds.
        h = target.succeed("cat /var/lib/hinteros/admin-password-hash").strip()
        target.fail(f"grep -rFq {shlex.quote(h)} /etc/hinteros /run/current-system/hinteros /etc/static")

    with subtest("sshd: password login for the admin only"):
        target.wait_for_unit("sshd.service")
        target.succeed("ss -tln | grep -q ':22 '")
        opts = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=6"
        def pw(user, password="hunter22", cmd="true"):
            return f"sshpass -p {password} ssh {opts} {user}@localhost {cmd}"
        target.succeed(pw("james", cmd="id -un"))
        target.fail(pw("james", "wrong"))
        target.fail(pw("hinteros"))
        target.fail(pw("root"))

    with subtest("the starter set: the installed apps, as the starter env"):
        installed = json.loads('${builtins.toJSON installedApps}')
        starter = json.loads(target.succeed("cat /var/lib/hinteros/starter.json"))
        assert starter["version"] == 1 and starter["by"] == "installer", starter
        assert sorted(starter["ids"]) == sorted(installed), starter
        assert target.succeed("stat -c '%a %U' /var/lib/hinteros/starter.json").strip() == "600 root"
        m = json.loads(target.succeed("cat /nix/var/nix/profiles/hinteros/starter/share/hinteros/apps.json"))
        assert m["ids"] == sorted(installed), m
        assert target.succeed("stat -c '%U %a' /nix/var/nix/profiles/hinteros/apps").strip() == "root 755"
        # Nothing of the apps is in the system itself.
        target.fail("test -e /run/current-system/sw/bin/hinteros-firefox-kiosk")

    target.shutdown()
  '';
}
