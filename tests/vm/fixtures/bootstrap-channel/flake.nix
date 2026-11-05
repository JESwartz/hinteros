# The box's /etc/hinteros/flake.nix in tests/vm/bootstrap-channel.nix: it follows the channel repo
# in the VM, and its "system" is the locked rev's source itself, so nothing is built and nothing
# needs nixpkgs or the network. Its switch-to-configuration is the rev's own
# bin/switch-to-configuration.
{
  inputs.hinteros.url = "git+file:///srv/channel.git?ref=stable";
  outputs =
    { hinteros, ... }:
    {
      nixosConfigurations.hinteros.config.system.build.toplevel = "${hinteros}";
    };
}
