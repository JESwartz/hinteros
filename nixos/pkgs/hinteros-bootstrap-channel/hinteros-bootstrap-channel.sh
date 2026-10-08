# hinteros-bootstrap-channel <stable|beta> <rev>: move this box onto a channel at a given signed
# revision, outside the update UI (hinteros-docs/design/distribution.md, "Migration from today").
# For a box whose running generation does not trust the release key yet (installed before the
# first signed release) and for boxes whose update keys are out of date. Run as root (sudo) over
# SSH by the owner, with the rev `promote` printed.
#
# It does what the privileged service's update apply does: verify the rev, stage a copy of
# /etc/hinteros, point flake.nix's hinteros input at the channel, lock it to the rev
# (`nix flake lock --override-input hinteros git+<repo>?ref=<branch>&rev=<rev>`), build, switch,
# and only then replace /etc/hinteros with the staged copy.
#
# HINTEROS_CONFIG_DIR and HINTEROS_POLICY_DIR override /etc/hinteros and the running generation's
# share/hinteros (for tests).

usage() {
  echo "usage: sudo hinteros-bootstrap-channel <stable|beta> <rev>" >&2
  exit 2
}
die() {
  printf 'hinteros-bootstrap-channel: %s\n' "$*" >&2
  exit 1
}
info() { printf '  %s\n' "$*"; }

[ "$#" -eq 2 ] || usage
channel=$1
rev=$2
case "$channel" in stable | beta) ;; *) usage ;; esac
[[ $rev =~ ^[0-9a-f]{40}$ ]] || die "the rev must be a full 40-character commit hash (as promote prints it)"
[ "$(id -u)" = 0 ] || die "run it as root: sudo hinteros-bootstrap-channel $channel $rev"

dir=${HINTEROS_CONFIG_DIR:-/etc/hinteros}
policy=${HINTEROS_POLICY_DIR:-/run/current-system/sw/share/hinteros}
profile=/nix/var/nix/profiles/system
if [ ! -f "$dir/flake.nix" ] || [ ! -f "$dir/flake.lock" ]; then
  die "$dir has no flake.nix/flake.lock: not an installed HinterOS box"
fi
# As the update jobs run: root's home, the system CA bundle for https.
export HOME=/root
export SSL_CERT_FILE=${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}

# The repo and branch come from the RUNNING generation, like the daemon's.
repo=$(jq -er '.repo' "$policy/update/channels.json") || die "cannot read $policy/update/channels.json"
branch=$(jq -er --arg c "$channel" '.branches[$c]' "$policy/update/channels.json") \
  || die "the running generation has no '$channel' channel"
[[ $repo =~ ^https://[^?#\ \"]+$ ]] || die "unexpected repo URL in channels.json: $repo"
[[ $branch =~ ^[A-Za-z0-9._/-]+$ ]] || die "unexpected branch in channels.json: $branch"
signers=$policy/update/allowed_signers

node=$(jq -er '.nodes[.root].inputs.hinteros | strings' "$dir/flake.lock") \
  || die "$dir/flake.lock has no hinteros input"
cur_ref=$(jq -r --arg n "$node" '.nodes[$n].original.ref // ""' "$dir/flake.lock")
cur_rev=$(jq -r --arg n "$node" '.nodes[$n].locked.rev // ""' "$dir/flake.lock")
[ -n "$cur_ref" ] || die "$dir/flake.lock does not name the branch the box follows"

echo "This box: channel '$cur_ref' at ${cur_rev:-<no rev>}."
echo "Target:   channel '$channel' (branch $branch of $repo) at $rev."

tmp=$(mktemp -d)
staging=
cleanup() {
  rm -rf "$tmp"
  [ -z "$staging" ] || rm -rf "$staging"
}
trap cleanup EXIT

echo
echo "Fetching $branch ..."
git -C "$tmp" init -q
git -C "$tmp" fetch -q "$repo" "refs/heads/$branch:refs/remotes/origin/$branch" \
  || die "could not fetch $branch from $repo"
git -C "$tmp" cat-file -e "$rev^{commit}" 2>/dev/null || die "$rev is not on $branch"
tip=$(git -C "$tmp" rev-parse "refs/remotes/origin/$branch")
git -C "$tmp" merge-base --is-ancestor "$rev" "$tip" || die "$rev is not on $branch"
[ "$rev" = "$tip" ] || info "note: $rev is not the tip of $branch (the tip is $tip)"

echo
info "commit:  $rev"
info "subject: $(git -C "$tmp" log -1 --format=%s "$rev")"
info "date:    $(git -C "$tmp" log -1 --format=%cd --date=iso "$rev")"
info "version: $(git -C "$tmp" show "$rev:release/version" 2>/dev/null || echo '<none>')"
echo
echo "Compare the commit above, character by character, with the one promote printed."
read -r -p "Is it the same? [y/N] " ans </dev/tty
case "$ans" in y | Y | yes) ;; *) die "not confirmed; nothing changed" ;; esac

verify() {
  git -C "$tmp" -c gpg.format=ssh -c gpg.ssh.program=ssh-keygen \
    -c "gpg.ssh.allowedSignersFile=$1" verify-commit "$rev" 2>&1
}
echo
if [ -f "$signers" ] && grep -v '^#' "$signers" | grep -q .; then
  if out=$(verify "$signers"); then
    info "signature: $(printf '%s\n' "$out" | grep -m1 -i good)"
    info "(checked against this box's keys, $signers)"
  else
    printf '%s\n' "$out" | sed 's/^/    /'
    die "$rev is not signed by a key this box trusts; nothing changed. If its keys are out of date, use a box image with the current keys or ask the vendor."
  fi
else
  echo "WARNING: this box's running system trusts no release key ($signers lists none),"
  echo "so the signature cannot be checked against anything the box already had."
  if git -C "$tmp" show "$rev:release/allowed_signers" 2>/dev/null \
    | grep -v '^#' | grep . | sed 's/^\([^ ]*\) /\1 namespaces="git" /' >"$tmp/own.signers" \
    && out=$(verify "$tmp/own.signers"); then
    info "for information: it is signed by a key its own release/allowed_signers lists:"
    info "$(printf '%s\n' "$out" | grep -m1 -i good)"
  else
    echo "It is NOT signed by a key its own release lists either."
  fi
  echo "Only continue if the commit matches what promote printed."
  read -r -p "Type 'yes' to trust it: " ans </dev/tty
  [ "$ans" = yes ] || die "not confirmed; nothing changed"
fi

# Stage: a copy of the config dir next to it (same file system, for the final swap).
staging=$(mktemp -d "$(dirname "$dir")/.$(basename "$dir").bootstrap.XXXXXX")
cp -a "$dir"/. "$staging"/
chmod 0755 "$staging"

from="git+$repo?ref=$cur_ref"
to="git+$repo?ref=$branch"
if [ "$from" != "$to" ]; then
  text=$(<"$staging/flake.nix")
  count=$(grep -oF "\"$from\"" "$staging/flake.nix" | wc -l)
  [ "$count" = 1 ] || die "flake.nix does not contain the hinteros input URL $from exactly once (found $count); nothing changed"
  printf '%s\n' "${text/"\"$from\""/"\"$to\""}" >"$staging/flake.nix"
  info "flake.nix: $from -> $to"
fi

nixf=(nix --extra-experimental-features "nix-command flakes")
echo
echo "Locking hinteros to $rev ..."
"${nixf[@]}" flake lock --override-input hinteros "$to&rev=$rev" "path:$staging" \
  || die "nix flake lock failed; nothing changed"
new_rev=$(jq -r --arg n "$(jq -r '.nodes[.root].inputs.hinteros' "$staging/flake.lock")" \
  '.nodes[$n].locked.rev // ""' "$staging/flake.lock")
[ "$new_rev" = "$rev" ] || die "the lock points at '$new_rev', not $rev; nothing changed"

echo
read -r -p "Build and switch to HinterOS at $rev now? (this takes a while) [y/N] " ans </dev/tty
case "$ans" in y | Y | yes) ;; *) die "not switched; nothing changed" ;; esac

echo "Building ..."
toplevel=$("${nixf[@]}" build --no-link --print-out-paths \
  "path:$staging#nixosConfigurations.hinteros.config.system.build.toplevel" | tail -n1) \
  || die "the build failed; nothing changed"
[ -x "$toplevel/bin/switch-to-configuration" ] || die "the build printed no system: $toplevel"

old=$(readlink -f "$profile")
echo "Switching to $toplevel ..."
if ! { nix-env -p "$profile" --set "$toplevel" && "$toplevel/bin/switch-to-configuration" switch; }; then
  echo "Activation failed; restoring the previous system as the boot default." >&2
  nix-env -p "$profile" --set "$old" || true
  "$old/bin/switch-to-configuration" boot || true
  die "activation failed; $dir is unchanged"
fi

# /etc/hinteros now describes the running system.
sync -f "$staging"
mv --exchange -T "$staging" "$dir"
echo
echo "Done: this box follows '$channel' at $rev."
echo "From now on, updates come through Settings -> Updates."
