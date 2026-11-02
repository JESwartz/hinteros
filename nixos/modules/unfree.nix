# Central allowlist of unfree packages. The catalog derives it from the enabled apps
# (catalog.nix: each entry's `license.unfreePackages`); devices and modules may add names to
# `hinteros.unfreeAllowlist`. This module turns the list into the one allowUnfreePredicate
# (several predicates cannot be merged, so nobody else may set it).
#
# What may be shipped to others is a separate question. A build that ships (the installer ISO,
# the binary cache job) sets `hinteros.forbidUnfree = true`, which fails evaluation when the
# allowlist holds anything outside `hinteros.unfreeExceptions`:
#   - the ISO leaves the exceptions empty: nothing unfree at all, Steam included;
#   - the cache job sets them to `config.hinteros.catalog.cacheableUnfree`: the unfree packages
#     of entries with `delivery = "download"`, which nixpkgs marks unfreeRedistributable (Steam). Plex
#     HTPC is unfree and not redistributable: it is built on the box, never cached.
{ config, lib, ... }:
let
  cfg = config.hinteros;
  forbidden = lib.subtractLists cfg.unfreeExceptions cfg.unfreeAllowlist;
in
{
  options.hinteros = {
    unfreeAllowlist = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "plex-htpc" ];
      description = ''
        Names (`lib.getName`) of the unfree packages this system may use. Everything
        else unfree is refused by nixpkgs. Enabled catalog apps add their own.
      '';
    };

    forbidUnfree = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Assert that `unfreeAllowlist` holds nothing outside `unfreeExceptions`. Set by
        configurations that are published (binary cache, installer ISO).
      '';
    };

    unfreeExceptions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = lib.literalExpression "config.hinteros.catalog.cacheableUnfree";
      description = "Unfree package names `forbidUnfree` lets through (the cache job: the catalog's cacheable ones). Empty on the ISO.";
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
        assertion = !cfg.forbidUnfree || forbidden == [ ];
        message = "hinteros.forbidUnfree is set but unfree packages are allowlisted: ${lib.concatStringsSep ", " forbidden}";
      }
    ];
  };
}
