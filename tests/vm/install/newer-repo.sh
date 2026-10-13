# Builds the channel repository install-newer serves: newer-repo.sh OUT SRC VERSION NEWER NEWEST
# SRC is this repo's source (the test installer's tree), VERSION its release/version, NEWER and
# NEWEST the versions of the newer releases. Writes:
#   OUT/hinteros.git   bare repo, branches stable (= newer) and beta (= iso), plus one branch per commit
#   OUT/revs.json      the commit ids (below)
#   OUT/release.pub    the throwaway release key the test installer trusts ("other" is not trusted)
#
#   base ── iso ──┬── newer (signed) ── newest (signed)
#     │           ├── unsigned
#     │           └── other (signed by an untrusted key)
#     └── notff (signed, but not on top of iso)
set -euo pipefail
out=$1
src=$2
version=$3
newer_version=$4
newest_version=$5

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
mkdir -p "$work"
cp -r "$src"/. "$work"/
chmod -R u+w "$work"
cd "$work"
git init -q -b main
git add -A
git commit -q -m "base"
base=$(git rev-parse HEAD)
git commit -q --allow-empty -m "the installer's revision"
iso=$(git rev-parse HEAD)
[ "$(cat release/version)" = "$version" ]

# commit KEY|"" VERSION MESSAGE: release/version set to VERSION, signed with KEY (if any).
commit() {
  echo "$2" >release/version
  if [ -n "$1" ]; then
    git -c gpg.format=ssh -c "user.signingKey=$keys/$1" commit -q -S -a -m "$3"
  else
    git commit -q -a -m "$3"
  fi
  git rev-parse HEAD
}
git checkout -q -b newer "$iso"
newer=$(commit release "$newer_version" "Release $newer_version")
newest=$(commit release "$newest_version" "Release $newest_version")
git checkout -q -b unsigned "$iso"
unsigned=$(commit "" "$newer_version" "Unsigned $newer_version")
git checkout -q -b other "$iso"
other=$(commit other "$newer_version" "Signed by another key")
git checkout -q -b notff "$base"
notff=$(commit release "$newer_version" "Not on top of the installer's revision")
git branch -q -f iso "$iso"
git branch -q -f stable "$newer"
git branch -q -f beta "$iso"

git clone -q --bare . "$out/hinteros.git"
cat >"$out/revs.json" <<EOF
{"base": "$base", "iso": "$iso", "newer": "$newer", "newest": "$newest", "unsigned": "$unsigned", "other": "$other", "notff": "$notff"}
EOF
