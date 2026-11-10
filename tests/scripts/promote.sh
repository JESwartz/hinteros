#!/usr/bin/env bash
# Tests scripts/promote.sh against a temporary bare repo, with throwaway ssh keys generated here
# and a stub for Forgejo's commit-status API (PROMOTE_STATUS_CMD). Nothing leaves the temporary
# directory. Run by the `promote` flake check, or by hand:
#   PROMOTE=/path/to/bin/promote bash tests/scripts/promote.sh
# Needs git, ssh-keygen and jq (and promote's own tools) on PATH.
set -euo pipefail

PROMOTE=${PROMOTE:-promote}
work=$(mktemp -d "${TMPDIR:-/tmp}/promote-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
export HOME=$work/home GIT_CEILING_DIRECTORIES=$work
mkdir -p "$HOME"
unset HINTEROS_RELEASE_KEY PROMOTE_FORGEJO_API PROMOTE_FORGEJO_REPO
git config --global user.name "Test Owner"
git config --global user.email owner@example.invalid
git config --global init.defaultBranch main

n=0
pass() {
  n=$((n + 1))
  echo "ok $n - $*"
}
die() {
  echo "FAIL: $*" >&2
  exit 1
}

# Keys: k1 (the release key from the start), k2 (added later), bad (never listed), nopub (k1-less
# key without a .pub, so promote cannot pre-check it and must catch it at verification).
for k in k1 k2 bad; do ssh-keygen -q -t ed25519 -N '' -C "$k" -f "$work/$k"; done
ssh-keygen -q -t ed25519 -N '' -C nopub -f "$work/nopub" && rm "$work/nopub.pub"
pub() { cut -d' ' -f1,2 "$work/$1.pub"; }

# The CI stub: state from $work/ci (success, pending, failure or none).
echo success >"$work/ci"
# The shebang is this bash (there is no /usr/bin/env in the build sandbox).
printf '#!%s\n' "$BASH" >"$work/status"
cat >>"$work/status" <<'EOF'
s=$(cat "$(dirname "$0")/ci")
if [ "$s" = none ]; then
  echo '{"state":"","sha":"","total_count":0,"statuses":null}'
else
  printf '{"state":"%s","sha":"%s","total_count":1,"statuses":[{"context":"check / check (push)","status":"%s","description":"stub"}]}\n' "$s" "$1" "$s"
fi
EOF
chmod +x "$work/status"
export PROMOTE_STATUS_CMD=$work/status
# The ISO build stub (PROMOTE_ISO_CMD <repo> <rev>): a store-like directory with iso/*.iso.
printf '#!%s\n' "$BASH" >"$work/iso-build"
cat >>"$work/iso-build" <<'EOF'
d=$(dirname "$0")/iso-out/$2
mkdir -p "$d/iso"
printf 'fake iso of %s\n' "$2" >"$d/iso/hinteros-installer.iso"
printf '%s\n' "$d"
EOF
chmod +x "$work/iso-build"
export PROMOTE_ISO_CMD=$work/iso-build
export PROMOTE_REPO_URL=$work/origin.git

git init -q --bare "$work/origin.git"
git clone -q "$work/origin.git" "$work/dev" 2>/dev/null
dev() { git -C "$work/dev" "$@"; }
o() { git -C "$work/origin.git" "$@"; }
cd "$work"
# promote runs in the owner's checkout: $here.
here=$work/dev

# Clones of two flake inputs next to the checkout, as ../hinteros-daemon is on the dev machine.
for r in hinteros-daemon hinteros-launcher; do
  git init -q "$work/$r"
  git -C "$work/$r" commit -q --allow-empty -m "$r start"
done
daemon1=$(git -C "$work/hinteros-daemon" rev-parse HEAD)
launcher1=$(git -C "$work/hinteros-launcher" rev-parse HEAD)
git -C "$work/hinteros-daemon" commit -q --allow-empty -m "Daemon change A"
git -C "$work/hinteros-daemon" commit -q --allow-empty -m "Daemon change B"
daemon2=$(git -C "$work/hinteros-daemon" rev-parse HEAD)
# lock <nixpkgs rev> <daemon rev> <launcher rev>: a flake.lock with these inputs.
lock() {
  printf '{"nodes":{"nixpkgs":{"locked":{"rev":"%s"}},"hinteros-daemon":{"locked":{"rev":"%s"}},"hinteros-launcher":{"locked":{"rev":"%s"}},"root":{}},"root":"root","version":7}\n' \
    "$@" >"$work/dev/flake.lock"
}

# A change on the current branch, noted in the `## Unreleased` section of the release notes
# (started if the top section is a released version). Optional trailer.
change() {
  local what=$1 trailer=${2:-} notes=$work/dev/release/notes.md
  mkdir -p "$work/dev/release"
  echo "$what" >>"$work/dev/file"
  {
    printf '# Release notes\n\n## Unreleased\n\n'
    if [ -f "$notes" ] && [ "$(grep -m1 '^## ' "$notes")" = "## Unreleased" ]; then
      sed -n '/^## Unreleased/,/^## [0-9]/p' "$notes" | sed -e '1d' -e '/^## /d' -e '/^$/d'
      echo "- $what"
      printf '\n'
      sed -n '/^## [0-9]/,$p' "$notes"
    else
      printf -- '- %s\n\n' "$what"
      [ ! -f "$notes" ] || sed -n '/^## /,$p' "$notes"
    fi
  } >"$notes.tmp"
  mv "$notes.tmp" "$notes"
  dev add -A
  if [ -n "$trailer" ]; then
    dev commit -q -m "$what" -m "$trailer"
  else
    dev commit -q -m "$what"
  fi
}
set_version() {
  echo "$1" >"$work/dev/release/version"
  dev commit -q -am "release/version $1"
}
signers() {
  mkdir -p "$work/dev/release"
  {
    echo "# comment line"
    for k in "$@"; do echo "$k $(pub "$k") $k@test"; done
  } >"$work/dev/release/allowed_signers"
}
push() { dev push -q origin "${1:-main}" 2>/dev/null; }
remote() { o rev-parse -q --verify "refs/heads/$1" || true; }
top_heading() { o show "$1:release/notes.md" | grep -m1 '^## '; }

# The same check as a box: verify-commit against <rev>'s release/allowed_signers.
box_verifies() {
  local rev=$1 against=$2
  o show "$against:release/allowed_signers" \
    | grep -v '^#' | sed 's/^\([^ ]*\) /\1 namespaces="git" /' >"$work/box.signers"
  o -c gpg.ssh.allowedSignersFile="$work/box.signers" verify-commit "$rev" 2>/dev/null
}

# PROMOTE_TEST_LOG=<file>: keep every promote run's output there.
run() {
  local rc=0
  (cd "$here" && "$PROMOTE" "$@") </dev/null >"$work/out" 2>&1 || rc=$?
  if [ -n "${PROMOTE_TEST_LOG:-}" ]; then
    printf '\n######## promote %s (exit %s)\n' "$*" "$rc" >>"$PROMOTE_TEST_LOG"
    cat "$work/out" >>"$PROMOTE_TEST_LOG"
  fi
  return "$rc"
}
expect_ok() {
  run "$@" || {
    cat "$work/out"
    die "promote $* failed"
  }
}
expect_refused() {
  local pattern=$1
  shift
  if run "$@"; then
    cat "$work/out"
    die "promote $* should have been refused"
  fi
  grep -q -- "$pattern" "$work/out" || {
    cat "$work/out"
    die "promote $* refused, but without '$pattern'"
  }
}

# --- main, before the first release --------------------------------------------------------
lock 1111111111111111111111111111111111111111 "$daemon1" "$launcher1"
signers k1
mkdir -p "$work/dev/release"
echo 0.6.0 >"$work/dev/release/version"
printf '# Release notes\n\n## 0.6.0\n\nNamed already.\n' >"$work/dev/release/notes.md"
dev add -A
dev commit -q -m "Initial"
push
expect_refused "must be '## Unreleased'" beta --bootstrap --key "$work/k1" --security none
pass "notes without an Unreleased section on top: refused"
printf '# Release notes\n\n' >"$work/dev/release/notes.md"
change "Everything so far"
push
main1=$(dev rev-parse HEAD)

# --- beta bootstrap ------------------------------------------------------------------------
echo none >"$work/ci"
expect_refused "use --skip-ci" beta --bootstrap --key "$work/k1" --security none
pass "no CI statuses: refused, pointing at --skip-ci"
echo pending >"$work/ci"
expect_refused "CI is still running" beta --bootstrap --key "$work/k1" --security none
pass "pending CI (still running): refused, no skip offered"
echo failure >"$work/ci"
expect_refused "CI is 'failure'" beta --bootstrap --key "$work/k1" --security none
pass "red CI: refused"
expect_ok beta --bootstrap --key "$work/k1" --security none --skip-ci --dry-run
grep -q "NO CI CHECK" "$work/out" || die "--skip-ci did not warn"
pass "--skip-ci skips the CI check with a warning"
echo success >"$work/ci"

expect_refused "needs --bootstrap" beta --key "$work/k1" --security none
pass "first beta without --bootstrap: refused"
expect_refused "does not apply to beta" beta --bootstrap --key "$work/k1" --security none --bump keep
pass "--bump keep on beta: refused"
expect_refused "do not apply to a hotfix" hotfix hotfix/x --key "$work/k1" --version 0.9.0
pass "--version on a hotfix: refused"

expect_ok beta --bootstrap --key "$work/k1" --dry-run
[ -z "$(remote beta)" ] || die "dry run created beta"
grep -q "would run: git push" "$work/out" || die "dry run did not show the push"
grep -q "HinterOS 0.6.1 beta" "$work/out" || die "dry run did not show the message"
pass "dry run: shows the commit and the push, creates nothing"

expect_refused "is not in the allowed signers" beta --bootstrap --key "$work/bad" --security none
pass "bootstrap with a key the new tree does not list: refused before signing"

expect_refused "needs --yes" beta --bootstrap --key "$work/k1" --security none
[ -z "$(remote beta)" ] || die "beta was pushed without the review being answered"
grep -q "== Review" "$work/out" || die "no review before signing"
grep -q "Sign this commit and push it to beta" "$work/out" || die "the review does not ask to sign and push"
pass "the review comes before signing: without an answer nothing is signed or pushed"

expect_ok beta --bootstrap --key "$work/k1" --security none --yes
beta1=$(remote beta)
[ -n "$beta1" ] || die "no beta after bootstrap"
[ "$(o diff --name-only "$main1" "$beta1")" = release/version ] || die "bootstrap tree differs from main beyond release/version"
[ "$(o show "$beta1:release/version")" = 0.6.1 ] || die "bootstrap release/version"
[ "$(o rev-list --parents -n1 "$beta1")" = "$beta1 $main1" ] || die "bootstrap parents are not just main"
[ "$(o log -1 --format=%s "$beta1")" = "HinterOS 0.6.1 beta" ] || die "bad subject"
o log -1 --format=%B "$beta1" | grep -q "Everything so far" || die "notes not in the message"
! o log -1 --format=%B "$beta1" | grep -q "^Security:" || die "Security: none must add no trailer"
grep -q "beta is HinterOS 0.6.1.${beta1:0:7} beta" "$work/out" || die "the beta's name is not shown"
box_verifies "$beta1" "$beta1" || die "bootstrap commit does not verify against its own signers"
pass "bootstrap: 'HinterOS 0.6.1 beta', tree = main with release/version 0.6.1, parent = main, shown as 0.6.1.<hash> beta, verifies"

expect_refused "already exists" beta --bootstrap --key "$work/k1" --security none
pass "--bootstrap when beta exists: refused"

# --- second beta: the next patch -----------------------------------------------------------
change "Fix a browser hole" "Security: medium"
signers k1 k2
# The launcher rev is not in the clone next to the checkout: promote must say so.
lock 2222222222222222222222222222222222222222 "$daemon2" 3333333333333333333333333333333333333333
dev commit -q -am "Add k2, bump nixpkgs"
push
main2=$(dev rev-parse HEAD)
expect_refused "no terminal: give --security" beta --key "$work/k1"
pass "non-interactive without --security: refused"

# The remote is not trusted: a commit there that the owner does not have stops the release,
# also with --rev of a commit the owner has.
git clone -q "$work/origin.git" "$work/forge" 2>/dev/null
git -C "$work/forge" commit -q --allow-empty -m "Added on the server"
git -C "$work/forge" push -q origin main 2>/dev/null
expect_refused "origin/main is not your local main. Pull and review first." beta --key "$work/k1" --security medium --yes
expect_refused "origin/main is not your local main" beta --rev "$main2" --key "$work/k1" --security medium --yes
o update-ref refs/heads/main "$main2"
[ "$(remote beta)" = "$beta1" ] || die "beta moved with a commit the owner does not have"
pass "origin/main with a commit that is not in the local main: refused, also with --rev"
dev commit -q --allow-empty -m "Not pushed"
expect_refused "Push first" beta --key "$work/k1" --security medium --yes
dev reset -q --hard "$main2"
pass "a local main with commits that are not pushed: refused"
here=$work
expect_refused "run promote in your checkout" beta --key "$work/k1" --security medium --yes
here=$work/dev
pass "not started in a checkout: refused"

expect_refused "0.6.1 is not more than 0.6.1 (the current beta)" beta --key "$work/k1" --security medium --version 0.6.1 --dry-run
expect_refused "0.6.0 is not more than 0.6.1 (the current beta)" beta --key "$work/k1" --security medium --version 0.6.0 --dry-run
pass "beta --version that is not more than the current beta: refused"
expect_ok beta --key "$work/k1" --security medium --bump minor --dry-run
grep -q "HinterOS 0.7.0 beta" "$work/out" || die "beta --bump minor is not 0.7.0"
expect_ok beta --key "$work/k1" --security medium --version 0.6.5 --dry-run
grep -q "HinterOS 0.6.5 beta" "$work/out" || die "beta --version 0.6.5 is not used"
expect_ok beta --key "$work/k1" --security medium --dry-run
grep -q "1) patch  0.6.2" "$work/out" && grep -q "2) minor  0.7.0" "$work/out" || die "the beta version menu"
grep -q "no terminal: using 0.6.2 (the default, patch)" "$work/out" || die "beta does not default to the next patch"
pass "beta --bump minor (0.7.0), --version 0.6.5, else the next patch (0.6.2) by default"

expect_ok beta --key "$work/k1" --security medium --yes
beta2=$(remote beta)
grep -q "Security: medium in" "$work/out" || die "trailer not listed"
grep -q "nixpkgs: 111111111111 -> 222222222222" "$work/out" || die "nixpkgs change not shown"
grep -q "hinteros-daemon: ${daemon1:0:12} -> ${daemon2:0:12}" "$work/out" || die "daemon change not shown"
grep -q "Daemon change A" "$work/out" && grep -q "Daemon change B" "$work/out" \
  || die "the daemon commits from ../hinteros-daemon are not listed"
grep -q "hinteros-launcher 333333333333 is not in $work/hinteros-launcher. Fetch it and review it." "$work/out" \
  || die "a launcher rev that is not in ../hinteros-launcher is not shown"
grep -q "flake.lock *|" "$work/out" && grep -q "files changed" "$work/out" || die "no diffstat"
grep -q "Fix a browser hole" "$work/out" || die "the commits are not listed"
[ "$(o rev-list --parents -n1 "$beta2")" = "$beta2 $beta1 $main2" ] || die "parents are not beta, main"
[ "$(o diff --name-only "$main2" "$beta2")" = release/version ] || die "tree differs from main beyond release/version"
[ "$(o show "$beta2:release/version")" = 0.6.2 ] || die "the second beta's release/version"
[ "$(o log -1 --format=%s "$beta2")" = "HinterOS 0.6.2 beta" ] || die "the second beta is not the next patch"
grep -q "beta is HinterOS 0.6.2.${beta2:0:7} beta" "$work/out" || die "the second beta's name"
o log -1 --format=%B "$beta2" | grep -qx "Security: medium" || die "no Security trailer"
box_verifies "$beta2" "$beta1" || die "beta does not verify against the old tip's signers"
pass "second beta, 0.6.1 -> 0.6.2: fast-forward, tree = main with release/version, parents beta+main, trailer, verifies"

# A key only the new tree lists is not enough; nor is a key that the script cannot pre-check.
change "More"
push
expect_refused "is not in the allowed signers" beta --key "$work/bad" --security none
expect_refused "does not verify against these signers" beta --key "$work/nopub" --security none --yes
[ "$(remote beta)" = "$beta2" ] || die "beta moved after a refused promotion"
pass "a key the old tip does not list: refused (pre-check, and at verification)"

# --- the first stable ----------------------------------------------------------------------
expect_refused "is not a release commit on origin/beta" stable --rev "$main2" --bump keep --yes
pass "stable from a main commit (not a release commit): refused"
expect_ok stable --rev "$beta1" --dry-run --key "$work/k1"
grep -q "no terminal: using 0.6.1 (the default, keep)" "$work/out" || die "stable does not default to the beta's version"
pass "stable without --bump/--version: the beta release's own version (0.6.1)"
expect_refused "or --version, not both" stable --rev "$beta1" --bump minor --version 0.9.0
pass "--bump and --version together: refused"
expect_refused "needs --yes" stable --rev "$beta1" --bump keep --key "$work/k1"
pass "stable without --yes and no terminal (the sign confirmation): refused"
expect_refused "0.6.0 is less than 0.6.1" stable --rev "$beta1" --version 0.6.0 --yes --key "$work/k1"
pass "a version below the beta's: refused"

expect_ok stable --rev "$beta1" --dry-run --key "$work/k1"
grep -q "1) keep   0.6.1" "$work/out" || die "the menu does not offer keep (the beta's version)"
# Bumps come after the newest beta (0.6.2), which has the next patch already.
grep -q "2) patch  0.6.3" "$work/out" || die "the menu's patch is not after the newest beta"
grep -q "3) minor  0.7.0" "$work/out" || die "the menu does not offer minor"
grep -q "5) other" "$work/out" || die "the menu does not offer other"
grep -q "using 0.6.1" "$work/out" || die "the dry run does not default to keep"
grep -q "Everything so far" "$work/out" || die "the release notes are not shown"
[ -z "$(remote stable)" ] || die "dry run created stable"
pass "dry run: the version menu (keep, patch, minor, major, other) and the notes, creates nothing"

# A "beta release" that the server put on beta, signed with a key that is not a release key.
fake=$(o -c gpg.format=ssh -c user.signingkey="$work/bad" \
  commit-tree -S "$beta2^{tree}" -p "$beta2" -m "HinterOS 0.6.2 beta")
o update-ref refs/heads/beta "$fake"
expect_refused "does not verify against these signers" stable --bump keep --yes --key "$work/k1"
o update-ref refs/heads/beta "$beta2"
[ -z "$(remote stable)" ] || die "stable was made from a beta release with a bad signature"
pass "stable from a beta release that a release key did not sign: refused"

expect_ok stable --rev "$beta1" --bump keep --yes --key "$work/k1"
stable1=$(remote stable)
[ "$(o rev-list --parents -n1 "$stable1")" = "$stable1 $beta1" ] || die "first stable's parent is not the beta release"
[ "$(o show "$stable1:release/version")" = 0.6.1 ] || die "first stable's version"
[ "$(top_heading "$stable1")" = "## 0.6.1" ] || die "first stable's notes heading: $(top_heading "$stable1")"
[ "$(o log -1 --format=%s "$stable1")" = "HinterOS 0.6.1" ] || die "first stable's subject"
[ -z "$(o diff --name-only "$beta1" "$stable1" | grep -vx -e release/version -e release/notes.md)" ] \
  || die "first stable changes more than the version"
grep -q "OWN release/allowed_signers" "$work/out" || die "first stable did not say what it verified against"
box_verifies "$stable1" "$beta1" || die "first stable does not verify"
pass "first stable takes the beta's 0.6.1: signed on top of the beta release, notes named, nothing else changed"

expect_refused "already contains" stable --rev "$beta1" --bump patch --yes --key "$work/k1"
pass "stable at that beta release again: refused"
expect_refused "is not an ancestor" stable --bump minor --yes --key "$work/k1"
pass "stable from a beta that does not contain the last stable release: refused"
expect_refused "merge stable" beta --key "$work/k1" --security none
pass "beta before stable is merged into main: refused"

# --- merge stable into main, then the next stable --------------------------------------------
dev fetch -q origin
dev merge -q -X theirs --no-edit origin/stable
[ "$(cat "$work/dev/release/version")" = 0.6.1 ] || die "main does not have the stable version after the merge"
change "After 0.6.1"
set_version 0.7.0
push
expect_refused "Main must have the stable version" beta --key "$work/k1" --security none
pass "beta with a hand-bumped release/version: refused"
set_version 0.6.1
push
main3=$(dev rev-parse HEAD)
expect_ok beta --key "$work/k1" --security none --yes
beta3=$(remote beta)
o merge-base --is-ancestor "$stable1" "$beta3" || die "stable is not an ancestor of beta"
# After the current beta (0.6.2), which is higher than stable (0.6.1).
[ "$(o log -1 --format=%s "$beta3")" = "HinterOS 0.6.3 beta" ] || die "beta 3 subject"
[ "$(o diff --name-only "$main3" "$beta3")" = release/version ] || die "tree differs"
pass "after merging stable into main: beta 0.6.3.<hash> (after beta 0.6.2), stable is an ancestor"

expect_refused "not more than 0.6.1 (the stable version)" stable --version 0.6.1 --yes --key "$work/k1"
pass "the same version again: refused"
expect_ok stable --dry-run --key "$work/k1"
grep -q "1) keep   0.6.3" "$work/out" || die "the menu does not offer the beta's version first"
grep -q "2) patch  0.6.4" "$work/out" || die "the menu does not offer patch"
grep -q "using 0.6.3" "$work/out" || die "the dry run does not default to the beta's version"
grep -q "After 0.6.1" "$work/out" || die "the changes since stable are not listed"
pass "dry run after the first stable: keep (the beta's 0.6.3) by default, patch/minor/major/other"
expect_ok stable --bump minor --yes --key "$work/k1"
stable2=$(remote stable)
[ "$(o rev-list --parents -n1 "$stable2")" = "$stable2 $beta3" ] || die "stable 0.7.0's parent"
[ "$(o show "$stable2:release/version")" = 0.7.0 ] || die "stable 0.7.0's version"
[ "$(top_heading "$stable2")" = "## 0.7.0" ] || die "stable 0.7.0's notes heading"
[ "$(o log -1 --format=%s "$stable2")" = "HinterOS 0.7.0" ] || die "stable 0.7.0's subject"
o log -1 --format=%B "$stable2" | grep -q "After 0.6.1" || die "stable 0.7.0's notes"
o merge-base --is-ancestor "$stable1" "$stable2" || die "not a fast-forward"
box_verifies "$stable2" "$stable1" || die "stable 0.7.0 does not verify against the old stable's signers"
pass "stable --bump minor: beta 0.6.3 -> 0.7.0, fast-forward, verifies against the old stable's signers"

# --- the release ISO and its signed tag ---------------------------------------------------------
expect_refused "do not apply to a tag" tag --security none --yes --key "$work/k1"
pass "tag with --security: refused"
expect_ok tag --dry-run --key "$work/k1"
grep -q "would run: git push .* refs/tags/v0.7.0" "$work/out" || die "tag dry run: no push shown"
[ -z "$(o tag -l v0.7.0)" ] || die "the dry run made a tag"
pass "tag --dry-run: the ISO and its checksums shown, nothing tagged"
expect_ok tag --yes --key "$work/k1"
[ "$(o rev-parse 'v0.7.0^{commit}')" = "$stable2" ] || die "v0.7.0 does not name stable 0.7.0"
o show "$stable2:release/allowed_signers" \
  | grep -v '^#' | sed 's/^\([^ ]*\) /\1 namespaces="git" /' >"$work/tag.signers"
o -c gpg.ssh.allowedSignersFile="$work/tag.signers" verify-tag v0.7.0 2>/dev/null || die "v0.7.0 does not verify"
o tag -l --format='%(contents:body)' v0.7.0 >"$work/SHA256SUMS"
(cd "$work/iso-out/$stable2/iso" && sha256sum -c --strict "$work/SHA256SUMS" >/dev/null) || die "the tag's SHA256SUMS do not match the ISO"
pass "tag: v0.7.0 on stable 0.7.0, signed by a release key, its body is the ISO's SHA256SUMS"
expect_refused "already has the tag v0.7.0" tag --yes --key "$work/k1"
pass "tag again: refused"

# --- hotfix --------------------------------------------------------------------------------
dev fetch -q origin
dev checkout -q -b hotfix/bad "$stable2"
change "Bad hotfix" "Security: high"
set_version 0.7.1
push hotfix/bad
expect_refused "Keep it at 0.7.0" hotfix hotfix/bad --key "$work/k1" --security high --yes
pass "hotfix that sets release/version itself: refused"

dev checkout -q -b hotfix/fw "$stable2"
change "Firewall fix" "Security: high"
push hotfix/fw
hot=$(dev rev-parse HEAD)
extra=$(o commit-tree "$hot^{tree}" -p "$hot" -m "Added on the server")
o update-ref refs/heads/hotfix/fw "$extra"
expect_refused "origin/hotfix/fw is not your local hotfix/fw" hotfix hotfix/fw --key "$work/k2" --security high --yes
expect_refused "origin/hotfix/fw is not your local hotfix/fw" hotfix hotfix/fw --rev "$hot" --key "$work/k2" --security high --yes
o update-ref refs/heads/hotfix/fw "$hot"
pass "a hotfix branch with a commit that is not in the local branch: refused"
expect_refused "must have a Security severity" hotfix hotfix/fw --key "$work/k1" --security none --yes
pass "hotfix without a severity: refused"
expect_refused "needs --yes" hotfix hotfix/fw --key "$work/k2" --security high
pass "hotfix without confirming the version: refused"
expect_ok hotfix hotfix/fw --key "$work/k2" --security high --yes
stable3=$(remote stable)
grep -q "0.7.0 -> 0.7.1" "$work/out" || die "the hotfix version is not shown"
[ "$(o rev-list --parents -n1 "$stable3")" = "$stable3 $stable2" ] || die "hotfix parent is not stable"
[ "$(o show "$stable3:release/version")" = 0.7.1 ] || die "hotfix version"
[ "$(top_heading "$stable3")" = "## 0.7.1" ] || die "hotfix notes heading"
[ "$(o log -1 --format=%s "$stable3")" = "HinterOS 0.7.1" ] || die "bad hotfix subject"
[ -z "$(o diff --name-only "$hot" "$stable3" | grep -vx -e release/version -e release/notes.md)" ] \
  || die "hotfix tree differs beyond the version"
box_verifies "$stable3" "$stable2" || die "hotfix does not verify against the old stable's signers"
pass "hotfix: 0.7.1, signed (with the key added later) on top of stable, verifies"

expect_refused "already contains" stable --bump patch --yes --key "$work/k1"
pass "stable again after the hotfix (no new beta yet): refused"
dev checkout -q main
change "Work on main during the hotfix"
push
expect_refused "merge stable" beta --key "$work/k1" --security none
pass "beta while the hotfix is not on main: refused"

dev checkout -q main
dev fetch -q origin
dev merge -q -X theirs --no-edit origin/stable
change "After 0.7.1"
push
main4=$(dev rev-parse HEAD)
expect_ok beta --key "$work/k1" --security none --yes
beta4=$(remote beta)
[ "$(o diff --name-only "$main4" "$beta4")" = release/version ] || die "tree differs"
[ "$(o log -1 --format=%s "$beta4")" = "HinterOS 0.7.2 beta" ] || die "beta after the hotfix"
o merge-base --is-ancestor "$stable3" "$beta4" || die "stable is not an ancestor of beta"
box_verifies "$beta4" "$beta3" || die "beta 0.7.2.<hash> does not verify"
pass "after merging stable into main: beta 0.7.2.<hash> (after stable 0.7.1), stable is an ancestor again"

# --- betas count up; a hotfix and a stable after them ---------------------------------------
change "Beta work 1"
push
main5=$(dev rev-parse HEAD)
expect_ok beta --key "$work/k1" --security none --bump patch --yes
beta5=$(remote beta)
[ "$(o log -1 --format=%s "$beta5")" = "HinterOS 0.7.3 beta" ] || die "the next beta is not 0.7.3"
[ "$(o show "$beta5:release/version")" = 0.7.3 ] || die "beta 0.7.3's release/version"
[ "$(o rev-list --parents -n1 "$beta5")" = "$beta5 $beta4 $main5" ] || die "beta 0.7.3's parents"
grep -q "beta is HinterOS 0.7.3.${beta5:0:7} beta" "$work/out" || die "beta 0.7.3's name"
pass "beta -> beta: 0.7.2 -> 0.7.3 (--bump patch), release/version 0.7.3"

# A hotfix while beta has 0.7.3: the next patch after the beta, not 0.7.2 (a beta has it).
dev checkout -q -b hotfix/dns "$stable3"
change "DNS fix" "Security: medium"
push hotfix/dns
expect_ok hotfix hotfix/dns --key "$work/k1" --security medium --yes
stable4=$(remote stable)
grep -q "0.7.1 -> 0.7.4" "$work/out" || die "the hotfix is not after the beta"
[ "$(o show "$stable4:release/version")" = 0.7.4 ] || die "hotfix 0.7.4's version"
[ "$(o log -1 --format=%s "$stable4")" = "HinterOS 0.7.4" ] || die "hotfix 0.7.4's subject"
pass "hotfix while beta is 0.7.3: 0.7.4 (no version a beta has)"

dev checkout -q main
dev fetch -q origin
dev merge -q -X theirs --no-edit origin/stable
[ "$(cat "$work/dev/release/version")" = 0.7.4 ] || die "main does not have the hotfix version"
change "Beta work 2"
push
main6=$(dev rev-parse HEAD)
expect_ok beta --key "$work/k1" --security none --yes
beta6=$(remote beta)
[ "$(o log -1 --format=%s "$beta6")" = "HinterOS 0.7.5 beta" ] || die "the beta after hotfix 0.7.4 is not 0.7.5"
pass "beta after the hotfix: 0.7.5"

expect_ok stable --yes --key "$work/k1"
stable5=$(remote stable)
[ "$(o rev-list --parents -n1 "$stable5")" = "$stable5 $beta6" ] || die "stable 0.7.5's parent"
[ "$(o show "$stable5:release/version")" = 0.7.5 ] || die "stable does not take the beta's 0.7.5"
[ "$(o log -1 --format=%s "$stable5")" = "HinterOS 0.7.5" ] || die "stable 0.7.5's subject"
[ "$(top_heading "$stable5")" = "## 0.7.5" ] || die "stable 0.7.5's notes heading"
[ "$(o diff --name-only "$beta6" "$stable5")" = release/notes.md ] || die "stable 0.7.5 changes more than the notes"
pass "stable takes the beta's number: beta 0.7.5 -> stable 0.7.5"

dev fetch -q origin
dev merge -q -X theirs --no-edit origin/stable
change "After 0.7.5"
push
expect_ok beta --key "$work/k1" --security none --yes
beta7=$(remote beta)
[ "$(o log -1 --format=%s "$beta7")" = "HinterOS 0.7.6 beta" ] || die "the beta after stable 0.7.5 is not 0.7.6"
pass "the next beta after stable 0.7.5: 0.7.6"

# --- the menus (no mode given), on a terminal ----------------------------------------------
# A fresh remote. `script` gives promote a terminal; the answers are typed in advance.
expect_refused "no terminal for the menus" --skip-ci
pass "no mode and no terminal: refused with the usage"

export PROMOTE_REPO_URL=$work/menus.git
git init -q --bare "$work/menus.git"
git clone -q "$work/menus.git" "$work/m" 2>/dev/null
here=$work/m
m() { git -C "$work/m" "$@"; }
mo() { git -C "$work/menus.git" "$@"; }
mkdir -p "$work/m/release"
echo 0.7.0 >"$work/m/release/version"
printf '# Release notes\n\n## Unreleased\n\n- Profiles.\n\n## 0.1.0\n\nOld.\n' >"$work/m/release/notes.md"
echo "k1 $(pub k1) k1@test" >"$work/m/release/allowed_signers"
cp "$work/dev/flake.lock" "$work/m/flake.lock"
m add -A
m commit -q -m "Profiles"
m push -q origin main 2>/dev/null
# The "editor": adds a line to the notes it is given.
printf '#!%s\necho "- Edited at the promote prompt." >>"$1"\n' "$BASH" >"$work/editor"
chmod +x "$work/editor"

# run_menus <answers, one per line> <args>: promote on a terminal; output in $work/out.
run_menus() {
  local answers=$1 rc=0
  shift
  printf '%b' "$answers" | (cd "$here" && EDITOR=$work/editor script -qec "$(printf '%q ' "$PROMOTE" "$@")" /dev/null) \
    | tr -d '\r' >"$work/out" 2>&1 || rc=$?
  if [ -n "${PROMOTE_TEST_LOG:-}" ]; then
    printf '\n######## promote (menus) %s (exit %s)\n' "$*" "$rc" >>"$PROMOTE_TEST_LOG"
    cat "$work/out" >>"$PROMOTE_TEST_LOG"
  fi
}

# "q" is no answer; the end of input (Ctrl+D) stops, as does Ctrl+C.
run_menus 'q\n' --skip-ci --key "$work/k1"
grep -q "1) Release main to beta" "$work/out" || {
  cat "$work/out"
  die "the menu does not offer the first beta"
}
grep -q "Release beta to stable" "$work/out" && die "the menu offers stable before there is a beta"
grep -q "q is not a choice" "$work/out" || die "q is taken as an answer"
grep -q "no answer" "$work/out" || die "the end of input did not stop"
[ -z "$(mo rev-parse -q --verify refs/heads/beta)" ] || die "stopping pushed something"
pass "menus: the channels and only what can be released; the end of input stops with nothing done"

run_menus 'x\n1\n1\n\n1\n\nn\n' --skip-ci --key "$work/k1"
grep -q "x is not a choice" "$work/out" || die "a wrong answer is not asked again"
grep -q "== Review" "$work/out" || die "no review"
grep -q "the answer is no" "$work/out" || die "answering no did not stop"
[ -z "$(mo rev-parse -q --verify refs/heads/beta)" ] || die "beta was pushed after answering no"
pass "menus: a wrong answer is asked again; no at the review leaves nothing signed or pushed"

# 1 release main to beta, 1 newest commit, default severity, 1 notes as they are, default
# version (the next patch), yes to sign.
run_menus '1\n1\n\n1\n\ny\n' --skip-ci --key "$work/k1"
mbeta=$(mo rev-parse -q --verify refs/heads/beta) || {
  cat "$work/out"
  die "the menus did not release beta"
}
grep -q "1) patch  0.7.1" "$work/out" || die "menus: the beta version menu"
[ "$(mo log -1 --format=%s "$mbeta")" = "HinterOS 0.7.1 beta" ] || die "menus: beta subject"
grep -q "This release makes it" "$work/out" || die "menus: the first beta was not explained"
grep -q "beta is HinterOS 0.7.1.${mbeta:0:7} beta" "$work/out" || die "menus: the beta's name"
pass "menus: release main to beta, the first one started without --bootstrap"

# 1 release beta to stable, 1 newest beta, 2 edit the notes then 1 use them, 1 keep (0.7.1), y sign.
run_menus '1\n1\n2\n1\n1\ny\n' --skip-ci --key "$work/k1"
mstable=$(mo rev-parse -q --verify refs/heads/stable) || {
  cat "$work/out"
  die "the menus did not release stable"
}
grep -q "1) Release beta to stable" "$work/out" || die "menus: stable not offered"
grep -q "2) HinterOS" "$work/out" && die "menus: a main commit is offered as a beta release"
grep -q "Release main to beta" "$work/out" && die "menus: beta offered with nothing new on main"
grep -q "notes:     changed here" "$work/out" || die "menus: the review does not say the notes were edited"
[ "$(mo show "$mstable:release/version")" = 0.7.1 ] || die "menus: stable version"
mo show "$mstable:release/notes.md" | grep -qx -- "- Edited at the promote prompt." || die "menus: the edit is not in release/notes.md"
mo log -1 --format=%B "$mstable" | grep -qx -- "- Edited at the promote prompt." || die "menus: the edit is not in the message"
[ "$(mo show "$mstable:release/notes.md" | grep -m1 '^## ')" = "## 0.7.1" ] || die "menus: notes heading"
mo show "$mstable:release/notes.md" | grep -qx "## 0.1.0" || die "menus: the older notes are gone"
[ -z "$(mo diff --name-only "$mbeta" "$mstable" | grep -vx -e release/version -e release/notes.md)" ] \
  || die "menus: stable changes more than the version and notes"
pass "menus: release beta to stable, notes edited before signing, the beta's 0.7.1 kept"

# The stable release has no tag: the menus offer its ISO and tag (the only choice), then yes.
run_menus '1\ny\n' --skip-ci --key "$work/k1"
grep -q "1) Build the ISO of stable 0.7.1 and sign its tag v0.7.1" "$work/out" || {
  cat "$work/out"
  die "menus: the tag is not offered"
}
[ "$(mo rev-parse 'v0.7.1^{commit}')" = "$mstable" ] || die "menus: v0.7.1 does not name stable 0.7.1"
pass "menus: the ISO and signed tag of the stable release"

run_menus '' --skip-ci --key "$work/k1"
grep -q "nothing to release" "$work/out" || die "menus: nothing to release is not said"
pass "menus: nothing new anywhere is said and refused"

# --- a beta promoted before betas kept the stable version ("HinterOS 0.7.0") ------------------
export PROMOTE_REPO_URL=$work/legacy.git
git init -q --bare "$work/legacy.git"
git clone -q "$work/legacy.git" "$work/l" 2>/dev/null
here=$work/l
# A long history (more `git rev-list` output than a pipe holds), as the real repo has: checks
# that read it through a pipe must read all of it.
for i in $(seq 1 3000); do
  printf 'commit refs/heads/main\ncommitter T <t@example.invalid> %d +0000\ndata 2\nc\n\n' "$((1700000000 + i))"
done | git -C "$work/l" fast-import --quiet
git -C "$work/l" reset -q --hard main
cp -r "$work/m/release" "$work/m/flake.lock" "$work/l/"
# The old script wanted the notes section named after the version.
sed -i "s/^## Unreleased$/## 0.7.0/" "$work/l/release/notes.md"
git -C "$work/l" add -A
git -C "$work/l" commit -q -m "Before the version scheme"
git -C "$work/l" push -q origin main 2>/dev/null
lmain=$(git -C "$work/l" rev-parse HEAD)
lbeta=$(git -C "$work/l" -c gpg.format=ssh -c user.signingkey="$work/k1" \
  commit-tree -S "$lmain^{tree}" -p "$lmain" -m "HinterOS 0.7.0" -m "- Profiles.")
git -C "$work/l" push -q origin "$lbeta:refs/heads/beta" 2>/dev/null
run_menus '1\n' --key "$work/k1"
grep -q "1) HinterOS 0.7.0.${lbeta:0:7} beta" "$work/out" || {
  cat "$work/out"
  die "the menus do not offer the old-style beta release for stable"
}
expect_ok stable --bump keep --yes --key "$work/k1"
lstable=$(git -C "$work/legacy.git" rev-parse refs/heads/stable)
[ "$(git -C "$work/legacy.git" rev-list --parents -n1 "$lstable")" = "$lstable $lbeta" ] || die "legacy: stable's parent"
[ "$(git -C "$work/legacy.git" log -1 --format=%s "$lstable")" = "HinterOS 0.7.0" ] || die "legacy: stable subject"
[ "$(git -C "$work/legacy.git" show "$lstable:release/notes.md" | grep -m1 "^## ")" = "## 0.7.0" ] || die "legacy: notes heading"
pass "a beta release from the old script ('HinterOS 0.7.0') can go to stable"


# A beta from the scheme before betas wrote their version (0.7.1 by its subject, release/version
# the stable 0.7.0), as boxes run it now: the next beta is 0.7.2, and stable takes 0.7.1.
l() { git -C "$work/l" "$@"; }
l fetch -q origin
l merge -q --no-edit origin/stable
printf '# Release notes\n\n## Unreleased\n\n- Old-scheme beta.\n\n' >"$work/l/release/notes.new"
sed -n '/^## /,$p' "$work/l/release/notes.md" >>"$work/l/release/notes.new"
mv "$work/l/release/notes.new" "$work/l/release/notes.md"
l commit -q -am "Old-scheme beta work"
l push -q origin main 2>/dev/null
lmain2=$(l rev-parse HEAD)
lbeta2=$(l -c gpg.format=ssh -c user.signingkey="$work/k1" \
  commit-tree -S "$lmain2^{tree}" -p "$lbeta" -p "$lmain2" -m "HinterOS 0.7.1 beta" -m "- Old-scheme beta.")
l push -q origin "$lbeta2:refs/heads/beta" 2>/dev/null
expect_ok stable --dry-run --key "$work/k1"
grep -q "beta release commit: HinterOS 0.7.1.${lbeta2:0:7} beta" "$work/out" || die "legacy: the old-scheme beta's name"
grep -q "using 0.7.1 (the default, keep)" "$work/out" || die "legacy: stable does not default to the old-scheme beta's 0.7.1"
pass "an old-scheme beta 0.7.1 (release/version 0.7.0) goes to stable as 0.7.1 by default"
printf -- '- New-scheme beta.\n' >>"$work/l/file"
l add -A
l commit -q -m "New-scheme beta work"
l push -q origin main 2>/dev/null
expect_ok beta --key "$work/k1" --security none --yes
lbeta3=$(git -C "$work/legacy.git" rev-parse refs/heads/beta)
[ "$(git -C "$work/legacy.git" log -1 --format=%s "$lbeta3")" = "HinterOS 0.7.2 beta" ] || die "legacy: the next beta is not 0.7.2"
[ "$(git -C "$work/legacy.git" show "$lbeta3:release/version")" = 0.7.2 ] || die "legacy: the next beta's release/version"
pass "the beta after an old-scheme beta 0.7.1: 0.7.2"
echo "all $n promote tests passed"
