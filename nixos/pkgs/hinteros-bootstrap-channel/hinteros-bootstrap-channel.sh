# hinteros-bootstrap-channel [--allow-downgrade] <stable|beta> <rev>: move this box onto a channel
# at a given signed revision, outside the update UI.
# For a box whose running generation does not trust the release key yet (installed before the
# first signed release) and for boxes whose update keys are out of date. Run as root (sudo) over
# SSH by the owner, with the rev `promote` printed. Never back: a rev that does not descend from
# the box's current one (its system may not read the state a newer one wrote) needs
# --allow-downgrade.
#
# It does what the privileged service's update apply does: verify the rev, stage a copy of
# /etc/hinteros, point flake.nix's hinteros input at the channel, lock it to the rev
# (`nix flake lock --override-input hinteros git+<repo>?ref=<branch>&rev=<rev>`), build, switch,
# and only then replace /etc/hinteros with the staged copy.
#
# Test hooks (tests/vm/bootstrap-channel.nix), only in the build with testHooks = true
# (default.nix). A box's build has test_hooks=0 and ignores them all: HINTEROS_CONFIG_DIR,
# HINTEROS_POLICY_DIR and HINTEROS_SYSTEM_PROFILE replace /etc/hinteros, the running generation's
# share/hinteros and the system profile; the answers come from HINTEROS_TTY instead of /dev/tty;
# and the repo may also be a file:/// URL. The root check has no hook (the test runs as root).
test_hooks=@testHooks@

usage() {
  echo "usage: sudo hinteros-bootstrap-channel [--allow-downgrade] <stable|beta> <rev>" >&2
  exit 2
}
die() {
  printf 'hinteros-bootstrap-channel: %s\n' "$*" >&2
  exit 1
}
info() { printf '  %s\n' "$*"; }
# ask <prompt>: one line from the terminal into $ans (empty at the end of input).
ask() {
  if ! { true <&3; } 2>/dev/null; then
    exec 3<"$tty" || die "cannot read from $tty: run it in a terminal"
  fi
  read -r -p "$1" ans <&3 || ans=
}

allow_downgrade=0
if [ "${1:-}" = --allow-downgrade ]; then
  allow_downgrade=1
  shift
fi
[ "$#" -eq 2 ] || usage
channel=$1
rev=$2
case "$channel" in stable | beta) ;; *) usage ;; esac
[[ $rev =~ ^[0-9a-f]{40}$ ]] || die "the rev must be a full 40-character commit hash (as promote prints it)"
[ "$(id -u)" = 0 ] || die "run it as root: sudo hinteros-bootstrap-channel $channel $rev"

dir=/etc/hinteros
policy=/run/current-system/sw/share/hinteros
profile=/nix/var/nix/profiles/system
tty=/dev/tty
repo_re='^https://[^?#" ]+$'
if [ "$test_hooks" = 1 ]; then
  dir=${HINTEROS_CONFIG_DIR:-$dir}
  policy=${HINTEROS_POLICY_DIR:-$policy}
  profile=${HINTEROS_SYSTEM_PROFILE:-$profile}
  tty=${HINTEROS_TTY:-$tty}
  repo_re='^(https://|file:///)[^?#" ]+$'
fi
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
[[ $repo =~ $repo_re ]] || die "unexpected repo URL in channels.json: $repo"
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
echo "Fetching the channel branches ..."
git -C "$tmp" init -q
git -C "$tmp" fetch -q "$repo" "refs/heads/$branch:refs/remotes/origin/$branch" \
  || die "could not fetch $branch from $repo"
# The other channels too, to tell whether the target follows this box's revision.
while IFS= read -r b; do
  if [ "$b" = "$branch" ] || ! [[ $b =~ ^[A-Za-z0-9._/-]+$ ]]; then continue; fi
  git -C "$tmp" fetch -q "$repo" "refs/heads/$b:refs/remotes/origin/$b" 2>/dev/null || true
done < <(jq -r '.branches[] | strings' "$policy/update/channels.json")
git -C "$tmp" cat-file -e "$rev^{commit}" 2>/dev/null || die "$rev is not on $branch"
tip=$(git -C "$tmp" rev-parse "refs/remotes/origin/$branch")
git -C "$tmp" merge-base --is-ancestor "$rev" "$tip" || die "$rev is not on $branch"
[ "$rev" = "$tip" ] || info "note: $rev is not the tip of $branch (the tip is $tip)"
# Never back (as the update UI): a system older than the one that wrote the box's state may not
# read it. A rev that does not descend from this box's revision needs --allow-downgrade.
if [ -n "$cur_rev" ] && git -C "$tmp" cat-file -e "$cur_rev^{commit}" 2>/dev/null; then
  if [ "$rev" = "$cur_rev" ]; then
    info "note: this box runs $rev already"
  elif ! git -C "$tmp" merge-base --is-ancestor "$cur_rev" "$rev"; then
    [ "$allow_downgrade" = 1 ] \
      || die "$rev does not follow this box's revision $cur_rev (it is older, or on another line). Its system may not read the state the newer one wrote. Nothing changed. To go back anyway, run it again with --allow-downgrade."
    echo "WARNING: $rev does not follow this box's revision $cur_rev (--allow-downgrade)."
  fi
else
  info "note: this box's revision ${cur_rev:-<none>} is on no channel branch; it cannot be checked that $rev follows it"
fi

echo
info "commit:  $rev"
info "subject: $(git -C "$tmp" log -1 --format=%s "$rev")"
info "date:    $(git -C "$tmp" log -1 --format=%cd --date=iso "$rev")"
info "version: $(git -C "$tmp" show "$rev:release/version" 2>/dev/null || echo '<none>')"
echo
echo "Compare the commit above, character by character, with the one promote printed."
ask "Is it the same? [y/N] "
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
  ask "Type 'yes' to trust it: "
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
ask "Build and switch to HinterOS at $rev now? (this takes a while) [y/N] "
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
