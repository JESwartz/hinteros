# hinteros-install: the installer backend (see hinteros-install.sh). Built for the ISO: it embeds
# the disko script, the offline flake lock and the list of flake input sources of that ISO.
{
  lib,
  stdenvNoCC,
  replaceVars,
  makeWrapper,
  shellcheck,
  bash,
  coreutils,
  util-linux,
  gnugrep,
  gnused,
  gawk,
  findutils,
  diffutils,
  curl,
  jq,
  mkpasswd,
  networkmanager,
  nixos-install,
  nixos-facter,
  systemd,
  nix,
  # Executable that partitions, formats and mounts (at /mnt) the disk /dev/hinteros-target.
  diskoScript,
  # flake.lock for the generated device flake (JSON file) and the store paths it needs.
  offlineLock,
  sourcesFile,
  # The device flake template and the app ids ({onIso, onlineOnly, preselected}).
  template ? ../../templates/device-flake.nix.in,
  appsJson,
  catalogIndex,
  stateVersion,
  repoUrl ? "https://justsomeshed.com/JSwartz/HinterOS/hinteros.git",
  isoRev ? "unknown",
  # The channel of a plan that names none (hinteros.installer.channel).
  defaultChannel ? "stable",
}:
let
  script = replaceVars ./hinteros-install.sh {
    bash = lib.getExe bash;
    template = "${template}";
    inherit
      diskoScript
      offlineLock
      sourcesFile
      appsJson
      catalogIndex
      stateVersion
      repoUrl
      isoRev
      defaultChannel
      ;
  };
in
stdenvNoCC.mkDerivation {
  pname = "hinteros-install";
  version = "0.1";

  dontUnpack = true;
  nativeBuildInputs = [
    makeWrapper
    shellcheck
  ];

  doInstallCheck = true;
  installCheckPhase = ''
    shellcheck -s bash --exclude=SC2154 $out/libexec/hinteros-install
  '';

  installPhase = ''
    install -D -m 0755 ${script} $out/libexec/hinteros-install
    makeWrapper $out/libexec/hinteros-install $out/bin/hinteros-install \
      --prefix PATH : ${
        lib.makeBinPath [
          coreutils
          util-linux
          gnugrep
          gnused
          gawk
          findutils
          diffutils
          curl
          jq
          mkpasswd
          networkmanager
          nixos-install
          nixos-facter
          systemd
          nix
        ]
      }
  '';

  meta = {
    description = "HinterOS installer backend: installs from a JSON plan, reporting JSON progress lines";
    mainProgram = "hinteros-install";
    license = lib.licenses.gpl3Only;
  };
}
