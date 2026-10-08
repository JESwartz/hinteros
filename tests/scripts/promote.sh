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

# Keys: k1 (the release key of 0.6.0), k2 (added by 0.7.0), bad (never listed), nopub (k1-less
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
export PROMOTE_REPO_URL=$work/origin.git

git init -q --bare "$work/origin.git"
git clone -q "$work/origin.git" "$work/dev" 2>/dev/null
dev() { git -C "$work/dev" "$@"; }
cd "$work"

# A release on main: version, notes section, optional signers line, optional trailer.
release() {
  local version=$1 trailer=${2:-}
  mkdir -p "$work/dev/release"
  echo "$version" >"$work/dev/release/version"
  {
    printf '# Release notes\n\n## %s\n\nChanges in %s.\n\n' "$version" "$version"
    [ ! -f "$work/dev/release/notes.md" ] || sed -n '/^## /,$p' "$work/dev/release/notes.md"
  } >"$work/dev/release/notes.tmp"
  mv "$work/dev/release/notes.tmp" "$work/dev/release/notes.md"
  dev add -A
  if [ -n "$trailer" ]; then
    dev commit -q -m "Release $version" -m "$trailer"
  else
    dev commit -q -m "Release $version"
  fi
}
signers() {
  mkdir -p "$work/dev/release"
  {
    echo "# comment line"
    for k in "$@"; do echo "$k $(pub "$k") $k@test"; done
  } >"$work/dev/release/allowed_signers"
}
push() { dev push -q origin "${1:-main}" 2>/dev/null; }
remote() { git -C "$work/origin.git" rev-parse -q --verify "refs/heads/$1" || true; }

# The same check as a box: verify-commit against <rev>'s release/allowed_signers.
box_verifies() {
  local rev=$1 against=$2
  git -C "$work/origin.git" show "$against:release/allowed_signers" \
    | grep -v '^#' | sed 's/^\([^ ]*\) /\1 namespaces="git" /' >"$work/box.signers"
  git -C "$work/origin.git" -c gpg.ssh.allowedSignersFile="$work/box.signers" verify-commit "$rev" 2>/dev/null
}

# PROMOTE_TEST_LOG=<file>: keep every promote run's output there.
run() {
  local rc=0
  "$PROMOTE" "$@" </dev/null >"$work/out" 2>&1 || rc=$?
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

# --- main with the first release ----------------------------------------------------------
echo '{"nodes":{"nixpkgs":{"locked":{"rev":"1111111111111111111111111111111111111111"}},"root":{}},"root":"root","version":7}' >"$work/dev/flake.lock"
echo one >"$work/dev/file"
dev add -A
dev commit -q -m "Initial"
signers k1
release 0.6.0
push
main1=$(dev rev-parse HEAD)

# --- beta bootstrap ------------------------------------------------------------------------
echo none >"$work/ci"
expect_refused "pass --skip-ci" beta --bootstrap --key "$work/k1" --security none
pass "no CI statuses: refused, pointing at --skip-ci"
echo pending >"$work/ci"
expect_refused "is 'pending', not success" beta --bootstrap --key "$work/k1" --security none
pass "pending CI: refused"
echo failure >"$work/ci"
expect_refused "is 'failure', not success" beta --bootstrap --key "$work/k1" --security none
pass "red CI: refused"
expect_ok beta --bootstrap --key "$work/k1" --security none --skip-ci --dry-run
grep -q "CI CHECK SKIPPED" "$work/out" || die "--skip-ci did not warn"
pass "--skip-ci skips the CI check with a warning"
echo success >"$work/ci"

expect_refused "needs --bootstrap" beta --key "$work/k1" --security none
pass "first beta without --bootstrap: refused"

expect_ok beta --bootstrap --key "$work/k1" --dry-run
[ -z "$(remote beta)" ] || die "dry run created beta"
grep -q "would run: git push" "$work/out" || die "dry run did not show the push"
grep -q "HinterOS 0.6.0" "$work/out" || die "dry run did not show the message"
pass "dry run: shows the commit and the push, creates nothing"

expect_refused "is not in the allowed_signers" beta --bootstrap --key "$work/bad" --security none
pass "bootstrap with a key the new tree does not list: refused before signing"

expect_ok beta --bootstrap --key "$work/k1" --security none
beta1=$(remote beta)
[ -n "$beta1" ] || die "no beta after bootstrap"
[ "$(git -C "$work/origin.git" rev-parse "$beta1^{tree}")" = "$(dev rev-parse "$main1^{tree}")" ] || die "bootstrap tree differs from main"
[ "$(git -C "$work/origin.git" rev-list --parents -n1 "$beta1")" = "$beta1 $main1" ] || die "bootstrap parents are not just main"
[ "$(git -C "$work/origin.git" log -1 --format=%s "$beta1")" = "HinterOS 0.6.0" ] || die "bad subject"
git -C "$work/origin.git" log -1 --format=%B "$beta1" | grep -q "Changes in 0.6.0" || die "notes not in the message"
! git -C "$work/origin.git" log -1 --format=%B "$beta1" | grep -q "^Security:" || die "Security: none must add no trailer"
box_verifies "$beta1" "$beta1" || die "bootstrap commit does not verify against its own signers"
pass "bootstrap: beta = signed commit, tree = main, parent = main, verifies against its own signers"

expect_refused "already exists" beta --bootstrap --key "$work/k1" --security none
pass "--bootstrap when beta exists: refused"

# --- second beta -----------------------------------------------------------------------------
echo two >"$work/dev/file"
dev commit -q -am "A change without a version bump"
push
expect_refused "is the current beta's" beta --key "$work/k1" --security none
pass "reused version: refused"

echo three >"$work/dev/file"
dev commit -q -am "Fix a browser hole" -m "Security: medium"
signers k1 k2
echo '{"nodes":{"nixpkgs":{"locked":{"rev":"2222222222222222222222222222222222222222"}},"root":{}},"root":"root","version":7}' >"$work/dev/flake.lock"
release 0.7.0
push
main2=$(dev rev-parse HEAD)
expect_refused "not interactive: pass --security" beta --key "$work/k1"
pass "non-interactive without --security: refused"
expect_ok beta --key "$work/k1" --security medium
beta2=$(remote beta)
grep -q "Security: medium in" "$work/out" || die "trailer not listed"
grep -q "nixpkgs: 111111111111 -> 222222222222" "$work/out" || die "nixpkgs change not shown"
[ "$(git -C "$work/origin.git" rev-list --parents -n1 "$beta2")" = "$beta2 $beta1 $main2" ] || die "parents are not beta, main"
[ "$(git -C "$work/origin.git" rev-parse "$beta2^{tree}")" = "$(dev rev-parse "$main2^{tree}")" ] || die "tree differs from main"
git -C "$work/origin.git" merge-base --is-ancestor "$beta1" "$beta2" || die "not a fast-forward"
git -C "$work/origin.git" log -1 --format=%B "$beta2" | grep -qx "Security: medium" || die "no Security trailer"
box_verifies "$beta2" "$beta1" || die "beta 0.7.0 does not verify against the old tip's signers"
pass "beta 0.7.0: fast-forward, tree = main, parents beta+main, trailer, verifies against the old tip's signers"

# A key only the new tree lists is not enough; nor is a key that the script cannot pre-check.
echo four >"$work/dev/file"
dev commit -q -am "More"
release 0.8.0
push
main3=$(dev rev-parse HEAD)
expect_refused "is not in the allowed_signers" beta --key "$work/bad" --security none
expect_refused "does not verify against these signers" beta --key "$work/nopub" --security none
[ "$(remote beta)" = "$beta2" ] || die "beta moved after a refused promotion"
pass "a key the old tip does not list: refused (pre-check, and at verification)"

# --- stable --------------------------------------------------------------------------------
expect_refused "not a first-parent commit of origin/beta" stable --rev "$main2" --yes
pass "stable from a main commit (not a release commit): refused"
expect_refused "needs --yes" stable --rev "$beta1"
pass "stable without the dogfood confirmation: refused"
expect_refused "only for Security: high or critical" stable --rev "$beta2" --expedite --yes
pass "--expedite on a medium release: refused"
expect_ok stable --rev "$beta1" --yes
[ "$(remote stable)" = "$beta1" ] || die "stable is not at the first beta release"
grep -q "OWN release/allowed_signers" "$work/out" || die "first stable did not say what it verified against"
pass "first stable: created at the beta release, verified against its own signers"
expect_ok stable --yes
[ "$(remote stable)" = "$beta2" ] || die "stable did not move to the beta tip"
pass "stable fast-forwards to the latest beta release"
expect_refused "already" stable --yes
pass "stable already at the target: refused"

# --- hotfix --------------------------------------------------------------------------------
dev fetch -q origin
dev checkout -q -b hotfix/bad "$beta2"
release 0.8.0 "Security: high"
push hotfix/bad
expect_refused "not a patch bump" hotfix hotfix/bad --key "$work/k1" --security high
pass "hotfix with a minor bump: refused"

dev checkout -q -b hotfix/fw "$beta2"
echo patched >"$work/dev/file"
dev commit -q -am "Firewall fix" -m "Security: high"
release 0.7.1
push hotfix/fw
hot=$(dev rev-parse HEAD)
expect_refused "needs a Security severity" hotfix hotfix/fw --key "$work/k1" --security none
pass "hotfix without a severity: refused"
expect_ok hotfix hotfix/fw --key "$work/k2" --security high
stable2=$(remote stable)
[ "$(git -C "$work/origin.git" rev-list --parents -n1 "$stable2")" = "$stable2 $beta2" ] || die "hotfix parent is not stable"
[ "$(git -C "$work/origin.git" rev-parse "$stable2^{tree}")" = "$(dev rev-parse "$hot^{tree}")" ] || die "hotfix tree differs"
[ "$(git -C "$work/origin.git" log -1 --format=%s "$stable2")" = "HinterOS 0.7.1" ] || die "bad hotfix subject"
box_verifies "$stable2" "$beta2" || die "hotfix does not verify against the old stable's signers"
pass "hotfix: signed (with the key 0.7.0 added) on top of stable, tree = hotfix tip, verifies"

expect_refused "is not an ancestor" stable --yes
pass "stable while the hotfix is not on beta: refused"
expect_refused "merge stable" beta --key "$work/k1" --security none
pass "beta while the hotfix is not on main: refused"

dev checkout -q main
dev fetch -q origin
dev merge -q -X ours --no-edit origin/stable
push
main4=$(dev rev-parse HEAD)
expect_ok beta --key "$work/k1" --security none
beta3=$(remote beta)
[ "$(git -C "$work/origin.git" rev-parse "$beta3^{tree}")" = "$(dev rev-parse "$main4^{tree}")" ] || die "tree differs"
git -C "$work/origin.git" merge-base --is-ancestor "$stable2" "$beta3" || die "stable is not an ancestor of beta"
box_verifies "$beta3" "$beta2" || die "beta 0.8.0 does not verify"
pass "after merging stable into main: beta 0.8.0, stable is an ancestor again"
[ "$main3" != "$main4" ]

echo "all $n promote tests passed"
