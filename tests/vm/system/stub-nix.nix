# A stub `nix` for the job unit's PATH: `build` (the only nix command the apply jobs run) waits
# for /run/stub/hold to go away, fails if /run/stub/fail exists, and otherwise prints the store
# path in /run/stub/toplevel (a prebuilt specialisation of the test VM). Everything else is the
# real nix. Every call is logged to /run/stub/nix.log.
{ pkgs, nix }:
pkgs.writeShellScriptBin "nix" ''
  echo "$@" >> /run/stub/nix.log
  while [ "$1" = "--extra-experimental-features" ]; do shift 2; done
  case "$1" in
  build)
    echo '@nix {"action":"start","id":1,"level":3,"type":103,"text":""}' >&2
    echo '@nix {"action":"result","id":1,"type":105,"fields":[1,4,0,0]}' >&2
    while [ -e /run/stub/hold ]; do sleep 0.1; done
    if [ -e /run/stub/fail ]; then
      echo '@nix {"action":"msg","level":0,"msg":"error: builder for stub.drv failed"}' >&2
      exit 1
    fi
    echo '@nix {"action":"result","id":1,"type":105,"fields":[4,4,0,0]}' >&2
    cat /run/stub/toplevel
    ;;
  *) exec ${nix}/bin/nix "$@" ;;
  esac
''
