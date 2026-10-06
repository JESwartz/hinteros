# Aggregates every HinterOS NixOS module that does not need flake `self`.
{
  imports = [
    ./daemon.nix
    ./input.nix
    ./session.nix
    ./state.nix
    ./fake-steam.nix
  ];
}
