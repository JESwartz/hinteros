# hinteros-bootstrap-channel: see hinteros-bootstrap-channel.sh. Shipped on every device
# (daemon.nix) for the admin account (sudo).
{
  writeShellApplication,
  gitMinimal,
  openssh,
  jq,
  coreutils,
  gnugrep,
  gnused,
  nix,
}:
writeShellApplication {
  name = "hinteros-bootstrap-channel";
  runtimeInputs = [
    gitMinimal
    openssh
    jq
    coreutils
    gnugrep
    gnused
    nix
  ];
  text = builtins.readFile ./hinteros-bootstrap-channel.sh;
  meta.description = "Move a HinterOS box onto a channel at a signed revision, outside the update UI";
}
