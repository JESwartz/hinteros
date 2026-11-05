# hinteros-bootstrap-channel: see hinteros-bootstrap-channel.sh. Shipped on every device
# (daemon.nix) for the admin account (sudo).
# testHooks = true only for tests/vm/bootstrap-channel.nix: it turns on the script's test hooks
# (other config, policy and profile paths, answers from a file, file:/// repos). A box's build
# never has them.
{
  lib,
  writeShellApplication,
  gitMinimal,
  openssh,
  jq,
  coreutils,
  gnugrep,
  gnused,
  nix,
  testHooks ? false,
}:
let
  script = builtins.readFile ./hinteros-bootstrap-channel.sh;
in
assert lib.hasInfix "\ntest_hooks=@testHooks@\n" script;
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
  text =
    builtins.replaceStrings
      [ "\ntest_hooks=@testHooks@\n" ]
      [ "\ntest_hooks=${if testHooks then "1" else "0"}\n" ]
      script;
  meta.description = "Move a HinterOS box onto a channel at a signed revision, outside the update UI";
}
