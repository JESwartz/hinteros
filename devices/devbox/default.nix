# The dev-mode configuration (`hinteros.dev`), built and checked by the tests as
# `nixosConfigurations.devbox`. It is not what runs on mini PC #1: that box was installed with
# the installer and is updated like any box, from /etc/hinteros (its own state.json, with the
# disk by UUID). Never deploy `.#devbox` to an installed box: the checked-in state.json has no
# `disk`, so it would boot the placeholder file systems in hardware.nix.
#
# Only a box whose disks carry those labels takes it, through the `deploy` user (key-only SSH,
# passwordless sudo; the session user is not root here either; add your key to
# hinteros.dev.deployKeys below):
#   nixos-rebuild switch --flake .#devbox --target-host deploy@<box> --sudo
# See tests/couch/m0-spikes.md.
#
# A function of the state (`self.lib.devices.devbox`): `nixosConfigurations.devbox` passes the
# checked-in state.json, and the device flake embedded in every generation's snapshot
# (`selfFlake`) passes /etc/hinteros/state.json, so hinteros-system can evaluate app envs and
# apply a state it rewrote on this box like on any other.
{ self }:
{ state }:
self.lib.mkDevice {
  inherit state;
  # TODO(M1): generate on the box with `nixos-facter` and check it in as facter.json,
  # then pass `facterReport = ./facter.json;`.
  facterReport = null;
  # The snapshot: a generated flake.nix and flake.lock naming this repo by store path, plus the
  # state.
  selfFlake = "devbox";
  extraModules = [
    ./hardware.nix
    {
      # The only dev switch: adds the `deploy` user and nothing for the session user.
      hinteros.dev = {
        enable = true;
        # Your own public key(s), e.g. the contents of ~/.ssh/id_ed25519.pub. Empty on purpose:
        # never commit a key that is not yours.
        deployKeys = [ ];
      };
    }
  ];
}
