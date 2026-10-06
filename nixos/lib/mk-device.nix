# hinteros.lib.mkDevice: builds a device's nixosSystem from its state.json contents.
# See hinteros-docs/design/device-config.md.
{ self, nixpkgs }:
{
  # Decoded state.json (an attrset).
  state,
  # Path to a nixos-facter report, or null before one exists.
  facterReport ? null,
  # Extra NixOS modules (hardware profiles, the dev box's extras).
  extraModules ? [ ],
  # nixpkgs base: "unstable" or "stable".
  base ? state.base or "unstable",
}:
let
  # TODO(stable-base): add a second nixpkgs input (the current NixOS release) and select it
  # here. CI must then build `stable` on both bases.
  nixpkgsFor = {
    unstable = nixpkgs;
  };
in
assert
  nixpkgsFor ? ${base}
  || throw "hinteros.lib.mkDevice: base \"${toString base}\" is not available (supported: ${builtins.concatStringsSep ", " (builtins.attrNames nixpkgsFor)})";
nixpkgsFor.${base}.lib.nixosSystem {
  system = "x86_64-linux";
  modules = [
    self.nixosModules.default
    { hinteros.state = state; }
    {
      hinteros.session.enable = true;
      hinteros.daemon.enable = true;
    }
  ]
  ++ nixpkgs.lib.optional (facterReport != null) { hardware.facter.reportPath = facterReport; }
  ++ extraModules;
}
