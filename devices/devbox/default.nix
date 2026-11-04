# Mini PC #1 (dev box), deployed from the desktop:
#   nixos-rebuild switch --flake .#devbox --target-host deploy@<box> --sudo
# (the unprivileged `deploy` user, key-only SSH, passwordless sudo; the session user is not root
# here either). It goes through mkDevice with a checked-in state file, like boxes #2 and #3 do
# with /etc/hinteros. Add your SSH public key to hinteros.dev.deployKeys below before the first
# deploy. See tests/couch/m0-spikes.md. The M0/M1 setup (NixOS installed by hand, ext4 by label in
# hardware.nix): never deploy it to a box the installer made (btrfs by UUID); that box follows its
# channel.
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
