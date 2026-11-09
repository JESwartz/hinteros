# Box features: the closed list of box-wide settings an app can ask
# for in its catalog entry (`box`). A feature runs nothing and installs nothing for users; it is
# on when any owner (a profile, the guest, the starter set) has an app that needs it.
#
# Who sets `hinteros.boxFeatures`:
#   - devices: state.json `requirements` (maintained by hinteros-system, state.nix),
#   - test VMs: the union over the box-wide apps that are on (catalog.nix).
# A new feature is a system-repo change here and in hinteros-catalog's validator (`features`).
{
  config,
  lib,
  ...
}:
let
  cfg = config.hinteros;

  # Feature -> NixOS config. Keep in step with hinteros-catalog's lib `features`.
  features = {
    # 32-bit graphics drivers and audio for Steam's 32-bit runtime and games. Steam's FHS env
    # finds them at /run/opengl-driver-32.
    graphics32 = {
      hardware.graphics.enable32Bit = true;
      services.pipewire.alsa.support32Bit = true;
    };
    # udev rules for Steam Controller, Index and Deck-style pads (uaccess).
    steam-devices = {
      hardware.steam-hardware.enable = true;
    };
  };
in
{
  options.hinteros = {
    boxFeatures = lib.mkOption {
      type = lib.types.listOf (lib.types.enum (builtins.attrNames features));
      default = [ ];
      example = [
        "graphics32"
        "steam-devices"
      ];
      description = "Box features that are on.";
    };

    knownBoxFeatures = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      internal = true;
      default = builtins.attrNames features;
      description = "Every feature name this system knows.";
    };
  };

  config = lib.mkMerge (
    lib.mapAttrsToList (name: settings: lib.mkIf (lib.elem name cfg.boxFeatures) settings) features
  );
}
