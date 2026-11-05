# A HinterOS VM (the real daemon module, hardening and session) for the system-service tests:
# /etc/hinteros populated from a fixture that is also the running generation's snapshot, the
# Python clients in /etc/hinteros-test, a second HinterOS user in the hinteros group that does
# not own the seat (`guest`) and one that is not in the group (`stranger`).
{
  self,
  pkgs,
  rateLimits ? false,
  # /etc/hinteros and the generation snapshot: the same file set, so hinteros-config-sync finds
  # nothing to restore.
  fixture ? ../fixtures/system-a,
}:
{ lib, config, ... }:
{
  imports = [
    ../../../nixos/modules # everything but the overlay (the test pkgs already have it)
    self.nixosModules.catalog
    ../../../nixos/vm
  ];

  hinteros.deviceConfig.configDir = fixture;
  systemd.tmpfiles.settings."10-hinteros-config"."/etc/hinteros".C = {
    user = "root";
    group = "root";
    mode = "0755";
    argument = "${fixture}";
  };

  environment.etc."hinteros-test".source = ./client;
  environment.systemPackages = [ pkgs.python3 ];

  users.users = {
    guest = {
      isNormalUser = true;
      extraGroups = [ config.hinteros.daemon.group ];
    };
    stranger.isNormalUser = true;
  };

  # As daemon.nix (--freeze-inactive), plus: the launcher is a client too (the session daemon
  # relays it as the same uid), so a test's own requests share the uid's token bucket with it:
  # tests that need many mutating requests lift the limit; the rate-limit test keeps the defaults.
  # The VM's store sits on a tmpfs and is small: relax the free-space preflight (the test of it
  # is the daemon's own integration tests).
  systemd.services.hinteros-system.serviceConfig.ExecStart = lib.mkForce (
    "${lib.getExe config.hinteros.daemon.system.package} --freeze-inactive --min-memory-bytes 268435456 --min-disk-bytes 1048576"
    + lib.optionalString (!rateLimits) " --rate-burst 100 --rate-per-minute 6000"
  );
}
