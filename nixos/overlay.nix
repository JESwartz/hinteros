# HinterOS' own packages. The component packages (hinteros-launcher, hinteros-session,
# hinteros-system) come from the component flakes' overlays, composed with this one in
# flake.nix's `overlays.default`.
final: _prev: {
  hinteros-placeholder-home = final.callPackage ./pkgs/placeholder-home.nix { };
}
