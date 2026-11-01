# hinteros-config-sync: a node whose /etc/hinteros differs from the generation's snapshot gets
# it restored at boot (atomically, facter.json kept); a node without /etc/hinteros is left alone.
{ self, pkgs }:
let
  # A checked-in dir, not a derivation: the module reads it at eval time (like a flake source).
  configDir = ./fixtures/config-sync;
  common = {
    imports = [ self.nixosModules.device-config ];
    system.stateVersion = "25.11";
  };
in
pkgs.testers.runNixOSTest {
  name = "hinteros-config-sync";

  nodes = {
    machine = {
      imports = [ common ];
      hinteros.deviceConfig.configDir = configDir;
    };
    bare = {
      imports = [ common ];
      hinteros.deviceConfig.configDir = configDir;
    };
  };

  testScript = ''
    start_all()
    for m in (machine, bare):
        m.wait_for_unit("multi-user.target")

    # The snapshot is in the toplevel: only the managed files.
    assert machine.succeed("ls /run/current-system/hinteros").split() == ["flake.lock", "flake.nix", "state.json"]
    machine.succeed("grep -q snapshot /run/current-system/hinteros/state.json")

    # No /etc/hinteros: the unit succeeds and creates nothing.
    bare.succeed("systemctl is-active hinteros-config-sync.service")
    bare.fail("test -e /etc/hinteros")
    bare.succeed("journalctl -u hinteros-config-sync --no-pager | grep 'nothing to sync'")

    # A dir that differs (changed, extra and missing files, plus a hardware report that must
    # survive) is restored at boot. The first boot had no /etc/hinteros, so populate it and reboot.
    machine.succeed("""
      mkdir /etc/hinteros
      echo '{"schemaVersion":2,"marker":"stale"}' > /etc/hinteros/state.json
      echo '# stale flake' > /etc/hinteros/flake.nix
      echo 'hardware' > /etc/hinteros/facter.json
      echo 'leftover' > /etc/hinteros/extra.json
    """)
    machine.shutdown()
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("systemctl is-active hinteros-config-sync.service")
    machine.succeed("journalctl -b -u hinteros-config-sync --no-pager | grep 'restoring /etc/hinteros'")
    for f in ("state.json", "flake.nix", "flake.lock"):
        machine.succeed(f"cmp /run/current-system/hinteros/{f} /etc/hinteros/{f}")
    assert machine.succeed("cat /etc/hinteros/facter.json").strip() == "hardware"
    assert machine.succeed("cat /etc/hinteros/extra.json").strip() == "leftover"
    # No temp dirs left behind.
    assert machine.succeed("ls -A /etc | grep -c '^.hinteros.sync' || true").strip() == "0"

    # Already in sync: a rerun changes nothing and says so.
    machine.succeed("systemctl restart hinteros-config-sync.service")
    machine.succeed("journalctl -u hinteros-config-sync --no-pager | grep 'already matches'")

    # Editing a file while the system runs is undone on the next sync (rollback case).
    machine.succeed("echo tampered > /etc/hinteros/state.json && systemctl restart hinteros-config-sync.service")
    machine.succeed("grep -q snapshot /etc/hinteros/state.json")
  '';
}
