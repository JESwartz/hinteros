# HinterOS overlay. Component packages (launcher, daemon) are added here once
# their flakes are inputs.
final: _prev: {
  hinteros-placeholder-home = final.callPackage ./pkgs/placeholder-home.nix { };
}
