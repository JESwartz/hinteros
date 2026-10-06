# HinterOS' own packages. The component packages (hinteros-launcher, hinteros-session,
# hinteros-system) come from the component flakes' overlays, composed with this one in
# flake.nix's `overlays.default`.
final: _prev: {
  hinteros-placeholder-home = final.callPackage ./pkgs/placeholder-home.nix { };
  hinteros-fake-steam = final.callPackage ./pkgs/fake-steam { };
  hinteros-firefox-kiosk = final.callPackage ./pkgs/firefox-kiosk.nix { };
}
