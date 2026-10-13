# `hinteros.update.allowedSigners` entries ("<principal> ssh-ed25519 <key> [comment]") as the lines
# of an ssh-keygen allowed_signers file (git's gpg.ssh.allowedSignersFile). The namespace is
# pinned, so these keys can only vouch for git commits. Shared by every generation's update policy
# (nixos/modules/daemon.nix) and by the installer's check for a newer release (nixos/installer).
{ lib }:
let
  signerLine =
    l:
    let
      m = builtins.match "([^ #]+) (ssh-ed25519 [A-Za-z0-9+/=]+( .*)?)" l;
    in
    if m == null then
      throw "hinteros.update.allowedSigners: \"${l}\" is not \"<principal> ssh-ed25519 <key> [comment]\""
    else
      ''${builtins.elemAt m 0} namespaces="git" ${builtins.elemAt m 1}'';
in
entries: lib.concatMapStringsSep "\n" signerLine entries
