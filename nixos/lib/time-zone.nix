# The one rule for a time zone name in state.json `settings.timeZone` (time-zone.md): one or more
# `/`-separated parts that each start with a capital letter (this keeps out `..`, absolute paths
# and tzdata's other files: `posix/`, `right/`, `zone1970.tab`, `tzdata.zi`, ...), naming a file
# of tzdata's zoneinfo. state.nix checks it at evaluation (`ok`, which reads tzdata: it is built
# or substituted first); time-zone.nix checks the same at activation (`pattern`, and the file
# under /etc/zoneinfo, which is this tzdata).
{ pkgs }:
rec {
  pattern = "[A-Z][A-Za-z0-9_+-]*(/[A-Z][A-Za-z0-9_+-]*)*";
  zoneinfo = "${pkgs.tzdata}/share/zoneinfo";
  ok =
    zone:
    builtins.isString zone
    && builtins.match pattern zone != null
    && builtins.pathExists "${zoneinfo}/${zone}"
    && builtins.readFileType "${zoneinfo}/${zone}" == "regular";
}
