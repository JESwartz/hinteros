# Central allowlist of unfree packages. Modules and devices add package names to
# `hinteros.unfreeAllowlist`; this module turns the list into the one allowUnfreePredicate
# (several predicates cannot be merged, so nobody else may set it).
#
# Steam is unfreeRedistributable and may be cached. Plex HTPC is unfree and not
# redistributable: it must never be in a binary cache or an ISO. A build that ships to
# others (the future ISO / cache job) sets `hinteros.forbidUnfree = true`, which fails
# evaluation while the allowlist is non-empty.
{ config, lib, ... }:
let
  cfg = config.hinteros;
in
{
  options.hinteros = {
    unfreeAllowlist = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "plex-htpc" ];
      description = ''
        Names (`lib.getName`) of the unfree packages this system may use. Everything
        else unfree is refused by nixpkgs.
      '';
    };

    forbidUnfree = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Assert that `unfreeAllowlist` is empty. Set by configurations that are published
        (binary cache, installer ISO), where unfree packages must never end up.
      '';
    };
  };

  config = {
    # Only when something is allowlisted: an empty list is nixpkgs' default, and the
    # read-only pkgs of VM tests refuse any nixpkgs.config definition.
    nixpkgs.config = lib.mkIf (cfg.unfreeAllowlist != [ ]) {
      allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) cfg.unfreeAllowlist;
    };

    assertions = [
      {
        assertion = !cfg.forbidUnfree || cfg.unfreeAllowlist == [ ];
        message = "hinteros.forbidUnfree is set but unfree packages are allowlisted: ${lib.concatStringsSep ", " cfg.unfreeAllowlist}";
      }
    ];
  };
}
