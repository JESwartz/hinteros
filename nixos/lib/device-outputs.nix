# hinteros.lib.deviceOutputs: the outputs of a device flake, given its config dir. All a device
# does lives here, so /etc/hinteros/flake.nix never needs rewriting on an installed box.
{ self }:
dir:
let
  has = f: builtins.pathExists (dir + "/${f}");
in
{
  nixosConfigurations.hinteros = self.lib.mkDevice {
    state = builtins.fromJSON (builtins.readFile (dir + "/state.json"));
    # Written by `nixos-facter` during the install. An offline install installs the generic
    # system that is on the installer medium and marks the report `facter.deferred`: a box
    # that boots on hardware the medium's system was not built for would otherwise need a
    # build. The marker goes away once the box is online (hinteros-facter-release), and the
    # next rebuild or update applies the report. The box still boots without it.
    facterReport = if has "facter.json" && !has "facter.deferred" then dir + "/facter.json" else null;
    # The snapshot embedded in every generation (flake.nix, flake.lock, state.json).
    configDir = dir;
    # What this install needs beyond the state (the installer's boot loader override). Not in
    # the snapshot: it belongs to the install, not to a generation (device-config.nix).
    extraModules = if has "extra.nix" then [ (dir + "/extra.nix") ] else [ ];
  };
}
