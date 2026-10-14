# A newer HinterOS than the installer's: the installer serves a local channel repository
# (file:///srv/hinteros.git, built by install/newer-repo.sh from this repo's tree) whose `iso`
# commit is the test installer's revision and whose newer commits are signed with a throwaway key
# that the installer trusts (hinteros.update.allowedSigners). There is no network; the
# HINTEROS_INSTALL_ONLINE_PROBE hook stands in for "online" where a case needs it.
#
#   - `--check-newer` reports the signed newer tip, and nothing newer for the installer's own
#     revision or an older one; an unsigned tip, one signed by an unknown key and one that does not
#     descend from the installer's revision are refused (exit 1, error line);
#   - a plan's `rev`: malformed, offline, not (any more) the channel's tip or not verifying is
#     refused with exit 2 and the disk untouched; the installer's own revision still validates
#     offline;
#   - plan.rev = the newer tip installs it: the device flake.lock pins that revision on the channel,
#     the generation is that release, and the starter env was built from that revision.
{ self, pkgs }:
let
  inherit (pkgs) lib;
  version = lib.fileContents (self + "/release/version");
  bump =
    n:
    let
      p = lib.splitString "." version;
    in
    "${lib.elemAt p 0}.${lib.elemAt p 1}.${toString (lib.toInt (lib.elemAt p 2) + n)}";
  newerVersion = bump 1;

  repo =
    pkgs.runCommand "hinteros-install-newer-repo"
      {
        nativeBuildInputs = [
          pkgs.git
          pkgs.openssh
        ];
      }
      ''
        bash ${./install/newer-repo.sh} "$out" ${self} ${version} ${newerVersion} ${bump 2}
      '';
  # Import from derivation: the installer has to be built knowing its revision and the key.
  revs = builtins.fromJSON (builtins.readFile "${repo}/revs.json");
  releaseKey = lib.trim (builtins.readFile "${repo}/release.pub");

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
          channel = "stable";
          apps = [ "youtube" ];
        }
        // extra
      )
    );
  cases = {
    bad-rev = plan { rev = "abc123"; };
    iso-rev = plan { rev = revs.iso; };
    newer = plan { rev = revs.newer; };
    unsigned = plan { rev = revs.unsigned; };
  };
in
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-install-newer";
  meta.timeout = 5400;

  nodes.installer =
    { pkgs, ... }:
    {
      imports = [ (import ./install/installer-node.nix { inherit self pkgs; }) ];
      hinteros = {
        installer.isoRev = revs.iso;
        release.version = version;
        update = {
          repo = "file:///srv/hinteros.git";
          allowedSigners = [ "release ${releaseKey}" ];
        };
      };
      environment.systemPackages = [ pkgs.git ];
      system.extraDependencies = [ repo ];
    };

  testScript = ''
    import json

    ${builtins.readFile ./install/system-steps.py}
    ${builtins.readFile ./install/copy-plan.py}
    REVS = json.loads('${builtins.toJSON revs}')
    CASES = {${lib.concatStringsSep ", " (lib.mapAttrsToList (n: v: ''"${n}": "${v}"'') cases)}}
    ONLINE = "HINTEROS_INSTALL_ONLINE_PROBE=file:///tmp/online "
    ENV = "HINTEROS_INSTALL_ALLOW_BIOS=1 HINTEROS_INSTALL_FACTER=false "

    installer.start()
    installer.wait_for_unit("multi-user.target")
    installer.succeed("udevadm settle")
    installer.succeed(
        "cp -r ${repo}/hinteros.git /srv/hinteros.git",
        "chmod -R u+w /srv/hinteros.git",
        # Partial clones as the real server allows them.
        "git --git-dir=/srv/hinteros.git config uploadpack.allowFilter true",
        "touch /tmp/online",
    )
    for name, path in CASES.items():
        copy_plan(path, f"/tmp/{name}.json")
    # A marker on the target disk: any partitioning or formatting would destroy it.
    installer.succeed("mkfs.ext4 -q -L marker /dev/vdb")

    def tip(channel, name):
        installer.succeed(f"git --git-dir=/srv/hinteros.git update-ref refs/heads/{channel} {REVS[name]}")

    def check(channel="stable"):
        status, out = installer.execute(f"hinteros-install --check-newer --channel {channel} 2>>/tmp/check.err")
        lines = [json.loads(l) for l in out.splitlines() if l.strip()]
        print(channel, status, lines)
        assert len(lines) == 1, lines
        return status, lines[0]

    def untouched():
        assert 'LABEL="marker"' in installer.succeed("blkid /dev/vdb")
        installer.succeed("test -z \"$(lsblk -nro NAME /dev/vdb | tail -n +2)\"")
        installer.fail("mountpoint -q /mnt")

    def validate(name, env="", validate_only=True):
        flag = " --validate-only" if validate_only else ""
        status, out = installer.execute(f"{ENV}{env}hinteros-install --plan /tmp/{name}.json{flag} 2>>/tmp/validate.err")
        lines = [json.loads(l) for l in out.splitlines() if l.strip()]
        print(name, status, lines)
        untouched()
        return status, lines

    def refused(name, code, env="", validate_only=True):
        status, lines = validate(name, env, validate_only)
        assert status == 2, (name, status, lines)
        assert lines[-1]["level"] == "error" and lines[-1]["code"] == code, (name, code, lines[-1])
        assert not any(l["stage"] in ("fetch", "partition", "packages", "build", "bootloader", "done") for l in lines), lines

    with subtest("--check-newer reports the signed newer tip"):
        tip("stable", "newer")
        status, r = check("stable")
        assert status == 0, r
        assert r == {
            "channel": "stable",
            "iso": {"rev": REVS["iso"], "version": "${version}"},
            "newer": {"rev": REVS["newer"], "version": "${newerVersion}", "date": r["newer"]["date"], "signer": "release"},
        }, r
        assert r["newer"]["date"] > 0, r

    with subtest("nothing newer: the installer's own revision, or an older one"):
        tip("beta", "iso")
        status, r = check("beta")
        assert status == 0 and r["newer"] is None and r["channel"] == "beta", r
        tip("beta", "base")
        status, r = check("beta")
        assert status == 0 and r["newer"] is None, r

    with subtest("tips that do not verify are refused"):
        for name, code in (("unsigned", "unsigned"), ("other", "unknown-signer"), ("notff", "not-fast-forward")):
            tip("stable", name)
            status, r = check("stable")
            assert status == 1, (name, status, r)
            assert r["level"] == "error" and r["code"] == code and r["message"], (name, r)
        status, r = check("nightly")
        assert status == 2 and r["code"] == "channel-invalid", r

    with subtest("plan.rev: refused before anything is touched"):
        refused("bad-rev", "rev-invalid")
        # Offline (no probe): the newer revision is not on the installer.
        tip("stable", "newer")
        refused("newer", "rev-needs-network")
        refused("newer", "rev-needs-network", validate_only=False)
        # The channel moved on since the UI asked: check again.
        tip("stable", "newest")
        refused("newer", "rev-not-tip", env=ONLINE)
        # The tip does not verify (the UI's word for it is not enough).
        tip("stable", "unsigned")
        refused("unsigned", "unsigned", env=ONLINE)
        refused("unsigned", "unsigned", env=ONLINE, validate_only=False)

    with subtest("plan.rev: the installer's own revision validates offline, the newer one online"):
        status, lines = validate("iso-rev")
        assert status == 0 and lines[-1]["stage"] == "done", lines
        tip("stable", "newer")
        status, lines = validate("newer", env=ONLINE)
        assert status == 0 and lines[-1]["stage"] == "done", lines
        assert any("${newerVersion}" in l["message"] for l in lines), lines

    with subtest("plan.rev installs the newer release"):
        def dump():
            print(installer.execute(
                "echo '--- install.stderr'; tail -n 80 /tmp/install.stderr; "
                "echo '--- /var/log/hinteros-install.log'; tail -n 200 /var/log/hinteros-install.log | cut -c1-600; "
                "echo '--- df'; df -h / /tmp /nix/store /mnt; ps -ef | grep -a '[h]interos-install'"
            )[1])

        # In its own session (out of the test shell's process group), the exit status written
        # atomically: a status file that is there is complete.
        installer.succeed(
            "rm -f /tmp/install.rc /tmp/install.out /tmp/install.stderr",
            f"setsid -f sh -c '{ENV}{ONLINE}timeout 3000 hinteros-install --plan /tmp/newer.json "
            ">/tmp/install.out 2>/tmp/install.stderr; echo $? >/tmp/install.rc.new && mv /tmp/install.rc.new /tmp/install.rc' "
            "</dev/null >/dev/null 2>&1",
        )
        rc = None
        gone = 0
        for _ in range(110):
            installer.sleep(30)
            status, out = installer.execute("cat /tmp/install.rc")
            if status == 0 and out.strip():
                rc = int(out.strip())
                break
            print(installer.execute("tail -n 3 /tmp/install.out; tail -n 2 /var/log/hinteros-install.log | cut -c1-300")[1])
            # Gone without a status (killed?): stop waiting after a grace poll.
            gone = gone + 1 if installer.execute("pgrep -f '[h]interos-install --plan'")[0] != 0 else 0
            if gone >= 2:
                break
        out = installer.succeed("cat /tmp/install.out")
        lines = [json.loads(l) for l in out.splitlines() if l.strip()]
        for l in lines:
            print(l)
        if rc != 0:
            dump()
        assert rc == 0, (rc, lines[-3:])
        assert all(l["level"] != "error" for l in lines), lines
        done = lines[-1]
        assert done["stage"] == "done" and done["percent"] == 100, done
        assert done["rev"] == REVS["newer"] and done["version"] == "${newerVersion}", done
        assert REVS["newer"] in done["message"] and done["failed_apps"] == [], done
        pct = [l["percent"] for l in lines]
        assert pct == sorted(pct), pct
        stages = []
        for l in lines:
            if l["stage"] not in stages:
                stages.append(l["stage"])
        assert stages == ["validate", "fetch", "partition", "facter", "config", "packages", "build", "bootloader", "snapshot", "apps", "finalize", "done"], stages
        # The system stage in its three steps (online: the packages are downloaded).
        check_system_steps(lines, "download")

    with subtest("the device flake pins the newer revision, and the system is that release"):
        installer.succeed("mount /dev/disk/by-partlabel/hinteros-root /mnt")
        flake = installer.succeed("cat /mnt/etc/hinteros/flake.nix")
        assert 'inputs.hinteros.url = "git+file:///srv/hinteros.git?ref=stable";' in flake, flake
        lock = json.loads(installer.succeed("cat /mnt/etc/hinteros/flake.lock"))
        node = lock["nodes"][lock["nodes"][lock["root"]]["inputs"]["hinteros"]]
        assert node["locked"]["rev"] == REVS["newer"], node
        assert node["original"] == {"type": "git", "url": "file:///srv/hinteros.git", "ref": "stable"}, node
        # The new root's store paths (and their absolute symlinks) resolve inside it.
        def cat(path):
            return installer.succeed(f"chroot /mnt /nix/var/nix/profiles/system/sw/bin/cat {path}")
        assert cat("/nix/var/nix/profiles/system/hinteros/flake.lock") == installer.succeed("cat /mnt/etc/hinteros/flake.lock")
        release = json.loads(cat("/nix/var/nix/profiles/system/sw/share/hinteros/release.json"))
        assert release["version"] == "${newerVersion}", release
        # The starter env was built from that revision's flake.
        manifest = json.loads(cat("/nix/var/nix/profiles/hinteros/starter/share/hinteros/apps.json"))
        assert manifest["system_rev"] == REVS["newer"] and manifest["ids"] == ["youtube"], manifest
        starter = json.loads(installer.succeed("cat /mnt/var/lib/hinteros/starter.json"))
        assert starter["ids"] == ["youtube"], starter
        installer.succeed("umount -R /mnt")
  '';
}
