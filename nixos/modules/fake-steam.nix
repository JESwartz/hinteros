# Test aid: puts the fake `steam` stub on PATH and installs a fake Steam home (library,
# manifests, artwork) for the session user, which the daemon reads through `steam.dir`.
# Never enabled on real devices (asserted).
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
  steamDir = "${home}/.local/share/Steam";
  # libraryfolders.vdf names the Steam directory by absolute path, so build for this home.
  fakeSteam = pkgs.hinteros-fake-steam.override { homeDir = home; };
in
{
  options.hinteros.fakeSteam.enable = lib.mkEnableOption "the fake Steam (stub binary and Steam home, for tests)";

  config = lib.mkIf cfg.enable {
    # Never on a device built from state.json (mkDevice) or on the installer's disk layout: the
    # stub would replace Steam and the tmpfiles rules below take over the real Steam home.
    assertions = [
      {
        assertion = (config.hinteros.state or null) == null && !(config.hinteros.disk.enable or false);
        message = "hinteros.fakeSteam is a test aid; never enable it on a real device.";
      }
    ];
    environment.systemPackages = [ fakeSteam ];
    hinteros.daemon.session.settings.steam = {
      # The daemon launches games and Big Picture through this stub instead of the real Steam.
      path = lib.getExe fakeSteam;
      dir = steamDir;
    };
    systemd.tmpfiles.rules = [
      "d ${home}/.local 0755 ${user} users -"
      "d ${home}/.local/share 0755 ${user} users -"
      "C+ ${steamDir} 0755 ${user} users - ${fakeSteam}/share/hinteros-fake-steam/home/.local/share/Steam"
      "Z ${steamDir} 0755 ${user} users -"
    ];
  };
}
