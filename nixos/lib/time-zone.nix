# The one rule for a time zone name in state.json `settings.timeZone` (time-zone.md): one or more
# `/`-separated parts that each start with a capital letter (this keeps out `..`, absolute paths
# and tzdata's other files: `posix/`, `right/`, `zone1970.tab`, `tzdata.zi`, ...), naming a file
# of tzdata's zoneinfo. state.nix checks it at evaluation (`wellFormed` must hold; `ok`, which
# reads tzdata, is built or substituted first, only warns: a newer release's tzdata may know a
# zone this one does not); time-zone.nix checks the same at activation (`pattern`, and the file
# under /etc/zoneinfo, which is this tzdata) and uses UTC otherwise.
{ pkgs }:
rec {
  pattern = "[A-Z][A-Za-z0-9_+-]*(/[A-Z][A-Za-z0-9_+-]*)*";
  zoneinfo = "${pkgs.tzdata}/share/zoneinfo";
  # The directory of the zone link (hinteros-system's `--localtime` default is its `localtime`):
  # /etc/localtime points at that link, which points at /etc/zoneinfo/<zone>. time-zone.nix makes
  # both; hinteros-time-zone-apply (daemon.nix) may write only this directory and /etc/hinteros.
  linkDir = "/etc/hinteros-time-zone";
  wellFormed = zone: builtins.isString zone && builtins.match pattern zone != null;
  ok =
    zone:
    wellFormed zone
    && builtins.pathExists "${zoneinfo}/${zone}"
    && builtins.readFileType "${zoneinfo}/${zone}" == "regular";
}
