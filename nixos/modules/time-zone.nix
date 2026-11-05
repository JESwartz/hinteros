# The time zone (hinteros-docs/design/time-zone.md). It is imperative: NixOS does not own
# /etc/localtime (`time.timeZone = null`). /etc/localtime is a fixed link to
# /etc/hinteros-time-zone/localtime, and that link points at /etc/zoneinfo/<zone>. Only the
# second link changes, so hinteros-time-zone-apply (daemon.nix) may write that directory and
# /etc/hinteros, not all of /etc. glibc and ICU follow both links.
#
# An activation script makes both links, with <zone> from `settings.timeZone` of the *live*
# state.json (read when it runs, not at evaluation: hinteros-system changes the zone without a
# rebuild, so a value baked into the generation would undo that on the next boot). Absent, or not
# a zone of this tzdata: UTC. Activation runs at every boot and every switch (also a rollback,
# which restores state.json), so the zone follows state.json, and a /etc/localtime that points
# somewhere else (a box from before the directory, or timedated) is put back.
# hinteros-system's `time_zone.set` writes state.json and the zone link at once.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  tz = import ../lib/time-zone.nix { inherit pkgs; };
  inherit (tz) linkDir;
  stateFile = "${config.hinteros.deviceConfig.dir}/state.json";
in
{
  # A device that sets time.timeZone conflicts here, loudly.
  time.timeZone = null;

  system.activationScripts.hinteros-time-zone = {
    # After /etc/zoneinfo is linked (the `etc` snippet).
    deps = [ "etc" ];
    text = ''
      (
        zone=UTC
        if [ -r ${lib.escapeShellArg stateFile} ]; then
          want=$(${lib.getExe pkgs.jq} -r '.settings.timeZone? // empty | strings' \
            ${lib.escapeShellArg stateFile} 2>/dev/null || true)
          if [ -n "$want" ]; then
            re='^${tz.pattern}$'
            if [[ "$want" =~ $re ]] && [ -f "/etc/zoneinfo/$want" ]; then
              zone=$want
            else
              echo "hinteros-time-zone: unknown time zone in ${stateFile}; using UTC" >&2
            fi
          fi
        fi
        # Each link only when it differs, and atomically: a new link next to it, renamed over it.
        relink() {
          if [ "$(readlink "$2" 2>/dev/null || true)" != "$1" ]; then
            ln -sfn "$1" "$(dirname "$2")/.localtime.hinteros-tmp"
            mv -fT "$(dirname "$2")/.localtime.hinteros-tmp" "$2"
          fi
        }
        # /etc/localtime moves only once the zone link is there.
        install -d -m 0755 -o root -g root ${linkDir} &&
          relink "/etc/zoneinfo/$zone" ${linkDir}/localtime &&
          relink ${linkDir}/localtime /etc/localtime
      )
    '';
  };
}
