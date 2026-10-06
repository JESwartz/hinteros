# Aggregates every HinterOS NixOS module that does not need flake `self`.
{
  imports = [
    ./daemon.nix
    ./session.nix
  ];
}
