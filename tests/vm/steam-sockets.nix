# Steam's FHS bwrap hides HinterOS's sockets (nixos/lib/steam.nix).
# Steam itself is unfree and needs the network, so this runs `.run-free` (steam-run without
# Steam): the same bwrap script with the same extra arguments. As the session user, inside:
# no /run/hinteros/system.sock, no $XDG_RUNTIME_DIR/hinteros/{session,osk}.sock, and both
# directories are empty tmpfs; the app envs (/run/hinteros/apps) are still there, read-only.
# Stock steam-run (no override) sees the sockets: the control.
{ self, pkgs }:
let
  ourRun = (import ../../nixos/lib/steam.nix pkgs.steam).run-free;
  stockRun = pkgs.steam.run-free;
in
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-steam-sockets";

  nodes.machine = {
    imports = [
      self.nixosModules.session
      self.nixosModules.daemon
      ../../nixos/vm
    ];
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_until_succeeds("pgrep -u hinteros-p1 -f '/bin/cage '")
    machine.wait_for_unit("hinteros-session.service", "hinteros-p1")
    uid = machine.succeed("id -u hinteros-p1").strip()
    rt = f"/run/user/{uid}"
    machine.wait_until_succeeds(f"test -S {rt}/hinteros/session.sock")
    machine.wait_until_succeeds("test -S /run/hinteros/system.sock")
    machine.succeed("mkdir -p /run/hinteros/apps/hinteros-p1 && touch /run/hinteros/apps/hinteros-p1/marker")

    user = f"runuser -u hinteros-p1 -- env XDG_RUNTIME_DIR={rt}"

    def inside(run, cmd):
        return machine.succeed(f"{user} {run}/bin/steam-run sh -c '{cmd}'").strip()

    with subtest("stock steam-run sees our sockets (control)"):
        out = inside("${stockRun}", f"ls /run/hinteros {rt}/hinteros")
        assert "system.sock" in out and "session.sock" in out, out

    with subtest("our Steam does not"):
        assert inside("${ourRun}", "ls -A /run/hinteros") == "apps", "only the app envs"
        assert inside("${ourRun}", f"ls -A {rt}/hinteros") == "", "runtime dir empty"
        inside("${ourRun}", "test ! -e /run/hinteros/system.sock")
        inside("${ourRun}", f"test ! -e {rt}/hinteros/session.sock && test ! -e {rt}/hinteros/osk.sock")

    with subtest("app envs stay, read-only"):
        inside("${ourRun}", "test -e /run/hinteros/apps/hinteros-p1/marker")
        machine.fail(f"{user} ${ourRun}/bin/steam-run sh -c 'touch /run/hinteros/apps/x'")

    with subtest("the rest of the runtime dir stays"):
        machine.succeed(f"runuser -u hinteros-p1 -- touch {rt}/steam-test")
        inside("${ourRun}", f"test -e {rt}/steam-test")
  '';
}
