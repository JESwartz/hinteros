# Aggregates every HinterOS NixOS module that does not need flake `self`.
{
  imports = [
    ./daemon.nix
    ./input.nix
    ./session.nix
    ./state.nix
    ./fake-steam.nix
    ./unfree.nix
    ./firefox-kiosk.nix
    ./apps.nix
    ./box-features.nix
    ./app-env.nix
    ./profiles.nix
    ./device-config.nix
    ./runtime.nix
    ./maintenance.nix
    ./disk.nix
    ./hardening.nix
    ./branding.nix
    ./diagnostics.nix
    ./network-hardware.nix
  ];
}
