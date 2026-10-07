# The ISO must carry every build-time input of the derivations an offline install builds. On
# real hardware (no network) one missing output (a `-dev` output, a helper that no runtime closure
# references) made nix build its inputs, then theirs, down to bootstrap bash, and the install died
# on "Could not resolve host: ftpmirror.gnu.org". The VM tests could not see it: they used to share
# the host's store. This check works on the derivations: for devices that differ from the
# installer's default system (other host names, users, app sets) it lists the outputs the install
# needs from derivations it does not build, and fails if one is not in the closure of the ISO's
# system.
{ self, pkgs }:
let
  c = self.nixosConfigurations.installer.config;
  offlineInputs = import ../../nixos/lib/offline-inputs.nix {
    inherit (pkgs) lib;
    inherit pkgs;
  };
in
offlineInputs.check {
  name = "hinteros-offline-inputs-on-iso";
  analysis = c.hinteros.installer.offlineInputs.check;
  toplevel = c.system.build.toplevel;
}
