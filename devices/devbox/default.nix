# Mini PC #1 (dev box), deployed from the desktop:
#   nixos-rebuild switch --flake .#devbox --target-host <user>@<box> --sudo
# It goes through mkDevice with a checked-in state file, like boxes #2 and #3 do with
# /etc/hinteros. Add your SSH public key to authorizedKeys in state.json before the first deploy.
# See tests/couch/m0-spikes.md.
{ self }:
self.lib.mkDevice {
  state = builtins.fromJSON (builtins.readFile ./state.json);
  # TODO(M1): generate on the box with `nixos-facter` and check it in as facter.json,
  # then pass `facterReport = ./facter.json;`.
  facterReport = null;
  # The snapshot embedded in every generation (state.json; there is no flake.nix here).
  configDir = ./.;
  extraModules = [ ./hardware.nix ];
}
