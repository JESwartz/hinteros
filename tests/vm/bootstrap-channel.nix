# hinteros-bootstrap-channel (nixos/pkgs/hinteros-bootstrap-channel), end to end, in its
# testHooks build: the box's config dir, policy and system profile are under /var/lib/box and
# /nix/var/nix/profiles/box-system, the answers come from a file, and the channel repo is a local
# bare repo, file:///srv/channel.git. The box's flake (fixtures/bootstrap-channel/flake.nix) uses
# the locked rev's source as its system: its bin/switch-to-configuration logs "<action>
# <release/version>" to /run/stand-in.log, and C's fails on switch.
# Keys are made in the test: `release` (in the box's allowed_signers) and `bad` (not).
# The channel repo: A (stable) <- B (signed by `bad`) <- C (activation fails) <- D (beta).
# The box starts on stable at A.
#   - The production build ignores the hooks (it looks at /etc/hinteros).
#   - Not root, not confirmed, no answer, no terminal, a repo URL that is not https or file:
#     refused, the box unchanged.
#   - B: a bad signature is refused, the box unchanged.
#   - C: the activation fails: the previous system is the profile and the boot default again
#     ("boot A"), the config dir is unchanged and no staging copy is left.
#   - D: the box moves to beta (flake.nix and flake.lock) at D, and the new system is switched to.
#   - stable at A from D: refused without --allow-downgrade, done with it.
{ self, pkgs }:
let
  inherit (pkgs) lib;
  bootstrap = pkgs.callPackage ../../nixos/pkgs/hinteros-bootstrap-channel { testHooks = true; };
  production = self.packages.${pkgs.stdenv.hostPlatform.system}.hinteros-bootstrap-channel;
in
pkgs.testers.runNixOSTest {
  name = "hinteros-bootstrap-channel";

  nodes.machine = {
    environment.systemPackages = [
      bootstrap
      pkgs.git
      pkgs.openssh
      pkgs.jq
    ];
    environment.etc."bootstrap-test/flake.nix".source = ./fixtures/bootstrap-channel/flake.nix;
    system.extraDependencies = [ production ];
    # Nothing to download.
    nix.settings = {
      substituters = lib.mkForce [ ];
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      flake-registry = "";
    };
    users.users.alice.isNormalUser = true;
  };

  testScript = ''
    import json
    import shlex

    NIX = "nix --extra-experimental-features 'nix-command flakes'"
    BOX = "/var/lib/box"
    CFG = f"{BOX}/hinteros"
    PROFILE = "/nix/var/nix/profiles/box-system"
    HOOKS = (f"HINTEROS_CONFIG_DIR={CFG} HINTEROS_POLICY_DIR={BOX}/policy "
             f"HINTEROS_SYSTEM_PROFILE={PROFILE}")
    GIT = "git -C /root/work -c user.name=Release -c user.email=release@test -c gpg.format=ssh"
    GOOD = "#!/bin/sh\nread -r v < \"''${0%/bin/*}/release/version\"\necho \"$1 $v\" >> /run/stand-in.log\n"
    FAILS = GOOD + "[ \"$1\" != switch ] || exit 1\n"

    def commit(name, key, activate):
        """Commit a rev with this switch-to-configuration, signed with key; return its hash."""
        machine.succeed(
            f"printf %s {shlex.quote(activate)} > /root/work/bin/switch-to-configuration",
            "chmod +x /root/work/bin/switch-to-configuration",
            f"echo 1.0.0-{name} > /root/work/release/version",
            f"{GIT} add -A",
            f"{GIT} -c user.signingkey=/root/keys/{key} commit -q -S -m {name}",
        )
        return machine.succeed(f"{GIT} rev-parse HEAD").strip()

    def run(args, answers="y\ny\n", tty=True, prefix=""):
        """Run the script (hooks set); return (status, output)."""
        machine.succeed(f"printf {shlex.quote(answers)} > /tmp/answers")
        env = HOOKS + (" HINTEROS_TTY=/tmp/answers" if tty else "")
        status, out = machine.execute(f"{prefix}env {env} hinteros-bootstrap-channel {args} 2>&1")
        print(out)
        return status, out

    def refused(args, expect, **kw):
        before = snapshot()
        status, out = run(args, **kw)
        assert status != 0, out
        assert expect in out, f"{expect!r} not in {out!r}"
        assert snapshot() == before, "the box changed"

    def snapshot():
        """The config dir, the system profile, the activation log and the staging copies."""
        return machine.succeed(
            f"cd {CFG} && sha256sum flake.nix flake.lock; readlink -f {PROFILE};"
            f" cat /run/stand-in.log 2>/dev/null || true; ls -A {BOX}"
        )

    def locked():
        lock = json.loads(machine.succeed(f"cat {CFG}/flake.lock"))
        node = lock["nodes"][lock["nodes"][lock["root"]]["inputs"]["hinteros"]]
        return node["original"].get("ref"), node["locked"]["rev"]

    def activations():
        return machine.succeed("cat /run/stand-in.log 2>/dev/null || true").splitlines()

    machine.wait_for_unit("multi-user.target")

    with subtest("setup: keys, the signed channel repo, the box on stable at A"):
        machine.succeed(
            "mkdir -p /root/keys /root/work/release /root/work/bin",
            "for k in release bad; do ssh-keygen -q -t ed25519 -N ''' -C $k -f /root/keys/$k; done",
            "git init -q -b main /root/work",
            "echo '{ outputs = _: { }; }' > /root/work/flake.nix",
        )
        A = commit("A", "release", GOOD)
        B = commit("B", "bad", GOOD)
        C = commit("C", "release", FAILS)
        D = commit("D", "release", GOOD)
        machine.succeed(
            "git init -q --bare /srv/channel.git",
            f"{GIT} push -q /srv/channel.git {A}:refs/heads/stable {D}:refs/heads/beta",
            f"mkdir -p {BOX}/policy/update {CFG}",
            "echo '{\"repo\":\"file:///srv/channel.git\",\"branches\":{\"stable\":\"stable\",\"beta\":\"beta\"}}'"
            f" > {BOX}/policy/update/channels.json",
            f"echo \"release namespaces=\\\"git\\\" $(cat /root/keys/release.pub)\" > {BOX}/policy/update/allowed_signers",
            f"install -m 0644 /etc/bootstrap-test/flake.nix {CFG}/flake.nix",
            f"{NIX} flake lock path:{CFG}",
            f"{NIX} build --no-link --print-out-paths"
            f" path:{CFG}#nixosConfigurations.hinteros.config.system.build.toplevel > /tmp/old",
            f"nix-env -p {PROFILE} --set $(cat /tmp/old)",
        )
        old = machine.succeed("cat /tmp/old").strip()
        assert locked() == ("stable", A), locked()
        assert machine.succeed(f"cat {old}/release/version").strip() == "1.0.0-A"

    with subtest("the production build ignores the test hooks"):
        status, out = run(f"beta {D}", prefix="PATH=${production}/bin:$PATH ")
        assert status != 0 and "/etc/hinteros has no flake.nix/flake.lock" in out, out

    with subtest("refused: not root, not confirmed, no terminal, a repo that is not https"):
        refused(f"beta {D}", "run it as root", prefix="runuser -u alice -- ")
        refused(f"beta {D}", "not confirmed; nothing changed", answers="n\n")
        refused(f"beta {D}", "not confirmed; nothing changed", answers="")
        # setsid: no controlling terminal, whatever the test driver gives its shell.
        refused(f"beta {D}", "cannot read from /dev/tty", tty=False, prefix="setsid -w ")
        machine.succeed(f"sed -i 's|file:///|http://|' {BOX}/policy/update/channels.json")
        refused(f"beta {D}", "unexpected repo URL in channels.json: http://srv/channel.git")
        machine.succeed(f"sed -i 's|http://|file:///|' {BOX}/policy/update/channels.json")

    with subtest("B: a bad signature is refused"):
        refused(f"beta {B}", "is not signed by a key this box trusts; nothing changed")

    with subtest("C: a failed activation is rolled back"):
        before = machine.succeed(f"cd {CFG} && sha256sum flake.nix flake.lock")
        status, out = run(f"beta {C}")
        assert status != 0 and "activation failed" in out, out
        assert activations() == ["switch 1.0.0-C", "boot 1.0.0-A"], activations()
        assert machine.succeed(f"readlink -f {PROFILE}").strip() == old
        assert machine.succeed(f"cd {CFG} && sha256sum flake.nix flake.lock") == before
        assert machine.succeed(f"ls -A {BOX}").split() == ["hinteros", "policy"]

    with subtest("D: the box moves to beta at D"):
        status, out = run(f"beta {D}")
        assert status == 0 and "Done: this box follows 'beta'" in out, out
        assert locked() == ("beta", D), locked()
        machine.succeed(f"grep -qF '\"git+file:///srv/channel.git?ref=beta\"' {CFG}/flake.nix")
        new = machine.succeed(f"readlink -f {PROFILE}").strip()
        assert new != old and machine.succeed(f"cat {new}/release/version").strip() == "1.0.0-D"
        assert activations()[-1] == "switch 1.0.0-D", activations()
        assert machine.succeed(f"ls -A {BOX}").split() == ["hinteros", "policy"]

    with subtest("stable at A from D: a downgrade needs --allow-downgrade"):
        refused(f"stable {A}", f"does not follow this box's revision {D}")
        status, out = run(f"--allow-downgrade stable {A}")
        assert status == 0 and "Done: this box follows 'stable'" in out, out
        assert "WARNING:" in out, out
        assert locked() == ("stable", A), locked()
        assert activations()[-1] == "switch 1.0.0-A", activations()
  '';
}
