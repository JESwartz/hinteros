# A stub `nix` for the job unit's PATH in the per-profile app tests: app envs are prebuilt by the
# test (config.hinteros.appEnv.build of the id sets it uses, in the VM's closure) and listed in
# `envs` = { "<ids joined by ,>" = { drv; out; }; }, so a job's env evaluation (DECISIONS D3:
# `nix eval --impure --json --expr '…(builtins.readFile /run/hinteros/jobs/<job>/envs.json)'`)
# and build (`nix build '<drv>^out' …`) need neither the device flake's inputs nor a network.
#   - `eval` with an expr naming an envs.json: prints [{drv, out}] for its id lists (sorted,
#     de-duplicated; an id set the test did not prebuild fails like an evaluation error);
#   - `build <drv>^out`: prints the out path of that drv;
#   - `build` of anything else (the system's toplevel, the `box` stage): prints the store path in
#     /run/stub/toplevel, as stub-nix.nix does, waiting for /run/stub/hold and failing on
#     /run/stub/fail.
# Everything else is the real nix. Every call is logged to /run/stub/nix.log.
{
  pkgs,
  nix,
  envs,
}:
let
  table = pkgs.writeText "stub-envs.json" (builtins.toJSON envs);
in
pkgs.writeShellScriptBin "nix" ''
  echo "$@" >> /run/stub/nix.log
  args=("$@")
  while [ "''${1:-}" = "--extra-experimental-features" ]; do shift 2; done
  case "''${1:-}" in
  eval)
    file=$(printf '%s\n' "''${args[@]}" | grep -o '/run/hinteros/jobs/[^ )'"'"'"]*\.json' | head -n1)
    if [ -n "$file" ]; then
      ${pkgs.jq}/bin/jq -c --slurpfile t ${table} '
        map((sort | unique | join(",")) as $k
          | ($t[0][$k] // error("stub nix: no prebuilt env for [\($k)]")))' "$file"
      exit $?
    fi
    exec ${nix}/bin/nix "''${args[@]}"
    ;;
  build)
    drv=$(printf '%s\n' "''${args[@]}" | grep -o '^/nix/store/[^ ]*\.drv' | head -n1)
    if [ -n "$drv" ]; then
      ${pkgs.jq}/bin/jq -r --arg d "$drv" 'to_entries[] | select(.value.drv == $d) | .value.out' ${table}
      exit 0
    fi
    echo '@nix {"action":"start","id":1,"level":3,"type":103,"text":""}' >&2
    while [ -e /run/stub/hold ]; do sleep 0.1; done
    if [ -e /run/stub/fail ]; then
      echo '@nix {"action":"msg","level":0,"msg":"error: builder for stub.drv failed"}' >&2
      exit 1
    fi
    cat /run/stub/toplevel
    ;;
  *) exec ${nix}/bin/nix "''${args[@]}" ;;
  esac
''
