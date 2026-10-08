# The installer as a VM test node: the real installer module (hinteros-install, the offline
# closure, flakes) without the ISO image bits, on a VM with NO network (no vlans), so every
# install here is an offline install from the node's own store. Shared by install-offline and
# install-validation.
{
  self,
  pkgs,
  # Only the installer's own store, like the ISO. A NixOS test VM shares the HOST's /nix/store by
  # default, which hid for a long time that an offline install needs build-time inputs (bash and
  # friends) the ISO did not carry. With this the store is an image of this node's closure and the
  # VM has no network, so nothing missing can be found elsewhere. The image is a drive: the install
  # target is then /dev/vdc instead of /dev/vdb.
  isolatedStore ? false,
}:
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
    mountHostNixStore = !isolatedStore;
    useNixStoreImage = isolatedStore;
    writableStore = true;
    # No network interface at all (a NixOS test VM otherwise has a user-mode eth0). With only `lo`
    # nix decides "you don't have Internet access" and turns substitution OFF, even from the local
    # store, which is what the ISO sees without a cable; the tests used to hide that.
    qemu.networkingOptions = lib.mkIf isolatedStore (lib.mkForce [ "-nic none" ]);
    memorySize = 6144;
    cores = 4;
    # The install target (vdb).
    emptyDiskImages = [ 20480 ];
  };

  # What the tests themselves run in the node.
  environment.systemPackages = [
    pkgs.util-linux
    pkgs.parted
    pkgs.dosfstools
    pkgs.e2fsprogs
  ];

  # The installer VM's own ssh etc. are irrelevant.
  networking.hostName = lib.mkForce "installer";
  system.stateVersion = "25.11";
}
