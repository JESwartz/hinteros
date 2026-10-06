# Fake Steam for tests: a `steam` stub that records its argv and shows a visible window for
# `steam://rungameid/<id>`, plus fake library manifests. No Steam code, so this is freely
# redistributable (unlike the real thing).
{
  lib,
  writeShellApplication,
  symlinkJoin,
  runCommand,
  xterm,
  coreutils,
  util-linux,
  bash,
  hinteros-session,
}:
let
  # (appid, name) pairs for the fake library.
  games = {
    "1000001" = "Fake Platformer";
    "1000002" = "Fake Racer";
    "1000003" = "Fake Puzzle";
  };

  library = runCommand "hinteros-fake-steam-library" { } ''
    dir=$out/share/hinteros-fake-steam/steamapps
    mkdir -p "$dir"
    ${lib.concatStrings (
      lib.mapAttrsToList (id: name: ''
        cat > "$dir/appmanifest_${id}.acf" <<'ACF'
        "AppState"
        {
        	"appid"		"${id}"
        	"name"		"${name}"
        	"installdir"		"${name}"
        	"StateFlags"		"4"
        	"SizeOnDisk"		"1048576"
        	"LastUpdated"		"1700000000"
        }
        ACF
      '') games
    )}
  '';

  stub = writeShellApplication {
    name = "steam";
    runtimeInputs = [
      hinteros-session
      xterm
      coreutils
      util-linux
      bash
    ];
    text = ''
      log="''${XDG_RUNTIME_DIR:-/tmp}/fake-steam.log"
      echo "argv: $*" >> "$log"
      for arg in "$@"; do
        case "$arg" in
          steam://rungameid/*)
            id="''${arg#steam://rungameid/}"
            echo "launch: $id" >> "$log"
            # Detached, like a game started by the running Steam client, and under the reaper
            # as Steam does, so gamescope gives the window the Steam app id (needed to focus it).
            setsid hinteros-session reaper SteamLaunch "AppId=$id" -- \
              xterm -fullscreen -bg black -fg white -fa Monospace -fs 40 -title "Fake game $id" \
              -e sh -c "echo; echo '  Fake game $id'; echo; exec sleep infinity" \
              >>"$log" 2>&1 &
            ;;
        esac
      done
    '';
  };
in
symlinkJoin {
  name = "hinteros-fake-steam";
  paths = [
    stub
    library
  ];
  meta = {
    description = "Stub steam binary and fake library manifests for VM tests";
    mainProgram = "steam";
    license = lib.licenses.gpl3Only;
  };
}
