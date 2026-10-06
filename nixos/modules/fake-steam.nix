# Test aid: puts the fake `steam` stub on PATH and installs the fake library manifests for
# the session user. Never enabled on real devices.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hinteros.fakeSteam;
  user = config.hinteros.session.user;
  home = config.users.users.${user}.home;
  steamapps = "${home}/.local/share/Steam/steamapps";
in
{
  options.hinteros.fakeSteam.enable = lib.mkEnableOption "the fake Steam (stub binary and library manifests, for tests)";

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.hinteros-fake-steam ];
    systemd.tmpfiles.rules = [
      "d ${home}/.local 0755 ${user} users -"
      "d ${home}/.local/share 0755 ${user} users -"
      "d ${home}/.local/share/Steam 0755 ${user} users -"
      "C+ ${steamapps} 0755 ${user} users - ${pkgs.hinteros-fake-steam}/share/hinteros-fake-steam/steamapps"
      "Z ${steamapps} 0755 ${user} users -"
    ];
  };
}
