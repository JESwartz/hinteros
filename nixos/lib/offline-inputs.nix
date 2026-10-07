# The build-time inputs an offline install needs.
#
# Installing a device builds a few dozen small derivations (etc, units, users-groups.json, the
# initrd, the toplevel ...) that differ from the ones in the installer's prebuilt default system.
# Nix builds a derivation only when its inputs are available, and "available" means the OUTPUT
# the derivation asks for is in the store: the installer ships the runtime closure of the default
# system, which does not include outputs that are only ever used at build time (an `-dev` output, a
# helper such as systemd-default-tmpfiles ...). One such missing output makes nix build that
# input, then its inputs, and so on down to the bootstrap tools: on real hardware, with no network,
# "6809 derivations will be built" and a failed download of bash-5.3.tar.gz.
#
# `analysis` works that out from the derivations themselves: for a set of representative devices
# ("variants") it lists every derivation that is not in the default system's derivation closure
# (what an install builds) and, of those, every output they need from derivations that are not
# built. Those outputs (`required.tsv`: output path, derivation, output name) go on the ISO
# (`closure`), and `check` fails a build when one of them is not in the ISO's store.
{ lib, pkgs }:
rec {
  analysis =
    {
      # The default system's toplevel and the variants' toplevels (derivations).
      default,
      variants,
    }:
    let
      drvOf = d: builtins.unsafeDiscardOutputDependency d.drvPath;
    in
    pkgs.runCommand "hinteros-offline-inputs"
      {
        nativeBuildInputs = [ pkgs.python3 ];
        # Only the .drv files and their closure enter the sandbox, never the outputs. (Not
        # exportReferencesGraph: with gc-keep-outputs it demands the outputs of the derivations.)
        defaultDrv = drvOf default;
        variantDrvs = map drvOf variants;
      }
      ''
        python3 ${./offline-inputs.py} > $out
      '';

  # The analysis as a list of { out, drv, name }.
  required =
    a:
    map (
      l:
      let
        f = lib.splitString "\t" l;
      in
      {
        # (readFile of a derivation output carries that derivation as context; drop it)
        out = builtins.unsafeDiscardStringContext (builtins.elemAt f 0);
        drv = builtins.unsafeDiscardStringContext (builtins.elemAt f 1);
        name = builtins.unsafeDiscardStringContext (builtins.elemAt f 2);
      }
    ) (lib.filter (l: l != "" && !lib.hasPrefix "#" l) (lib.splitString "\n" (builtins.readFile a)));

  # The store paths for system.extraDependencies: each output path carrying the context that
  # makes the build realise that output of that derivation.
  closure =
    a:
    map (
      r:
      builtins.appendContext r.out {
        ${r.drv} = {
          outputs = [ r.name ];
        };
      }
    ) (required a);

  # Fails unless every required output is in the closure of `toplevel` (the ISO's system).
  check =
    {
      name,
      analysis,
      toplevel,
    }:
    pkgs.runCommand name { closure = pkgs.closureInfo { rootPaths = [ toplevel ]; }; } ''
      missing=$(cut -f1 ${analysis} | grep -v '^#' | sort -u | grep -vxFf $closure/store-paths || true)
      if [ -n "$missing" ]; then
        echo "These outputs are build-time inputs of what an offline install builds, but are not on the installer:" >&2
        echo "$missing" >&2
        exit 1
      fi
      echo "$(grep -vc '^#' ${analysis}) required outputs, all on the installer" > $out
    '';
}
