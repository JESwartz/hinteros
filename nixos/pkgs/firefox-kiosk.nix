# hinteros-firefox-kiosk [--user-agent UA] [--no-kiosk] <name> <url>
#
# Runs Firefox with its own profile per app (so logins, cookies and the Widevine CDM stay
# separate): $XDG_DATA_HOME/hinteros/firefox/<name>. Enterprise policies (no first run, no
# telemetry, DRM, VA-API ...) come from the Firefox package's policies.json (see
# nixos/modules/firefox-kiosk.nix); the only per-profile setting is the User-Agent override,
# written to the profile's user.js.
#
# Firefox runs on Xwayland (MOZ_ENABLE_WAYLAND=0): native-Wayland Firefox hung or crashed under
# gamescope and in VMs (hinteros-docs spikes/05-on-screen-keyboard.md).
{
  lib,
  writeShellApplication,
  firefox,
}:
writeShellApplication {
  name = "hinteros-firefox-kiosk";
  meta.mainProgram = "hinteros-firefox-kiosk";
  text = ''
    usage() {
      echo "usage: hinteros-firefox-kiosk [--user-agent UA] [--no-kiosk] <name> <url>" >&2
      exit 2
    }

    ua=""
    kiosk=1
    while [ $# -gt 0 ]; do
      case "$1" in
        --user-agent) [ $# -ge 2 ] || usage; ua="$2"; shift 2 ;;
        --no-kiosk) kiosk=0; shift ;;
        --) shift; break ;;
        -*) usage ;;
        *) break ;;
      esac
    done
    [ $# -eq 2 ] || usage
    name="$1"
    url="$2"
    case "$name" in
      *[!a-z0-9._-]* | "" | .*) echo "invalid profile name: $name" >&2; exit 2 ;;
    esac

    profile="''${XDG_DATA_HOME:-$HOME/.local/share}/hinteros/firefox/$name"
    mkdir -p "$profile"

    # user.js is re-read on every start, so a changed (or removed) override takes effect.
    userjs="$profile/user.js"
    : > "$userjs"
    if [ -n "$ua" ]; then
      esc=''${ua//\\/\\\\}
      esc=''${esc//\"/\\\"}
      printf 'user_pref("general.useragent.override", "%s");\n' "$esc" >> "$userjs"
    fi

    export MOZ_ENABLE_WAYLAND=0
    args=(--no-remote --profile "$profile")
    [ "$kiosk" = 1 ] && args+=(--kiosk)
    exec ${lib.getExe firefox} "''${args[@]}" "$url"
  '';
}
