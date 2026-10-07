# The installer as a VM test node: the real installer module (hinteros-install, the offline
# closure, flakes) without the ISO image bits, on a VM with NO network (no vlans), so every
# install here is an offline install from the node's own store. Shared by install-offline and
# install-validation.
{ self, pkgs }:
{ lib, ... }:
{
  imports = [
    ../../../nixos/modules # everything but the overlay (the test pkgs already have it)
    self.nixosModules.catalog
    (import ../../../nixos/installer { inherit self; })
  ];

  nix.enable = true;
  virtualisation = {
    vlans = [ ]; # no network at all
    memorySize = 6144;
    cores = 4;
    # The install target (vdb).
    emptyDiskImages = [ 20480 ];
  };

  # What the tests themselves run in the node.
  environment.systemPackages = [
    pkgs.util-linux
    pkgs.parted
    pkgs.e2fsprogs
  ];

  # The installer VM's own ssh etc. are irrelevant.
  networking.hostName = lib.mkForce "installer";
  system.stateVersion = "25.11";
}
