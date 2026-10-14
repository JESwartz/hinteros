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
export PROMOTE_REPO_URL=$work/origin.git

git init -q --bare "$work/origin.git"
git clone -q "$work/origin.git" "$work/dev" 2>/dev/null
dev() { git -C "$work/dev" "$@"; }
o() { git -C "$work/origin.git" "$@"; }
cd "$work"

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

# --- main, before the first release --------------------------------------------------------
echo '{"nodes":{"nixpkgs":{"locked":{"rev":"1111111111111111111111111111111111111111"}},"root":{}},"root":"root","version":7}' >"$work/dev/flake.lock"
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
expect_refused "CI is 'pending'" beta --bootstrap --key "$work/k1" --security none
pass "pending CI: refused"
echo failure >"$work/ci"
expect_refused "CI is 'failure'" beta --bootstrap --key "$work/k1" --security none
pass "red CI: refused"
expect_ok beta --bootstrap --key "$work/k1" --security none --skip-ci --dry-run
grep -q "NO CI CHECK" "$work/out" || die "--skip-ci did not warn"
pass "--skip-ci skips the CI check with a warning"
echo success >"$work/ci"

expect_refused "needs --bootstrap" beta --key "$work/k1" --security none
pass "first beta without --bootstrap: refused"
expect_refused "only apply to promote stable" beta --bootstrap --key "$work/k1" --security none --bump minor
pass "--bump on beta: refused"

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
[ "$(o rev-parse "$beta1^{tree}")" = "$(dev rev-parse "$main1^{tree}")" ] || die "bootstrap tree differs from main"
[ "$(o rev-list --parents -n1 "$beta1")" = "$beta1 $main1" ] || die "bootstrap parents are not just main"
[ "$(o log -1 --format=%s "$beta1")" = "HinterOS 0.6.1 beta" ] || die "bad subject"
o log -1 --format=%B "$beta1" | grep -q "Everything so far" || die "notes not in the message"
! o log -1 --format=%B "$beta1" | grep -q "^Security:" || die "Security: none must add no trailer"
grep -q "beta is HinterOS 0.6.1.${beta1:0:7} beta" "$work/out" || die "the beta's name is not shown"
box_verifies "$beta1" "$beta1" || die "bootstrap commit does not verify against its own signers"
pass "bootstrap: 'HinterOS 0.6.1 beta', tree = main, parent = main, shown as 0.6.1.<hash> beta, verifies"

expect_refused "already exists" beta --bootstrap --key "$work/k1" --security none
pass "--bootstrap when beta exists: refused"

# --- second beta: no version bump needed ---------------------------------------------------------
change "Fix a browser hole" "Security: medium"
signers k1 k2
echo '{"nodes":{"nixpkgs":{"locked":{"rev":"2222222222222222222222222222222222222222"}},"root":{}},"root":"root","version":7}' >"$work/dev/flake.lock"
dev commit -q -am "Add k2, bump nixpkgs"
push
main2=$(dev rev-parse HEAD)
expect_refused "no terminal: give --security" beta --key "$work/k1"
pass "non-interactive without --security: refused"
expect_ok beta --key "$work/k1" --security medium --yes
beta2=$(remote beta)
grep -q "Security: medium in" "$work/out" || die "trailer not listed"
grep -q "nixpkgs: 111111111111 -> 222222222222" "$work/out" || die "nixpkgs change not shown"
grep -q "Fix a browser hole" "$work/out" || die "the commits are not listed"
[ "$(o rev-list --parents -n1 "$beta2")" = "$beta2 $beta1 $main2" ] || die "parents are not beta, main"
[ "$(o rev-parse "$beta2^{tree}")" = "$(dev rev-parse "$main2^{tree}")" ] || die "tree differs from main"
[ "$(o log -1 --format=%s "$beta2")" = "HinterOS 0.6.1 beta" ] || die "the second beta has another version"
o log -1 --format=%B "$beta2" | grep -qx "Security: medium" || die "no Security trailer"
box_verifies "$beta2" "$beta1" || die "beta does not verify against the old tip's signers"
pass "second beta, same version: fast-forward, tree = main, parents beta+main, trailer, verifies"

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
expect_refused "give --bump or --version" stable --rev "$beta1" --yes --key "$work/k1"
pass "stable without a tty and without --bump/--version: refused"
expect_refused "or --version, not both" stable --rev "$beta1" --bump minor --version 0.9.0
pass "--bump and --version together: refused"
expect_refused "needs --yes" stable --rev "$beta1" --bump keep --key "$work/k1"
pass "stable without the dogfood confirmation: refused"
expect_refused "only for Security: high or critical" stable --rev "$beta2" --expedite --bump keep --yes
pass "--expedite on a medium release: refused"
expect_refused "is less than 0.6.0" stable --rev "$beta1" --version 0.5.9 --yes --key "$work/k1"
pass "a version below the beta's: refused"

expect_ok stable --rev "$beta1" --dry-run --key "$work/k1"
grep -q "1) keep   0.6.0" "$work/out" || die "the menu does not offer keep"
grep -q "3) minor  0.7.0" "$work/out" || die "the menu does not offer minor"
grep -q "5) other" "$work/out" || die "the menu does not offer other"
grep -q "using 0.6.0" "$work/out" || die "the dry run does not default to keep"
grep -q "Everything so far" "$work/out" || die "the release notes are not shown"
[ -z "$(remote stable)" ] || die "dry run created stable"
pass "dry run: the version menu (keep, patch, minor, major, other) and the notes, creates nothing"

expect_ok stable --rev "$beta1" --bump keep --yes --key "$work/k1"
stable1=$(remote stable)
[ "$(o rev-list --parents -n1 "$stable1")" = "$stable1 $beta1" ] || die "first stable's parent is not the beta release"
[ "$(o show "$stable1:release/version")" = 0.6.0 ] || die "first stable's version"
[ "$(top_heading "$stable1")" = "## 0.6.0" ] || die "first stable's notes heading: $(top_heading "$stable1")"
[ "$(o log -1 --format=%s "$stable1")" = "HinterOS 0.6.0" ] || die "first stable's subject"
[ -z "$(o diff --name-only "$beta1" "$stable1" | grep -vx -e release/version -e release/notes.md)" ] \
  || die "first stable changes more than the version"
grep -q "OWN release/allowed_signers" "$work/out" || die "first stable did not say what it verified against"
box_verifies "$stable1" "$beta1" || die "first stable does not verify"
pass "first stable, kept at 0.6.0: signed on top of the beta release, notes named, nothing else changed"

expect_refused "already contains" stable --rev "$beta1" --bump patch --yes --key "$work/k1"
pass "stable at that beta release again: refused"
expect_refused "is not an ancestor" stable --bump minor --yes --key "$work/k1"
pass "stable from a beta that does not contain the last stable release: refused"
expect_refused "merge stable" beta --key "$work/k1" --security none
pass "beta before stable is merged into main: refused"

# --- merge stable into main, then the next stable --------------------------------------------
dev fetch -q origin
dev merge -q -X theirs --no-edit origin/stable
change "After 0.6.0"
set_version 0.7.0
push
expect_refused "Main must have the stable version" beta --key "$work/k1" --security none
pass "beta with a hand-bumped release/version: refused"
set_version 0.6.0
push
main3=$(dev rev-parse HEAD)
expect_ok beta --key "$work/k1" --security none --yes
beta3=$(remote beta)
o merge-base --is-ancestor "$stable1" "$beta3" || die "stable is not an ancestor of beta"
[ "$(o log -1 --format=%s "$beta3")" = "HinterOS 0.6.1 beta" ] || die "beta 3 subject"
[ "$(o rev-parse "$beta3^{tree}")" = "$(dev rev-parse "$main3^{tree}")" ] || die "tree differs"
pass "after merging stable into main: beta 0.6.1.<hash>, stable is an ancestor"

expect_refused "is already on stable" stable --bump keep --yes --key "$work/k1"
pass "--bump keep after the first stable: refused"
expect_refused "not more than the stable version 0.6.0" stable --version 0.6.0 --yes --key "$work/k1"
pass "the same version again: refused"
expect_ok stable --dry-run --key "$work/k1"
grep -q "1) patch  0.6.1" "$work/out" || die "the menu does not offer patch first"
! grep -q "keep" "$work/out" || die "the menu offers keep after the first stable"
grep -q "using 0.6.1" "$work/out" || die "the dry run does not default to patch"
grep -q "After 0.6.0" "$work/out" || die "the changes since stable are not listed"
pass "dry run after the first stable: patch/minor/major/other, patch by default"
expect_ok stable --bump minor --yes --key "$work/k1"
stable2=$(remote stable)
[ "$(o rev-list --parents -n1 "$stable2")" = "$stable2 $beta3" ] || die "stable 0.7.0's parent"
[ "$(o show "$stable2:release/version")" = 0.7.0 ] || die "stable 0.7.0's version"
[ "$(top_heading "$stable2")" = "## 0.7.0" ] || die "stable 0.7.0's notes heading"
[ "$(o log -1 --format=%s "$stable2")" = "HinterOS 0.7.0" ] || die "stable 0.7.0's subject"
o log -1 --format=%B "$stable2" | grep -q "After 0.6.0" || die "stable 0.7.0's notes"
o merge-base --is-ancestor "$stable1" "$stable2" || die "not a fast-forward"
box_verifies "$stable2" "$stable1" || die "stable 0.7.0 does not verify against the old stable's signers"
pass "stable --bump minor: 0.6.0 -> 0.7.0, fast-forward, verifies against the old stable's signers"

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
[ "$(o rev-parse "$beta4^{tree}")" = "$(dev rev-parse "$main4^{tree}")" ] || die "tree differs"
[ "$(o log -1 --format=%s "$beta4")" = "HinterOS 0.7.2 beta" ] || die "beta after the hotfix"
o merge-base --is-ancestor "$stable3" "$beta4" || die "stable is not an ancestor of beta"
box_verifies "$beta4" "$beta3" || die "beta 0.7.2.<hash> does not verify"
pass "after merging stable into main: beta 0.7.2.<hash>, stable is an ancestor again"

# --- the menus (no mode given), on a terminal ----------------------------------------------
# A fresh remote. `script` gives promote a terminal; the answers are typed in advance.
expect_refused "no terminal for the menus" --skip-ci
pass "no mode and no terminal: refused with the usage"

export PROMOTE_REPO_URL=$work/menus.git
git init -q --bare "$work/menus.git"
git clone -q "$work/menus.git" "$work/m" 2>/dev/null
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
  printf '%b' "$answers" | EDITOR=$work/editor script -qec "$(printf '%q ' "$PROMOTE" "$@")" /dev/null \
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

run_menus 'x\n1\n1\n\n1\nn\n' --skip-ci --key "$work/k1"
grep -q "x is not a choice" "$work/out" || die "a wrong answer is not asked again"
grep -q "== Review" "$work/out" || die "no review"
grep -q "the answer is no" "$work/out" || die "answering no did not stop"
[ -z "$(mo rev-parse -q --verify refs/heads/beta)" ] || die "beta was pushed after answering no"
pass "menus: a wrong answer is asked again; no at the review leaves nothing signed or pushed"

# 1 release main to beta, 1 newest commit, default severity, 1 notes as they are, yes to sign.
run_menus '1\n1\n\n1\ny\n' --skip-ci --key "$work/k1"
mbeta=$(mo rev-parse -q --verify refs/heads/beta) || {
  cat "$work/out"
  die "the menus did not release beta"
}
[ "$(mo log -1 --format=%s "$mbeta")" = "HinterOS 0.7.1 beta" ] || die "menus: beta subject"
grep -q "This release makes it" "$work/out" || die "menus: the first beta was not explained"
grep -q "beta is HinterOS 0.7.1.${mbeta:0:7} beta" "$work/out" || die "menus: the beta's name"
pass "menus: release main to beta, the first one started without --bootstrap"

# 1 release beta to stable, 1 newest beta, 2 edit the notes then 1 use them, 1 keep 0.7.0,
# y box #2, y sign.
run_menus '1\n1\n2\n1\n1\ny\ny\n' --skip-ci --key "$work/k1"
mstable=$(mo rev-parse -q --verify refs/heads/stable) || {
  cat "$work/out"
  die "the menus did not release stable"
}
grep -q "1) Release beta to stable" "$work/out" || die "menus: stable not offered"
grep -q "2) HinterOS" "$work/out" && die "menus: a main commit is offered as a beta release"
grep -q "Release main to beta" "$work/out" && die "menus: beta offered with nothing new on main"
grep -q "notes:     changed here" "$work/out" || die "menus: the review does not say the notes were edited"
[ "$(mo show "$mstable:release/version")" = 0.7.0 ] || die "menus: stable version"
mo show "$mstable:release/notes.md" | grep -qx -- "- Edited at the promote prompt." || die "menus: the edit is not in release/notes.md"
mo log -1 --format=%B "$mstable" | grep -qx -- "- Edited at the promote prompt." || die "menus: the edit is not in the message"
[ "$(mo show "$mstable:release/notes.md" | grep -m1 '^## ')" = "## 0.7.0" ] || die "menus: notes heading"
mo show "$mstable:release/notes.md" | grep -qx "## 0.1.0" || die "menus: the older notes are gone"
[ -z "$(mo diff --name-only "$mbeta" "$mstable" | grep -vx -e release/version -e release/notes.md)" ] \
  || die "menus: stable changes more than the version and notes"
pass "menus: release beta to stable, notes edited before signing, kept at 0.7.0"

run_menus '' --skip-ci --key "$work/k1"
grep -q "nothing to release" "$work/out" || die "menus: nothing to release is not said"
pass "menus: nothing new anywhere is said and refused"

# --- a beta promoted before betas kept the stable version ("HinterOS 0.7.0") ------------------
export PROMOTE_REPO_URL=$work/legacy.git
git init -q --bare "$work/legacy.git"
git clone -q "$work/legacy.git" "$work/l" 2>/dev/null
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
grep -q "1) HinterOS 0.7.1.${lbeta:0:7} beta" "$work/out" || {
  cat "$work/out"
  die "the menus do not offer the old-style beta release for stable"
}
expect_ok stable --bump keep --yes --key "$work/k1"
lstable=$(git -C "$work/legacy.git" rev-parse refs/heads/stable)
[ "$(git -C "$work/legacy.git" rev-list --parents -n1 "$lstable")" = "$lstable $lbeta" ] || die "legacy: stable's parent"
[ "$(git -C "$work/legacy.git" log -1 --format=%s "$lstable")" = "HinterOS 0.7.0" ] || die "legacy: stable subject"
[ "$(git -C "$work/legacy.git" show "$lstable:release/notes.md" | grep -m1 "^## ")" = "## 0.7.0" ] || die "legacy: notes heading"
pass "a beta release from the old script ('HinterOS 0.7.0') can go to stable"

echo "all $n promote tests passed"
