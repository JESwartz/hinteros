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
}:
let
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
      disk = "/dev/vdb";
      hostname = "livingroom";
      admin = {
        user = "james";
        password = "hunter2";
      };
      ssh.enable = true;
      channel = "stable";
      base = "unstable";
      apps = [
        "youtube"
        "firefox"
      ];
      acceptedTerms = { };
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
        imports = [ (import ./install/installer-node.nix { inherit self pkgs; }) ];
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

    installer.start()
    installer.wait_for_unit("multi-user.target")
    installer.succeed("udevadm settle")
    installer.succeed("test -b /dev/vdb")
    # No network: the installer must work from its own store.
    installer.fail("curl -sS --max-time 3 https://cache.nixos.org/nix-cache-info")

    installer.copy_from_host("${plan}", "/tmp/plan.json")
    installer.copy_from_host("${extraModule}", "/tmp/extra-module.nix")

    with subtest("hinteros-install runs and reports progress"):
        installer.succeed(
            "(HINTEROS_INSTALL_ALLOW_BIOS=1 ${facterEnv}HINTEROS_INSTALL_EXTRA_MODULE=/tmp/extra-module.nix "
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
        status = 0 if '"stage":"done"' in out.splitlines()[-1] else 1
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
        assert stages == ["validate", "partition", "facter", "config", "install", "snapshot", "finalize", "done"], stages
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
        assert state["schemaVersion"] == 1, state
        assert state["apps"] == ["youtube", "firefox"], state
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

    with subtest("the privileged service answers (system API 0.3) and knows its channel"):
        hello = {"jsonrpc": "2.0", "id": 0, "method": "hello",
                 "params": {"api_version": "0.3", "client": {"name": "install-test", "version": "0"}}}
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
        target.succeed("printf 'hunter2\\n' | runuser -u james -- sudo -S -k true")
        target.fail("printf 'wrong\\n' | runuser -u james -- sudo -S -k true")
        # The hash is not in the config the generation embeds.
        h = target.succeed("cat /var/lib/hinteros/admin-password-hash").strip()
        target.fail(f"grep -rFq {shlex.quote(h)} /etc/hinteros /run/current-system/hinteros /etc/static")

    with subtest("sshd: password login for the admin only"):
        target.wait_for_unit("sshd.service")
        target.succeed("ss -tln | grep -q ':22 '")
        opts = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=6"
        def pw(user, password="hunter2", cmd="true"):
            return f"sshpass -p {password} ssh {opts} {user}@localhost {cmd}"
        target.succeed(pw("james", cmd="id -un"))
        target.fail(pw("james", "wrong"))
        target.fail(pw("hinteros"))
        target.fail(pw("root"))

    with subtest("apps: only the selected ones"):
        uid = target.succeed("id -u hinteros").strip()
        sock = f"/run/user/{uid}/hinteros/session.sock"
        target.wait_until_succeeds(f"test -S {sock}")
        hello = {"jsonrpc": "2.0", "id": 0, "method": "hello",
                 "params": {"api_version": "0.9", "client": {"name": "install-test", "version": "0"}}}
        call = {"jsonrpc": "2.0", "id": 1, "method": "apps.list", "params": {}}
        payload = "".join(json.dumps(m) + "\n" for m in (hello, call))
        cmd = f"(printf %s {shlex.quote(payload)}; sleep 2) | socat -t2 - UNIX-CONNECT:{sock}"
        out = target.succeed(f"runuser -u hinteros -- sh -c {shlex.quote(cmd)}")
        replies = [json.loads(l) for l in out.splitlines() if l.strip()]
        apps = next(r for r in replies if r.get("id") == 1)["result"]["apps"]
        ids = [a["id"] for a in apps]
        print(ids)
        assert "youtube" in ids and "firefox" in ids, ids
        for absent in ("jellyfin", "crunchyroll", "plex-htpc", "moonlight"):
            assert absent not in ids, ids

    target.shutdown()
  '';
}
