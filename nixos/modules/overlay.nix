# Wires the HinterOS overlay into nixpkgs for any system using the modules.
{ self }:
_: {
  nixpkgs.overlays = [ self.overlays.default ];
}
