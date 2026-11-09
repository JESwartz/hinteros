#!/usr/bin/env bash
# Builds the channel repository system-update serves: update-repo.sh OUT URL STATE
# URL is where the box finds the repo (file:///srv/hinteros.git), STATE the box's state.json.
# The repo holds a tiny flake (lib.catalogIds, no inputs: the job's `nix flake lock` and catalog
# evaluation need nothing else) and release/version. Writes:
#   OUT/hinteros.git    bare repo: stable = base, beta = cur, and a branch t/<name> per commit
#   OUT/revs.json       the commit ids (below)
#   OUT/release.pub     the throwaway release key the box trusts ("other" is not trusted)
#   OUT/config/         the box's /etc/hinteros: on beta, locked at cur
#   OUT/config-beta/    flake.nix and state.json of a system built from beta (the update)
#   OUT/config-stable/  the same after channel.set stable (flake.nix retargeted)
#
#   base (1.0.0, stable) ── cur (1.0.1, the box) ──┬── newer (1.0.2, Security: high)
#     │                                            ├── unsigned
#     │                                            ├── other (signed by an untrusted key)
#     │                                            └── badsig (newer's signature on other content)
#     └── notff (signed, not on top of cur)
set -euo pipefail
out=$1
url=$2
state=$3

export HOME=$PWD GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@hinteros.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@hinteros.invalid
export GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" GIT_COMMITTER_DATE="2026-01-01T00:00:00Z"

keys=$PWD/keys
mkdir -p "$keys" "$out"
ssh-keygen -q -t ed25519 -N "" -C test-release -f "$keys/release"
ssh-keygen -q -t ed25519 -N "" -C test-other -f "$keys/other"
cp "$keys/release.pub" "$out/release.pub"

work=$PWD/work
mkdir -p "$work/release"
cd "$work"
git init -q -b main
cat >flake.nix <<'EOF'
{
  outputs = _: { lib.catalogIds = { }; };
}
EOF
git add flake.nix

# commit KEY|"" VERSION MESSAGE: release/version set to VERSION, signed with KEY (if any).
commit() {
  echo "$2" >release/version
  git add release/version
  if [ -n "$1" ]; then
    git -c gpg.format=ssh -c "user.signingKey=$keys/$1" commit -q -S -m "$3"
  else
    git commit -q -m "$3"
  fi
  git rev-parse HEAD
}
base=$(commit release 1.0.0 "Release 1.0.0")
cur=$(commit release 1.0.1 "Release 1.0.1")
newer=$(commit release 1.0.2 "$(printf 'Release 1.0.2\n\nSecurity: high\nSecurity-Summary: Test fix.')")
git checkout -q --detach "$cur"
unsigned=$(commit "" 1.0.2 "Unsigned 1.0.2")
git checkout -q --detach "$cur"
other=$(commit other 1.0.2 "Signed by another key")
git checkout -q --detach "$base"
notff=$(commit release 1.0.2 "Not on top of 1.0.1")
# newer's signature on another subject: the signature no longer matches the commit.
badsig=$(git cat-file commit "$newer" | sed 's/^Release 1\.0\.2$/Release 1.0.3/' | git hash-object -t commit -w --stdin)
[ "$badsig" != "$newer" ]
for name in base cur newer unsigned other notff badsig; do
  git branch -q -f "t/$name" "${!name}"
done
git branch -q -f stable "$base"
git branch -q -f beta "$cur"
git clone -q --bare . "$out/hinteros.git"
cat >"$out/revs.json" <<EOF
{"base": "$base", "cur": "$cur", "newer": "$newer", "unsigned": "$unsigned", "other": "$other", "notff": "$notff", "badsig": "$badsig"}
EOF

# The device config: the input line names the channel, flake.lock locks cur as nix would.
device_flake() {
  cat <<EOF
# The device flake of system-update (never evaluated: the build is a stub).
{
  inputs.hinteros.url = "git+$url?ref=$1";
  outputs = _: { };
}
EOF
}
tree=$PWD/tree
mkdir "$tree"
git archive "$cur" | tar -x -C "$tree"
mkdir "$out/config" "$out/config-beta" "$out/config-stable"
device_flake beta >"$out/config/flake.nix"
jq -n --arg rev "$cur" --arg url "$url" --arg nar "$(nix-hash --type sha256 --sri "$tree")" \
  --argjson count "$(git rev-list --count "$cur")" --argjson time "$(git log -1 --format=%ct "$cur")" '
  {nodes: {hinteros: {locked: {lastModified: $time, narHash: $nar, ref: "beta", rev: $rev,
                               revCount: $count, type: "git", url: $url},
                      original: {ref: "beta", type: "git", url: $url}},
           root: {inputs: {hinteros: "hinteros"}}},
   root: "root", version: 7}' >"$out/config/flake.lock"
# The systems the stub "builds" have no flake.lock in their snapshot: the lock the job writes
# (narHash and all) is not known when the VM is built. So no job takes it back.
device_flake beta >"$out/config-beta/flake.nix"
device_flake stable >"$out/config-stable/flake.nix"
for d in config config-beta config-stable; do
  cp "$state" "$out/$d/state.json"
done
