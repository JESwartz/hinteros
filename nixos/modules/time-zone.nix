# The time zone (hinteros-docs/design/time-zone.md). It is imperative: NixOS does not own
# /etc/localtime (`time.timeZone = null`). An activation script points /etc/localtime at
# /etc/zoneinfo/<zone>, with <zone> from `settings.timeZone` of the *live* state.json (read when it
# runs, not at evaluation: hinteros-system changes the zone without a rebuild, so a value baked into
# the generation would undo that on the next boot). Absent, or not a zone of this tzdata: UTC.
# Activation runs at every boot and every switch (also a rollback, which restores state.json),
# so /etc/localtime follows state.json. hinteros-system's `time_zone.set` writes both at once:
# state.json itself, /etc/localtime through systemd-timedated (`SetTimezone`), so its helper unit
# (daemon.nix) needs no write access to /etc beyond /etc/hinteros. /etc/localtime stays one link
# straight at /etc/zoneinfo/<zone>, as timedated writes it: readers that take the zone name from
# that one link (OpenJDK, timedated itself, .NET) need that.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  tz = import ../lib/time-zone.nix { inherit pkgs; };
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
        target="/etc/zoneinfo/$zone"
        # Only when it differs, and atomically: a new link next to it, renamed over it.
        if [ "$(readlink /etc/localtime 2>/dev/null || true)" != "$target" ]; then
          ln -sfn "$target" /etc/.localtime.hinteros-tmp
          mv -fT /etc/.localtime.hinteros-tmp /etc/localtime
        fi
      )
    '';
  };
}
