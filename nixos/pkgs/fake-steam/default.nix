# Fake Steam for tests: a `steam` stub that records its argv and shows visible windows, plus
# a fake Steam home modelled on the daemon's fixtures (libraryfolders.vdf, app manifests
# including tools that games.list must filter out, librarycache artwork). No Steam code, so
# this is freely redistributable (unlike the real thing).
#
# The stub understands: `-silent` (starts a long-lived stand-in "steam" client process, so the
# daemon sees Steam running), `-gamepadui` and `steam://open/bigpicture` (a "Fake Big Picture"
# window that looks like Steam's to the daemon: WM_CLASS steam/Steam), `steam://close/bigpicture`,
# `-shutdown` (Big Picture and the stand-in client exit), `steam://rungameid/<id>` (a "Fake
# game <id>" window under the reaper, like a real game) and
# `--hinteros-fake-popup <title>` (a Steam-style dialog window, e.g. "Steam Guard").
{
  lib,
  writeShellApplication,
  symlinkJoin,
  runCommand,
  xterm,
  coreutils,
  util-linux,
  bash,
  imagemagick,
  hinteros-session,
  # Home directory of the session user; libraryfolders.vdf names the Steam directory by
  # absolute path, as real Steam does.
  homeDir ? "/home/hinteros-p1",
}:
let
  steamDir = "${homeDir}/.local/share/Steam";

  # Installed games: appid -> name.
  games = {
    "1000001" = "Fake Platformer";
    "1000002" = "Fake Racer";
    "1000003" = "Fake Puzzle";
  };
  # Tools, which games.list leaves out (known ids: redistributables, Proton, Linux runtime).
  tools = {
    "228980" = "Steamworks Common Redistributables";
    "1493710" = "Proton Experimental";
    "1628350" = "Steam Linux Runtime 3.0 (sniper)";
  };
  allApps = games // tools;

  manifest = id: name: ''
    "AppState"
    {
      "appid"    "${id}"
      "Universe"    "1"
      "name"    "${name}"
      "StateFlags"    "4"
      "installdir"    "${name}"
      "LastUpdated"    "1788166757"
      "LastPlayed"    "${if games ? ${id} then "1786300589" else "0"}"
      "SizeOnDisk"    "1048576"
      "buildid"    "24893155"
      "InstalledDepots"
      {
      }
      "UserConfig"
      {
        "language"    "english"
      }
    }
  '';

  libraryFolders = ''
    "libraryfolders"
    {
      "0"
      {
        "path"    "${steamDir}"
        "label"    ""
        "contentid"    "6409048248388315076"
        "totalsize"    "0"
        "apps"
        {
    ${
      lib.concatStrings (lib.mapAttrsToList (id: _: "              \"${id}\"  \"1048576\"\n") allApps)
    }        }
      }
    }
  '';

  home = runCommand "hinteros-fake-steam-home" { nativeBuildInputs = [ imagemagick ]; } ''
    steam=$out/share/hinteros-fake-steam/home/.local/share/Steam
    apps=$steam/steamapps
    cache=$steam/appcache/librarycache
    mkdir -p "$apps" "$cache"
    cat > "$apps/libraryfolders.vdf" <<'VDF'
    ${libraryFolders}
    VDF
    ${lib.concatStrings (
      lib.mapAttrsToList (id: name: ''
        cat > "$apps/appmanifest_${id}.acf" <<'ACF'
        ${manifest id name}
        ACF
      '') allApps
    )}
    # Artwork in the current librarycache layout: <appid>/<sha1>/library_*.jpg, plus the
    # flat <appid>/library_600x900.jpg that Steam keeps for portraits.
    ${lib.concatStrings (
      lib.mapAttrsToList (id: _: ''
        mkdir -p "$cache/${id}/b21199296d8ca5aff27b5b3b33c00aa9e3d7518b" "$cache/${id}/74d59d9f11bd9a2516106cb5522107cfcce0240f"
        magick -size 600x900 xc:navy "$cache/${id}/library_600x900.jpg"
        magick -size 460x215 xc:darkgreen "$cache/${id}/74d59d9f11bd9a2516106cb5522107cfcce0240f/library_header.jpg"
        magick -size 1920x620 xc:darkred "$cache/${id}/b21199296d8ca5aff27b5b3b33c00aa9e3d7518b/library_hero.jpg"
      '') games
    )}
  '';

  # An executable named `steam` that just sleeps: the daemon looks for a process with that
  # name to tell whether a Steam client is running.
  client = runCommand "hinteros-fake-steam-client" { } ''
    mkdir -p $out/libexec
    ln -s ${coreutils}/bin/sleep $out/libexec/steam
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
      run="''${XDG_RUNTIME_DIR:-/tmp}"
      log="$run/fake-steam.log"
      echo "argv: $*" >> "$log"

      # A Steam-style window: WM_CLASS steam/Steam, which is how the daemon recognises Steam's.
      steam_window() { # title, text, extra xterm args...
        local title="$1" text="$2"
        shift 2
        setsid xterm -name steam -class Steam -bg black -fg white -fa Monospace -fs 32 \
          -title "$title" "$@" \
          -e sh -c "echo; echo '  $text'; echo; exec sleep infinity" >>"$log" 2>&1 &
        echo $! > "$run/fake-steam-$$.pid"
      }

      open_bigpicture() {
        if [ -s "$run/fake-steam-bigpicture.pid" ] && kill -0 "$(cat "$run/fake-steam-bigpicture.pid")" 2>/dev/null; then
          return
        fi
        echo "bigpicture: open" >> "$log"
        steam_window "Fake Big Picture" "Fake Big Picture" -fullscreen
        mv "$run/fake-steam-$$.pid" "$run/fake-steam-bigpicture.pid"
      }

      while [ $# -gt 0 ]; do
        arg="$1"
        shift
        case "$arg" in
          -silent)
            if ! { [ -s "$run/fake-steam-client.pid" ] && kill -0 "$(cat "$run/fake-steam-client.pid")" 2>/dev/null; }; then
              setsid ${client}/libexec/steam infinity >/dev/null 2>&1 &
              echo $! > "$run/fake-steam-client.pid"
            fi
            ;;
          -gamepadui | steam://open/bigpicture) open_bigpicture ;;
          steam://close/bigpicture)
            echo "bigpicture: close" >> "$log"
            if [ -s "$run/fake-steam-bigpicture.pid" ]; then
              kill "$(cat "$run/fake-steam-bigpicture.pid")" 2>/dev/null || true
              rm -f "$run/fake-steam-bigpicture.pid"
            fi
            ;;
          -shutdown)
            # Steam exits: Big Picture and the stand-in client go.
            echo "shutdown" >> "$log"
            for p in bigpicture client; do
              if [ -s "$run/fake-steam-$p.pid" ]; then
                kill "$(cat "$run/fake-steam-$p.pid")" 2>/dev/null || true
                rm -f "$run/fake-steam-$p.pid"
              fi
            done
            ;;
          --hinteros-fake-popup)
            title="''${1:-Steam Guard}"
            shift || true
            echo "popup: $title" >> "$log"
            steam_window "$title" "$title" -geometry 40x8
            rm -f "$run/fake-steam-$$.pid"
            ;;
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
    home
  ];
  meta = {
    description = "Stub steam binary and fake Steam home (library, manifests, artwork) for VM tests";
    mainProgram = "steam";
    license = lib.licenses.gpl3Only;
  };
}
