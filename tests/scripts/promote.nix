# The promote script (scripts/promote.sh) against a temporary bare repo with throwaway keys and
# a stubbed Forgejo status API: see promote.sh next to this file. No VM, no network.
{ self, pkgs }:
pkgs.runCommand "hinteros-promote-test"
  {
    nativeBuildInputs = [
      self.packages.${pkgs.stdenv.hostPlatform.system}.promote
      pkgs.git
      pkgs.openssh
      pkgs.jq
      pkgs.util-linux # script: promote on a terminal, for the menus
    ];
  }
  ''
    PROMOTE=promote bash ${./promote.sh}
    touch $out
  ''
