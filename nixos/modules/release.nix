# The vendor's release data, read from
# the repo's `release/` directory: the version, the keys that sign release commits and the
# binary cache keys. Part of `nixosModules.default` only (flake.nix), not of `./default.nix` or
# the individual modules, so a config that picks modules one by one does not inherit this
# vendor's trust: the options themselves default to empty.
#
# Everything is set with `mkDefault`: a definition anywhere else (the dev box, a test with its
# own signer) replaces the vendor's value instead of adding to it.
{ lib, ... }:
let
  dir = ../../release;

  # Non-empty lines that are not comments.
  entries =
    file:
    lib.filter (l: l != "" && !lib.hasPrefix "#" l) (
      map lib.trim (lib.splitString "\n" (builtins.readFile file))
    );

  version = lib.fileContents (dir + "/version");
in
assert
  builtins.match "(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)" version != null
  || throw "release/version must be MAJOR.MINOR.PATCH, got \"${version}\"";
{
  hinteros = {
    release.version = lib.mkDefault version;
    update.allowedSigners = lib.mkDefault (entries (dir + "/allowed_signers"));
    cache.publicKeys = lib.mkDefault (entries (dir + "/cache-keys"));
  };
}
