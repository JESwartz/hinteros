# The HinterOS binary cache as a substituter: cache.nixos.org first, the HinterOS cache second,
# so the home lab only serves what cache.nixos.org lacks. OFF until the cache exists (Phase 2);
# the keys come from `release/cache-keys` through release.nix.
{ config, lib, ... }:
let
  cfg = config.hinteros.cache;
in
{
  options.hinteros.cache = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Substitute from the HinterOS binary cache (after cache.nixos.org).";
    };

    url = lib.mkOption {
      type = lib.types.str;
      default = "https://cache.hinteros.org";
      description = "The HinterOS binary cache.";
    };

    publicKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "cache.hinteros.org-1:AAAA..." ];
      description = ''
        Keys whose narinfo signatures are trusted for the HinterOS cache (`<name>:<base64>`).
        Empty by default; `nixosModules.default` sets the vendor's from `release/cache-keys`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.publicKeys != [ ];
        message = "hinteros.cache.enable needs at least one key in hinteros.cache.publicKeys.";
      }
    ];
    # extra-*: added next to cache.nixos.org (priority 40 in its nix-cache-info) and its key,
    # never replacing them.
    nix.settings = {
      extra-substituters = [ "${cfg.url}?priority=50" ];
      extra-trusted-public-keys = cfg.publicKeys;
    };
  };
}
