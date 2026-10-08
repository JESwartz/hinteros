# `nix run .#promote -- beta|stable|hotfix <branch> ...`: see promote.sh.
{
  writeShellApplication,
  git,
  openssh,
  curl,
  jq,
  coreutils,
  gnused,
  gnugrep,
  gawk,
}:
writeShellApplication {
  name = "promote";
  runtimeInputs = [
    git
    openssh
    curl
    jq
    coreutils
    gnused
    gnugrep
    gawk
  ];
  text = builtins.readFile ./promote.sh;
  meta.description = "Sign and move the HinterOS beta and stable channels";
}
