# hinteros.lib.mkDevice: builds a device's nixosSystem from its state.json contents.
# See hinteros-docs/design/device-config.md.
{ self, nixpkgs }:
{
  # Decoded state.json (an attrset).
  state,
  # Path to a nixos-facter report, or null: the device then gets generic hardware support
  # (nixos/modules/generic-hardware.nix), the same on every machine.
  facterReport ? null,
  # The device config dir (flake.nix, flake.lock, state.json) this system is built from; embedded
  # in the toplevel as the generation snapshot. null: the snapshot is just state.json.
  configDir ? null,
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
      # A console appliance: no man pages or NixOS manual (no builds of them on every rebuild,
      # nothing to carry on the installer ISO). A device can switch them back on.
      documentation.enable = nixpkgs.lib.mkDefault false;
      system.tools.nixos-generate-config.enable = nixpkgs.lib.mkDefault false;
    }
    (nixpkgs.lib.optionalAttrs (configDir != null) { hinteros.deviceConfig.configDir = configDir; })
    {
      hinteros.session.enable = true;
      hinteros.daemon.enable = true;
    }
  ]
  ++ nixpkgs.lib.optional (facterReport != null) { hardware.facter.reportPath = facterReport; }
  ++ nixpkgs.lib.optional (facterReport == null) self.nixosModules.generic-hardware
  ++ extraModules;
}
