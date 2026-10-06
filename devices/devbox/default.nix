# Mini PC #1 (dev box), deployed from the desktop:
#   nixos-rebuild switch --flake .#devbox --target-host deploy@<box> --sudo
# (the unprivileged `deploy` user, key-only SSH, passwordless sudo; the session user is not root
# here either). It goes through mkDevice with a checked-in state file, like boxes #2 and #3 do
# with /etc/hinteros. Add your SSH public key to hinteros.dev.deployKeys below before the first
# deploy. See tests/couch/m0-spikes.md.
{ self }:
self.lib.mkDevice {
  state = builtins.fromJSON (builtins.readFile ./state.json);
  # TODO(M1): generate on the box with `nixos-facter` and check it in as facter.json,
  # then pass `facterReport = ./facter.json;`.
  facterReport = null;
  # The snapshot embedded in every generation (state.json; there is no flake.nix here).
  configDir = ./.;
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
