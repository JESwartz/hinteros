# promote: move a HinterOS channel (hinteros-docs/design/distribution.md, "The release pipeline",
# "Promote script checks"). Run by the owner on the dev machine:
#
#   nix run .#promote                [--dry-run] [--skip-ci] [--key <path>]
#
# asks for everything with numbered menus: it shows where main, beta and stable are, what can be
# released where, which commit, the security severity, the version, the release notes (which can
# be edited before signing), and always shows the finished commit for review before it is signed
# and pushed. The same steps without questions, for scripts and tests:
#
#   nix run .#promote -- beta   [--rev <main commit>] [--bootstrap] [--security <sev>]
#   nix run .#promote -- stable [--rev <beta release commit>] [--expedite] [--bump <b> | --version <v>]
#   nix run .#promote -- hotfix <branch> [--rev <commit>] [--security <sev>]
#   common: [--dry-run] [--skip-ci] [--key <path>] [--yes]
#
# Versions: `release/version` on main is the latest stable release, and main's release notes keep
# an `## Unreleased` section on top. A beta release keeps both: a box shows it as
# `<version>.<commit> beta` (the release commit's short hash). `promote stable` shows what changed
# and asks the promoter for the new version (patch, minor, major or typed; --bump/--version
# without asking), then signs a commit on top of the beta release that only writes it to
# release/version and renames `## Unreleased`; a box shows `<version> stable`. A hotfix is the
# next patch version, written the same way.
#
# It works on a fresh bare clone of the remote in a temporary directory (never on the checkout it
# is started from), prints every check it makes, signs the release commit with the release key
# file (never through ssh-agent: ssh-keygen asks for the passphrase on the terminal), verifies it
# the way a box will and pushes the channel branch as a fast-forward. --dry-run does everything
# except signing and pushing.
#
# Environment:
#   HINTEROS_RELEASE_KEY   signing key file (default ~/.ssh/hinteros/release_ed25519)
#   PROMOTE_REPO_URL       remote to fetch from and push to (default: `origin` of the current repo)
#   PROMOTE_FORGEJO_API    Forgejo API base, e.g. https://justsomeshed.com/api/v1 (default: derived)
#   PROMOTE_FORGEJO_REPO   repo path for the API, e.g. JSwartz/HinterOS/hinteros (default: derived)
#   PROMOTE_STATUS_CMD     program printing the combined-status JSON for a commit (tests)

usage() {
  cat <<'USAGE'
usage: promote [--dry-run] [--skip-ci] [--key <path>]   (menus ask for all values)
       promote beta   [--rev <sha>] [--bootstrap] [--security <sev>] [options]
       promote stable [--rev <sha>] [--expedite] [--bump <bump> | --version <v>] [options]
       promote hotfix <branch> [--rev <sha>] [--security <sev>] [options]
options: --dry-run  --skip-ci  --key <path>  --yes
  --bump       stable only: patch, minor, major, or keep (before the first stable release)
  --version    stable only: the new version (MAJOR.MINOR.PATCH)
  --dry-run    do all steps, but do not sign or push
  --skip-ci    do not require a CI result (use until the CI runner exists)
  --key        the signing key file (default: $HINTEROS_RELEASE_KEY or ~/.ssh/hinteros/release_ed25519)
  --security   none, low, medium, high or critical (if not given, the script asks)
  --bootstrap  the first beta release (the beta branch does not exist)
  --expedite   stable only: a high or critical release after 1 hour on box #2
  --yes        answer yes to all questions, also at the review (for scripts)
USAGE
}

die() {
  printf 'promote: %s\n' "$*" >&2
  exit 1
}
step() { printf '\n== %s\n' "$*"; }
ok() { printf '  [ok]   %s\n' "$*"; }
info() { printf '  [info] %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }
fail() {
  printf '  [FAIL] %s\n' "$*"
  printf '\npromote: stopped. Nothing is signed or pushed.\n' >&2
  exit 1
}

# Never sign through an agent: the key must be unlocked with its passphrase, each time.
unset SSH_AUTH_SOCK SSH_AGENT_PID

mode=
hotfix_branch=
want_rev=
dry_run=0
bootstrap=0
expedite=0
skip_ci=0
assume_yes=0
security=
want_bump=
want_version=
interactive=0
notes_edited=0
key=${HINTEROS_RELEASE_KEY:-$HOME/.ssh/hinteros/release_ed25519}

case "${1:-}" in
  "" | --dry-run | --skip-ci | --key)
    # No mode: the menus ask for everything.
    [ -t 0 ] || {
      usage >&2
      die "no terminal for the menus. Give beta, stable or hotfix and the options."
    }
    interactive=1
    set -- interactive "$@"
    ;;
  beta | stable) mode=$1 ;;
  hotfix)
    mode=hotfix
    [ "$#" -ge 2 ] || die "hotfix needs the branch: promote hotfix hotfix/<name>"
    hotfix_branch=$2
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --rev)
      [ "$#" -ge 2 ] || die "--rev needs a commit"
      want_rev=$2
      shift
      ;;
    --key)
      [ "$#" -ge 2 ] || die "--key needs a path"
      key=$2
      shift
      ;;
    --security)
      [ "$#" -ge 2 ] || die "--security needs a severity"
      security=$2
      shift
      ;;
    --bump)
      [ "$#" -ge 2 ] || die "--bump needs patch, minor, major or keep"
      want_bump=$2
      shift
      ;;
    --version)
      [ "$#" -ge 2 ] || die "--version needs a version"
      want_version=$2
      shift
      ;;
    --dry-run) dry_run=1 ;;
    --bootstrap) bootstrap=1 ;;
    --expedite) expedite=1 ;;
    --skip-ci) skip_ci=1 ;;
    --yes) assume_yes=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done
if [ "$interactive" = 1 ]; then
  [ -z "$want_rev$security$want_bump$want_version" ] && [ "$bootstrap$expedite$assume_yes" = 000 ] \
    || die "the menus ask for the commit, severity, version and confirmations: only --dry-run, --skip-ci and --key go with them"
fi
[ "$bootstrap" = 0 ] || [ "$mode" = beta ] || die "--bootstrap only applies to promote beta"
[ "$expedite" = 0 ] || [ "$mode" = stable ] || die "--expedite only applies to promote stable"
[ -z "$want_bump$want_version" ] || [ "$mode" = stable ] \
  || die "--bump and --version only apply to promote stable (beta keeps the version, hotfix is a patch)"
[ -z "$want_bump" ] || [ -z "$want_version" ] || die "--bump or --version, not both"
case "$want_bump" in
  "" | patch | minor | major | keep) ;;
  *) die "--bump must be patch, minor, major or keep" ;;
esac
case "$security" in
  "" | none | low | medium | high | critical) ;;
  *) die "--security must be none, low, medium, high or critical" ;;
esac
case "$key" in
  /*) ;;
  *) key=$PWD/$key ;;
esac

# --- where ---------------------------------------------------------------------------------

local_repo=$(git rev-parse --show-toplevel 2>/dev/null) || local_repo=
url=${PROMOTE_REPO_URL:-}
if [ -z "$url" ]; then
  [ -n "$local_repo" ] || die "run inside a checkout of the system repo, or set PROMOTE_REPO_URL"
  url=$(git -C "$local_repo" remote get-url origin) || die "the current repo has no 'origin' remote"
fi

# Forgejo API from an https remote: https://host/<path>.git -> https://host/api/v1, <path>.
api=${PROMOTE_FORGEJO_API:-}
api_repo=${PROMOTE_FORGEJO_REPO:-}
if [[ $url =~ ^https://([^/]+)/(.+)$ ]]; then
  [ -n "$api" ] || api="https://${BASH_REMATCH[1]}/api/v1"
  if [ -z "$api_repo" ]; then
    api_repo=${BASH_REMATCH[2]%/}
    api_repo=${api_repo%.git}
  fi
fi

if [ "$dry_run" = 1 ]; then
  printf 'promote: DRY RUN. Nothing is signed or pushed.\n'
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/promote.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
repo=$tmp/repo
g() { git -C "$repo" "$@"; }

step "Get $url"
clone_args=(--bare --quiet)
[ -z "$local_repo" ] || clone_args+=(--reference-if-able "$local_repo" --dissociate)
git clone "${clone_args[@]}" "$url" "$repo" || fail "cannot clone $url"
ok "new clone in a temporary directory. All refs are from the remote (origin/*)."
for b in main beta stable; do
  if r=$(g rev-parse -q --verify "refs/heads/$b^{commit}"); then
    info "origin/$b = $r"
  else
    info "origin/$b does not exist"
  fi
done

# Committer identity: the checkout's, else the global one.
cfg_get() {
  if [ -n "$local_repo" ]; then git -C "$local_repo" config "$1"; else git config "$1"; fi
}
name=$(cfg_get user.name) || die "set git user.name"
email=$(cfg_get user.email) || die "set git user.email"
export GIT_AUTHOR_NAME=$name GIT_AUTHOR_EMAIL=$email GIT_COMMITTER_NAME=$name GIT_COMMITTER_EMAIL=$email

# Credentials for the push: the checkout's helpers (they may be configured only there).
cred_args=()
if [ -n "$local_repo" ]; then
  mapfile -t helpers < <(git -C "$local_repo" config --get-all credential.helper || true)
  if [ "${#helpers[@]}" -gt 0 ]; then
    cred_args=(-c credential.helper=)
    for h in "${helpers[@]}"; do cred_args+=(-c "credential.helper=$h"); done
  fi
fi

# --- helpers -------------------------------------------------------------------------------

tip() { g rev-parse -q --verify "refs/heads/$1^{commit}" || true; }

resolve() {
  g rev-parse -q --verify "$1^{commit}" || fail "$1 is not a commit on the remote"
}

is_ancestor() { g merge-base --is-ancestor "$1" "$2"; }

semver_re='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

# release/version of a commit ("" if it has none).
version_at() {
  local v
  v=$(g show "$1:release/version" 2>/dev/null) || {
    printf ''
    return 0
  }
  printf '%s' "$v" | tr -d '[:space:]'
}

# a > b for MAJOR.MINOR.PATCH.
semver_gt() {
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<<"$1"
  IFS=. read -r b1 b2 b3 <<<"$2"
  ((a1 > b1)) && return 0
  ((a1 < b1)) && return 1
  ((a2 > b2)) && return 0
  ((a2 < b2)) && return 1
  ((a3 > b3))
}

# bump <MAJOR.MINOR.PATCH> patch|minor|major|keep
bump() {
  local a b c
  IFS=. read -r a b c <<<"$1"
  case "$2" in
    keep) echo "$1" ;;
    patch) echo "$a.$b.$((c + 1))" ;;
    minor) echo "$a.$((b + 1)).0" ;;
    major) echo "$((a + 1)).0.0" ;;
  esac
}

# The new stable version, from --bump/--version or the promoter's pick from a menu. $1: the
# version the beta release is based on (the latest stable's, or the never released first one);
# $2: the current stable's version ("" before the first stable). Sets $new_version.
new_version=
choose_version() {
  local base=$1 current=$2 default=minor ans i choices=(patch minor major)
  if [ -z "$current" ]; then
    choices=(keep patch minor major)
    default=keep
  fi
  if [ -n "$want_version" ]; then
    new_version=$want_version
    info "--version $want_version"
  elif [ -n "$want_bump" ]; then
    [ "$want_bump" != keep ] || [ -z "$current" ] \
      || fail "--bump keep: $base is already on stable. Use patch, minor or major."
    new_version=$(bump "$base" "$want_bump")
    info "--bump $want_bump"
  else
    printf '\n  Select the new stable version%s:\n' "${current:+ (the current stable is $current)}"
    i=0
    for c in "${choices[@]}"; do
      i=$((i + 1))
      if [ "$c" = keep ]; then
        printf '    %d) keep   %s\n' "$i" "$base"
      else
        printf '    %d) %-6s %s\n' "$i" "$c" "$(bump "$base" "$c")"
      fi
    done
    printf '    %d) other  (type a version)\n' "$((i + 1))"
    if [ ! -t 0 ]; then
      new_version=$(bump "$base" "$default")
      info "no terminal: using $new_version (the default, $default)"
      [ "$dry_run" = 1 ] || fail "no terminal: give --bump or --version"
    else
      read -r -p "  Version [1-$((i + 1)) or name, default $default]: " ans
      ans=${ans:-$default}
      case "$ans" in
        keep | patch | minor | major)
          printf '%s\n' "${choices[@]}" | grep -qx "$ans" || fail "$ans is not a choice"
          new_version=$(bump "$base" "$ans")
          ;;
        "$((i + 1))" | other) read -r -p "  Version (MAJOR.MINOR.PATCH): " new_version ;;
        *)
          if ! [[ $ans =~ ^[0-9]+$ ]] || ((ans < 1 || ans > i)); then fail "$ans is not a choice"; fi
          new_version=$(bump "$base" "${choices[ans - 1]}")
          ;;
      esac
    fi
  fi
  [[ $new_version =~ $semver_re ]] || fail "'$new_version' is not MAJOR.MINOR.PATCH"
  if [ -n "$current" ]; then
    semver_gt "$new_version" "$current" || fail "$new_version is not more than the stable version $current"
  elif [ "$new_version" != "$base" ]; then
    semver_gt "$new_version" "$base" || fail "$new_version is less than $base"
  fi
  ok "new stable version: ${current:-none} -> $new_version"
}

# The tree of commit $1 with release/version set to $2 and the top section of release/notes.md
# (`## Unreleased`) replaced by `## $2` with the release's notes ($tmp/notes.top, as edited).
# Prints the tree id.
versioned_tree() {
  local rev=$1 version=$2 vblob nblob
  export GIT_INDEX_FILE=$tmp/index
  rm -f "$GIT_INDEX_FILE"
  g read-tree "$rev^{tree}"
  vblob=$(printf '%s\n' "$version" | g hash-object -w --stdin)
  nblob=$(g show "$rev:release/notes.md" \
    | awk -v v="$version" -v top="$tmp/notes.top" '
        /^## / { s++ }
        s == 0 { print; next }
        s == 1 && !done {
          print "## " v
          print ""
          while ((getline line < top) > 0) print line
          print ""
          done = 1
          next
        }
        s == 1 { next }
        { print }' \
    | g hash-object -w --stdin)
  g update-index --cacheinfo "100644,$vblob,release/version" \
    --cacheinfo "100644,$nblob,release/notes.md"
  g write-tree
  unset GIT_INDEX_FILE
}

# The release commit $1 changes nothing but release/version and release/notes.md from $2.
only_version_changed() {
  local other
  other=$(g diff --name-only "$2" "$1" | grep -vx -e release/version -e release/notes.md || true)
  [ -z "$other" ] || fail "the release commit changes other files: $other"
  ok "only release/version and release/notes.md are different from ${2:0:12}"
}

# The subjects of the commits in a range (merges and release commits left out), at most 40.
list_changes() {
  local n
  n=$(g rev-list --no-merges --count "$@")
  info "$n commit(s):"
  g log --no-merges --format='           %h %s' "$@" | { grep -v ' HinterOS [0-9]' || true; } | head -40 || true
  [ "$n" -le 40 ] || info "... and $((n - 40)) more"
}

# release/allowed_signers of a commit, in ssh-keygen's format with the namespace pinned to git,
# exactly as nixos/modules/daemon.nix writes it for a box.
signers_of() {
  local rev=$1 out=$2 line n=0
  g show "$rev:release/allowed_signers" >"$tmp/signers.src" 2>/dev/null \
    || fail "$rev has no release/allowed_signers"
  : >"$out"
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    case "$line" in "" | "#"*) continue ;; esac
    [[ $line =~ ^([^\ #]+)\ (ssh-ed25519\ [A-Za-z0-9+/=]+(\ .*)?)$ ]] \
      || fail "release/allowed_signers of $rev: bad line: $line"
    printf '%s namespaces="git" %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" >>"$out"
    n=$((n + 1))
  done <"$tmp/signers.src"
  [ "$n" -gt 0 ] || fail "release/allowed_signers of $rev has no keys. No box can verify a release."
  info "$n key(s) in release/allowed_signers of ${rev:0:12}: $(cut -d' ' -f1 "$out" | tr '\n' ' ')"
}

# Is the signing key's public half in a signers file? Only the .pub file is read.
key_preflight() {
  local signers=$1 pub
  if [ ! -f "$key" ]; then
    if [ "$dry_run" = 1 ]; then
      warn "the signing key $key does not exist. A real run must have it."
      return 0
    fi
    fail "the signing key $key does not exist. Use --key or HINTEROS_RELEASE_KEY."
  fi
  if [ ! -f "$key.pub" ]; then
    info "$key.pub does not exist. The script cannot check the key before it signs."
    return 0
  fi
  pub=$(cut -d' ' -f1,2 "$key.pub")
  if grep -qF " $pub" "$signers"; then
    ok "the signing key $key is in the list as: $(grep -F " $pub" "$signers" | cut -d' ' -f1)"
  else
    fail "the public key of $key is not in the allowed signers for this release"
  fi
}

# git verify-commit against a signers file, as hinteros-system does on a box.
verify() {
  local rev=$1 signers=$2 out
  if out=$(g -c gpg.format=ssh -c gpg.ssh.program=ssh-keygen -c "gpg.ssh.allowedSignersFile=$signers" \
    verify-commit "$rev" 2>&1); then
    ok "git verify-commit ${rev:0:12}: $(printf '%s\n' "$out" | grep -m1 -i 'good' || printf 'good')"
  else
    printf '%s\n' "$out" | sed 's/^/         /'
    fail "${rev:0:12} does not verify against these signers. A box rejects it (unknown_signer)."
  fi
}

# Forgejo's combined commit status must be success, unless --skip-ci.
ci_check() {
  local sha=$1 what=$2 json state total
  step "CI status of $what ${sha:0:12}"
  if [ "$skip_ci" = 1 ]; then
    ci_skipped "$sha"
    return 0
  fi
  if [ -n "${PROMOTE_STATUS_CMD:-}" ]; then
    json=$("$PROMOTE_STATUS_CMD" "$sha") || fail "PROMOTE_STATUS_CMD failed for $sha"
  else
    [ -n "$api" ] && [ -n "$api_repo" ] \
      || fail "cannot find the Forgejo API from $url. Set PROMOTE_FORGEJO_API and PROMOTE_FORGEJO_REPO, or use --skip-ci."
    info "GET $api/repos/$api_repo/commits/$sha/status"
    json=$(curl -fsS --max-time 30 "$api/repos/$api_repo/commits/$sha/status") \
      || fail "cannot read the commit status from Forgejo"
  fi
  total=$(jq -r '.total_count // 0' <<<"$json")
  state=$(jq -r '.state // ""' <<<"$json")
  if [ "$total" = 0 ]; then
    ci_skip_or_fail "$sha" "no CI result for ${sha:0:12}. There is no CI runner. Test by hand and use --skip-ci."
    return 0
  fi
  jq -r '.statuses[] | "  [ci]   \(.context): \(.status)\(if .description then " (\(.description))" else "" end)"' <<<"$json"
  case "$state" in
    success) ok "all $total CI statuses are success" ;;
    pending)
      ci_skip_or_fail "$sha" "CI is 'pending'. No runner started the job. Use --skip-ci until the runner exists."
      ;;
    *) fail "CI is '$state'. It must be 'success'." ;;
  esac
}

ci_skipped() {
  warn "************************************************************************"
  warn "NO CI CHECK: nothing tested ${1:0:12}."
  warn "Do the checks by hand before you release (TESTING.md)."
  warn "Stop this when the Forgejo runner exists."
  warn "************************************************************************"
}

# No CI result (no runner yet): the menus ask whether to go on without it; otherwise refused.
ci_skip_or_fail() {
  local sha=$1 why=$2 ans
  [ "$interactive" = 1 ] || fail "$why"
  warn "$why"
  read -r -p "  Continue without CI? You must do the checks by hand (TESTING.md). [y/N] " ans || ans=
  case "$ans" in
    y | Y | yes)
      skip_ci=1
      ci_skipped "$sha"
      ;;
    *) fail "no CI result for ${sha:0:12}" ;;
  esac
}

sev_rank() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    "" | no | none) echo 0 ;;
    low) echo 1 ;;
    medium) echo 2 ;;
    high) echo 3 ;;
    critical) echo 4 ;;
    *) echo 3 ;; # unknown counts as high, as on the box
  esac
}
sev_name() {
  case "$1" in
    0) echo none ;;
    1) echo low ;;
    2) echo medium ;;
    3) echo high ;;
    4) echo critical ;;
  esac
}

# Highest Security trailer among the commits of a range (all listed). Sets $range_sev.
range_sev=none
scan_security() {
  local range=$1 best=0 sha val r s found=0 vals
  shift
  while IFS=$'\t' read -r sha val; do
    [ -n "$val" ] || continue
    found=1
    info "Security: $val in ${sha:0:12} $(g log -1 --format=%s "$sha")"
    IFS=, read -ra vals <<<"$val"
    for s in "${vals[@]}"; do
      r=$(sev_rank "$(printf '%s' "$s" | tr -d '[:space:]')")
      if ((r > best)); then best=$r; fi
    done
  done < <(g log --format='%H%x09%(trailers:key=Security,valueonly,separator=%x2C)' "$@" "$range")
  [ "$found" = 1 ] || info "no Security trailers in $range"
  range_sev=$(sev_name "$best")
}

# The release severity: --security, else asked (default: the highest in range). Sets $release_sev.
release_sev=none
choose_security() {
  local default=$1 ans
  if [ -n "$security" ]; then
    release_sev=$security
    if (($(sev_rank "$security") < $(sev_rank "$default"))); then
      warn "--security $security is less than the highest trailer in the range ($default)"
    fi
  elif [ ! -t 0 ]; then
    release_sev=$default
    info "no terminal: using the default severity ($default)"
    [ "$dry_run" = 1 ] || fail "no terminal: give --security"
  else
    read -r -p "  Security severity [none/low/medium/high/critical, default $default]: " ans
    release_sev=${ans:-$default}
    case "$release_sev" in
      none | low | medium | high | critical) ;;
      *) fail "$release_sev is not a severity" ;;
    esac
  fi
  ok "release severity: $release_sev"
}

confirm() {
  local ans
  if [ "$assume_yes" = 1 ]; then
    ok "$1 yes (--yes)"
  elif [ "$dry_run" = 1 ]; then
    info "dry run, no question: $1"
  elif [ -t 0 ]; then
    read -r -p "  $1 [y/N] " ans
    case "$ans" in
      y | Y | yes) ok "confirmed" ;;
      *) fail "the answer is no" ;;
    esac
  else
    fail "no terminal: '$1' needs --yes"
  fi
}

# pick <question> <default> <choice>...: a numbered menu, asked until the answer is one of them
# (Ctrl+C or Ctrl+D stops). Sets $picked (1-based).
picked=
pick() {
  local question=$1 default=$2 ans i=0 choice
  shift 2
  [ "$#" -gt 0 ] || fail "no choices for: $question"
  printf '\n  %s\n' "$question"
  for choice in "$@"; do
    i=$((i + 1))
    printf '    %d) %s\n' "$i" "$choice"
  done
  while :; do
    read -r -p "  Choice [1-$i, default $default]: " ans || fail "no answer"
    ans=${ans:-$default}
    if [[ $ans =~ ^[0-9]+$ ]] && ((ans >= 1 && ans <= i)); then
      picked=$ans
      return 0
    fi
    printf '  %s is not a choice.\n' "$ans"
  done
}

# The release notes ($tmp/notes.top) as they will be signed, with the chance to change them in
# an editor first ($VISUAL, $EDITOR, else nano). Only on a terminal and without --yes.
review_notes() {
  local editor
  sed 's/^/  | /' "$tmp/notes.top"
  [ -t 0 ] && [ "$assume_yes" = 0 ] || return 0
  while :; do
    pick "Release notes:" 1 "Use these notes" "Edit the notes"
    [ "$picked" = 2 ] || return 0
    editor=${VISUAL:-${EDITOR:-nano}}
    cp "$tmp/notes.top" "$tmp/notes.edit"
    # The editor may come with arguments ("code --wait").
    # shellcheck disable=SC2086
    $editor "$tmp/notes.edit" || fail "the editor ($editor) failed"
    sed -e '/./,$!d' "$tmp/notes.edit" | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}' >"$tmp/notes.new"
    if [ ! -s "$tmp/notes.new" ]; then
      warn "the notes are empty. The script keeps the old text."
    elif cmp -s "$tmp/notes.new" "$tmp/notes.top"; then
      info "no change"
    else
      mv "$tmp/notes.new" "$tmp/notes.top"
      notes_edited=1
      ok "the release notes are changed"
    fi
    step "Release notes to sign"
    sed 's/^/  | /' "$tmp/notes.top"
  done
}

# The release commit for review, then (after "yes") the same commit signed: an unsigned draft
# is shown in full with where it goes; nothing is signed before the promoter agrees. With
# --dry-run the draft is the result. Sets $new.
# review_and_sign <branch> <what a box shows> <tree> <commit-tree parent args>...
new=
review_and_sign() {
  local branch=$1 shown=$2 tree=$3 draft old
  shift 3
  draft=$(g commit-tree "$tree" "$@" -F "$tmp/msg")
  old=$(tip "$branch")
  step "Review"
  info "channel:   $branch (origin/$branch ${old:+${old:0:12} }-> this commit, fast-forward)"
  info "release:   $shown"
  info "security:  $release_sev"
  if [ "$notes_edited" = 1 ]; then info "notes:     changed here"; fi
  info "remote:    $url"
  [ "$dry_run" = 1 ] || info "key:       $key"
  info "the commit before signing (the signature changes the hash):"
  show_commit "$draft"
  if [ "$dry_run" = 1 ]; then
    new=$draft
    info "dry run: no signature and no push"
    return 0
  fi
  confirm "Sign this commit and push it to $branch?"
  info "sign with $key. ssh-keygen asks for the passphrase."
  new=$(make_commit "$tree" "$@") || fail "the signature failed"
  [ "$(g rev-parse "$new^{tree}")" = "$tree" ] || fail "the signed commit has a different tree"
  ok "signed: $new"
}

# The top section of release/notes.md (under the first "## " heading), which must be
# `## Unreleased`: what changed since the last stable release.
notes_of() {
  local rev=$1 named=${2:-} version heading
  g show "$rev:release/notes.md" >"$tmp/notes.md" 2>/dev/null || fail "$rev has no release/notes.md"
  heading=$(grep -m1 '^## ' "$tmp/notes.md" | sed -e 's/^## *//' -e 's/[[:space:]]*$//') || true
  version=$heading
  [ "$heading" = Unreleased ] || { [ -n "$named" ] && [ "$heading" = "$named" ]; } \
    || fail "release/notes.md: the top section is '## ${heading:-<none>}'. It must be '## Unreleased'."
  awk 'BEGIN { s = 0 } /^## / { s++; next } s == 1 { print }' "$tmp/notes.md" \
    | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}' >"$tmp/notes.top"
  [ -s "$tmp/notes.top" ] || fail "release/notes.md: the $version section is empty"
  ok "release notes: the '## $version' section ($(wc -l <"$tmp/notes.top") lines)"
}

# Component and nixpkgs revisions that change between two commits' flake.lock.
lock_changes() {
  local old=$1 new=$2
  g show "$new:flake.lock" >"$tmp/new.lock" 2>/dev/null || return 0
  if [ -n "$old" ] && g show "$old:flake.lock" >"$tmp/old.lock" 2>/dev/null; then :; else
    echo '{"nodes":{}}' >"$tmp/old.lock"
  fi
  jq -r --slurpfile o "$tmp/old.lock" '
    .nodes | to_entries[] | select(.value.locked.rev != null)
    | .key as $k | .value.locked.rev as $r | ($o[0].nodes[$k].locked.rev // "") as $p
    | if $p == $r then "  [info] \($k): \($r[0:12]) (unchanged)"
      elif $p == "" then "  [info] \($k): \($r[0:12])"
      else "  [info] \($k): \($p[0:12]) -> \($r[0:12])" end' "$tmp/new.lock"
}

# Writes the release commit message to $tmp/msg.
compose_message() {
  local version=$1
  {
    printf 'HinterOS %s\n\n' "$version"
    cat "$tmp/notes.top"
    if [ "$release_sev" != none ]; then printf '\nSecurity: %s\n' "$release_sev"; fi
  } >"$tmp/msg"
}

# Creates the signed release commit and prints its hash.
make_commit() {
  local tree=$1
  shift
  env -u SSH_AUTH_SOCK git -C "$repo" -c gpg.format=ssh -c gpg.ssh.program=ssh-keygen \
    -c "user.signingkey=$key" commit-tree -S "$tree" "$@" -F "$tmp/msg"
}

show_commit() {
  # The headers without the signature block, then the message as is.
  g cat-file -p "$1" | awk '
    h == 0 && /^$/ { h = 1 }
    h == 0 && /^gpgsig / { s = 1; next }
    h == 0 && s && /^ / { next }
    { s = 0; print "  | " $0 }'
}

push_branch() {
  local sha=$1 branch=$2 now
  step "Push origin/$branch -> ${sha:0:12}"
  if [ "$dry_run" = 1 ]; then
    info "would run: git push $url $sha:refs/heads/$branch (no force)"
    return 0
  fi
  g "${cred_args[@]}" push "$url" "$sha:refs/heads/$branch" || fail "the push failed. Maybe $branch changed. The script never forces a push."
  now=$(git ls-remote "$url" "refs/heads/$branch" | cut -f1)
  [ "$now" = "$sha" ] || fail "after the push, origin/$branch is '$now', not $sha"
  ok "origin/$branch = $sha"
}

# --- beta ----------------------------------------------------------------------------------

promote_beta() {
  local main beta_tip stable_tip target v sv tree new hot c listed=0
  main=$(tip main)
  [ -n "$main" ] || fail "origin/main does not exist"
  beta_tip=$(tip beta)
  stable_tip=$(tip stable)
  target=$(resolve "${want_rev:-$main}")

  step "Target: origin/main commit $target"
  info "$(g log -1 --format='%s (%an, %ad)' --date=short "$target")"
  if is_ancestor "$target" "$main"; then ok "it is on origin/main"; else fail "$target is not on origin/main"; fi
  if [ -z "$beta_tip" ]; then
    [ "$bootstrap" = 1 ] || fail "origin/beta does not exist. The first beta release needs --bootstrap."
    warn "BOOTSTRAP: there is no beta branch. The only parent of the release commit is main."
  else
    [ "$bootstrap" = 0 ] || fail "--bootstrap: origin/beta already exists ($beta_tip)"
    ! is_ancestor "$target" "$beta_tip" || fail "${target:0:12} is already on beta"
    ok "previous beta tip: $beta_tip"
  fi

  ci_check "$target" "the main commit (unstable base)"

  step "Version"
  v=$(version_at "$target")
  [[ $v =~ $semver_re ]] || fail "release/version of the target is '${v:-<missing>}'. It must be MAJOR.MINOR.PATCH."
  if [ -n "$stable_tip" ]; then
    sv=$(version_at "$stable_tip")
    [ "$v" = "$sv" ] \
      || fail "release/version of the target is $v. Stable is $sv. Main must have the stable version: merge stable into main. Only promote changes the version."
    ok "release/version = $v (the stable version this beta starts from)"
  else
    ok "release/version = $v (there is no stable release)"
  fi
  info "a box shows this release as $v.<release commit> beta"

  step "Hotfixes and stable releases on main"
  hot=()
  for b in beta stable; do [ -z "$(tip "$b")" ] || hot+=("refs/heads/$b"); done
  if [ "${#hot[@]}" -eq 0 ]; then
    ok "there is no beta or stable branch"
  else
    while read -r c; do
      [ -n "$c" ] || continue
      # Release commits that only re-point a tree (the bootstrap commit) change nothing.
      [ "$(g rev-parse "$c^{tree}")" != "$(g rev-parse "$c^1^{tree}" 2>/dev/null)" ] || continue
      warn "not on main: ${c:0:12} $(g log -1 --format=%s "$c")"
      listed=1
    done < <(g rev-list --no-merges "${hot[@]}" --not "$target")
    [ "$listed" = 0 ] || fail "merge stable (and beta) into main. Then release that main commit."
    ok "all commits on ${hot[*]#refs/heads/} are in the target"
  fi

  step "Changes"
  if [ -n "$beta_tip" ]; then
    list_changes "$beta_tip..$target"
    lock_changes "$beta_tip" "$target"
  else
    lock_changes "" "$target"
  fi

  step "Security"
  if [ -n "$beta_tip" ]; then scan_security "$beta_tip..$target"; else scan_security "$target" --max-count=200; fi
  choose_security "$range_sev"

  step "Release notes"
  notes_of "$target"
  review_notes
  if [ "$notes_edited" = 1 ]; then
    info "the change is only in the message of this beta. release/notes.md on main does not change."
  fi
  compose_message "$v beta"

  step "Signers that verify the result"
  if [ -n "$beta_tip" ]; then
    info "release/allowed_signers of the current beta (a box on beta trusts these keys)"
    signers_of "$beta_tip" "$tmp/verify.signers"
  else
    warn "BOOTSTRAP: there is no beta, so the signers come from the NEW tree."
    warn "This only shows that a key of this release signed the commit."
    warn "A box trusts it one time, with hinteros-bootstrap-channel and the rev below."
    signers_of "$target" "$tmp/verify.signers"
  fi
  key_preflight "$tmp/verify.signers"

  tree=$(g rev-parse "$target^{tree}")
  if [ -n "$beta_tip" ]; then
    info "the release commit: tree of $target, parents $beta_tip (beta) and $target (main)"
    review_and_sign beta "HinterOS $v.<commit> beta" "$tree" -p "$beta_tip" -p "$target"
  else
    info "the release commit: tree of $target, one parent $target (main)"
    review_and_sign beta "HinterOS $v.<commit> beta" "$tree" -p "$target"
  fi

  step "Checks on the result"
  [ "$(g rev-parse "$new^{tree}")" = "$tree" ] || fail "the tree of the result is not $tree"
  ok "the tree is the same as the tested main commit ($tree)"
  if [ -n "$beta_tip" ]; then
    is_ancestor "$beta_tip" "$new" || fail "not a fast-forward from $beta_tip"
    ok "fast-forward from the current beta"
  fi
  if [ -n "$stable_tip" ]; then
    is_ancestor "$stable_tip" "$new" || fail "origin/stable ($stable_tip) is not an ancestor of the result"
    ok "origin/stable is an ancestor of the result"
  else
    info "there is no origin/stable"
  fi
  if [ "$dry_run" = 1 ]; then
    info "dry run: no signature to verify"
  else
    verify "$new" "$tmp/verify.signers"
  fi

  push_branch "$new" beta

  step "Done"
  if [ "$dry_run" = 1 ]; then
    info "dry run: no change to beta"
  else
    ok "beta is HinterOS $v.${new:0:7} beta: $new"
    info "to move a box to beta one time: sudo hinteros-bootstrap-channel beta $new"
    info "test it on box #2. Then run nix run .#promote again for stable."
    if [ "$notes_edited" = 1 ]; then info "for stable, put the changed notes in release/notes.md on main"; fi
  fi
}

# --- stable --------------------------------------------------------------------------------

# A beta release commit's subject: `HinterOS <version> beta`, or `HinterOS <version>` from before
# betas kept the stable version (the first beta, 0.7.0, was promoted that way).
is_beta_release() {
  local s v
  v=$(version_at "$1")
  s=$(g log -1 --format=%s "$1")
  [ "$s" = "HinterOS $v beta" ] || [ "$s" = "HinterOS $v" ]
}

promote_stable() {
  local beta_tip stable_tip target v sv="" tree new
  beta_tip=$(tip beta)
  stable_tip=$(tip stable)
  [ -n "$beta_tip" ] || fail "origin/beta does not exist. Release main to beta first."
  target=$(resolve "${want_rev:-$beta_tip}")

  step "Target: beta release commit $target"
  if g rev-list --first-parent "$beta_tip" | grep -x "$target" >/dev/null; then
    ok "it is a release commit on origin/beta"
  else
    fail "$target is not a release commit on origin/beta. Only beta releases go to stable."
  fi
  v=$(version_at "$target")
  [[ $v =~ $semver_re ]] || fail "release/version of the target is '${v:-<missing>}'"
  is_beta_release "$target" \
    || fail "the subject is '$(g log -1 --format=%s "$target")'. It must be 'HinterOS $v beta'."
  ok "beta release commit: HinterOS $v.${target:0:7} beta"
  g cat-file commit "$target" | grep '^gpgsig ' >/dev/null || fail "$target is not signed"
  ok "it has a signature"

  if [ -n "$stable_tip" ]; then
    is_ancestor "$target" "$stable_tip" && fail "origin/stable already contains $target"
    is_ancestor "$stable_tip" "$target" \
      || fail "origin/stable ($stable_tip) is not an ancestor. A stable release is not on beta: merge stable into main, then release main to beta."
    ok "origin/stable $stable_tip is an ancestor"
    sv=$(version_at "$stable_tip")
    [[ $sv =~ $semver_re ]] || fail "stable's release/version is '${sv:-<missing>}'"
  else
    warn "origin/stable does not exist. This release makes it."
  fi

  ci_check "$target" "the beta release (both bases)"

  step "Changes since the last stable release"
  if [ -n "$stable_tip" ]; then
    list_changes "$stable_tip..$target"
  else
    info "$(g rev-list --no-merges --count "$target") commit(s): all commits"
  fi
  lock_changes "$stable_tip" "$target"

  step "Security (from the beta releases)"
  if [ -n "$stable_tip" ]; then scan_security "$stable_tip..$target"; else scan_security "$target" --max-count=200; fi
  release_sev=$range_sev
  ok "severity of this stable release: $release_sev"

  step "Release notes"
  # A beta from before betas kept the stable version has its section named already.
  notes_of "$target" "$v"
  review_notes

  step "Version"
  choose_version "$v" "$sv"
  compose_message "$new_version"

  step "Test on box #2"
  if [ "$interactive" = 1 ]; then
    case "$release_sev" in
      high | critical)
        pick "This is a $release_sev security release. Select the test on box #2:" 1 \
          "Normal: all couch checklists passed" \
          "Expedite: it ran for 1 hour or more with no problems"
        [ "$picked" = 1 ] || expedite=1
        ;;
    esac
  fi
  if [ "$expedite" = 1 ]; then
    case "$release_sev" in
      high | critical) ok "--expedite with a $release_sev release" ;;
      *) fail "--expedite is only for Security: high or critical releases. This release is $release_sev." ;;
    esac
    confirm "Did box #2 run HinterOS $v.${target:0:7} beta for 1 hour or more with no problems?"
  else
    confirm "Did box #2 run HinterOS $v.${target:0:7} beta and pass the couch checklists for the changes?"
  fi

  step "Signers that verify the result"
  if [ -n "$stable_tip" ]; then
    info "release/allowed_signers of the current stable (a box on stable trusts these keys)"
    signers_of "$stable_tip" "$tmp/verify.signers"
  else
    warn "there is no stable, so the signers come from the OWN release/allowed_signers of the target."
    warn "A box trusts the first stable from the ISO or hinteros-bootstrap-channel."
    signers_of "$target" "$tmp/verify.signers"
  fi
  key_preflight "$tmp/verify.signers"

  tree=$(versioned_tree "$target" "$new_version")
  info "the release commit: the tree of the beta release with release/version $new_version, one parent $target (beta)"
  review_and_sign stable "HinterOS $new_version stable" "$tree" -p "$target"

  step "Checks on the result"
  only_version_changed "$new" "$target"
  [ "$(version_at "$new")" = "$new_version" ] || fail "release/version of the result is not $new_version"
  ok "release/version = $new_version"
  if [ -n "$stable_tip" ]; then
    is_ancestor "$stable_tip" "$new" || fail "not a fast-forward from $stable_tip"
    ok "fast-forward from origin/stable"
  fi
  if [ "$dry_run" = 1 ]; then
    info "dry run: no signature to verify"
  else
    verify "$new" "$tmp/verify.signers"
  fi

  push_branch "$new" stable

  step "Done"
  if [ "$dry_run" = 1 ]; then
    info "dry run: no change to stable"
  else
    ok "stable is HinterOS $new_version stable: $new"
  fi
  info "next: merge stable into main. Then release/version on main is $new_version."
  info "Add a new '## Unreleased' section to release/notes.md before the next beta."
  # TODO(M6 phase 3, ISO publishing): wait for CI's stable ISO, fetch its SHA256SUMS, create the
  # signed tag v<version> carrying them (git tag -s with the release key, no agent), push it and,
  # with a Forgejo token in the environment, create the release page.
  warn "TODO: the script does not make the signed tag v$new_version (ISO SHA256SUMS) or the release page."
}

# --- hotfix --------------------------------------------------------------------------------

promote_hotfix() {
  local stable_tip hot target sv tree new
  stable_tip=$(tip stable)
  [ -n "$stable_tip" ] || fail "origin/stable does not exist"
  case "$hotfix_branch" in hotfix/*) ;; *) warn "branch '$hotfix_branch' is not named hotfix/<name>" ;; esac
  hot=$(tip "$hotfix_branch")
  [ -n "$hot" ] || fail "origin/$hotfix_branch does not exist"
  target=$(resolve "${want_rev:-$hot}")

  step "Target: $hotfix_branch commit $target"
  info "$(g log -1 --format='%s (%an, %ad)' --date=short "$target")"
  is_ancestor "$target" "$hot" || fail "$target is not on origin/$hotfix_branch"
  is_ancestor "$stable_tip" "$target" \
    || fail "$hotfix_branch does not start from the current origin/stable ($stable_tip). Rebase it."
  [ "$target" != "$stable_tip" ] || fail "$hotfix_branch has no commits after stable"
  ok "starts from origin/stable $stable_tip ($(g rev-list --count "$stable_tip..$target") commit(s) after it)"

  ci_check "$target" "the hotfix (both bases)"

  step "Changes"
  list_changes "$stable_tip..$target"
  lock_changes "$stable_tip" "$target"

  step "Security"
  scan_security "$stable_tip..$target"
  choose_security "$range_sev"
  if [ "$release_sev" = none ]; then
    if [ "$dry_run" = 1 ]; then
      warn "a hotfix must have a Security severity. A real run stops with none."
    else
      fail "a hotfix must have a Security severity: low, medium, high or critical"
    fi
  fi

  step "Release notes"
  notes_of "$target"
  review_notes

  step "Version"
  sv=$(version_at "$stable_tip")
  [[ $sv =~ $semver_re ]] || fail "stable's release/version is '${sv:-<missing>}'"
  [ "$(version_at "$target")" = "$sv" ] \
    || fail "the hotfix changes release/version to $(version_at "$target"). Keep it at $sv. The script sets the version."
  new_version=$(bump "$sv" patch)
  ok "a hotfix is a patch release: $sv -> $new_version"
  confirm "Release this hotfix as HinterOS $new_version stable?"
  compose_message "$new_version"

  step "Signers that verify the result"
  info "release/allowed_signers of the current stable (a box on stable trusts these keys)"
  signers_of "$stable_tip" "$tmp/verify.signers"
  key_preflight "$tmp/verify.signers"

  tree=$(versioned_tree "$target" "$new_version")
  info "the release commit: tree of $target with release/version $new_version, one parent $stable_tip (stable)"
  review_and_sign stable "HinterOS $new_version stable (hotfix)" "$tree" -p "$stable_tip"

  step "Checks on the result"
  only_version_changed "$new" "$target"
  is_ancestor "$stable_tip" "$new" || fail "not a fast-forward from $stable_tip"
  ok "fast-forward from origin/stable"
  if [ "$dry_run" = 1 ]; then
    info "dry run: no signature to verify"
  else
    verify "$new" "$tmp/verify.signers"
  fi

  push_branch "$new" stable

  step "Done"
  if [ "$dry_run" = 1 ]; then
    info "dry run: no change to stable"
  else
    ok "stable is HinterOS $new_version stable: $new"
  fi
  info "next: merge stable into main. Let CI run. Then release main to beta."
  info "Before that, a stable release stops, and beta boxes see stable as not a fast-forward."
}

# --- menus (no mode given) -----------------------------------------------------------------

# One line per channel branch: where it is and what a box calls it.
describe_branch() {
  local b=$1 r v n
  r=$(tip "$b")
  if [ -z "$r" ]; then
    printf '  %-7s does not exist\n' "$b"
    return 0
  fi
  v=$(version_at "$r")
  case "$b" in
    main)
      if [ -n "$(tip beta)" ]; then n=$(g rev-list --no-merges --count "refs/heads/beta..$r"); else n=$(g rev-list --no-merges --count "$r"); fi
      printf '  %-7s %s  release/version %s, %s commit(s) not on beta. Last: %s\n' "$b" "${r:0:7}" "${v:-?}" "$n" \
        "$(g log -1 --format=%s "$r")"
      ;;
    beta) printf '  %-7s %s  HinterOS %s.%s beta (%s)\n' "$b" "${r:0:7}" "${v:-?}" "${r:0:7}" "$(g log -1 --format=%cs "$r")" ;;
    stable) printf '  %-7s %s  HinterOS %s stable (%s)\n' "$b" "${r:0:7}" "${v:-?}" "$(g log -1 --format=%cs "$r")" ;;
  esac
}

# Asks what to release where and which commit; sets $mode, $want_rev, $hotfix_branch,
# $bootstrap and, if the default key file is missing, $key.
choose_release() {
  local main beta_tip stable_tip labels=() modes=() revs=() names=() c b
  main=$(tip main)
  beta_tip=$(tip beta)
  stable_tip=$(tip stable)
  step "Channels"
  for b in main beta stable; do describe_branch "$b"; done
  mapfile -t names < <(g for-each-ref --format='%(refname:short)' refs/heads/hotfix/)

  if [ -n "$main" ] && { [ -z "$beta_tip" ] || ! is_ancestor "$main" "$beta_tip"; }; then
    labels+=("Release main to beta")
    modes+=(beta)
  fi
  if [ -n "$beta_tip" ] && { [ -z "$stable_tip" ] || ! is_ancestor "$beta_tip" "$stable_tip"; }; then
    labels+=("Release beta to stable")
    modes+=(stable)
  fi
  if [ -n "$stable_tip" ] && [ "${#names[@]}" -gt 0 ]; then
    labels+=("Release a hotfix branch to stable")
    modes+=(hotfix)
  fi
  [ "${#modes[@]}" -gt 0 ] || fail "nothing to release. Beta has all of main, and stable has all of beta."
  pick "Select the release:" 1 "${labels[@]}"
  mode=${modes[picked - 1]}

  case "$mode" in
    beta)
      labels=()
      revs=()
      while read -r c; do
        [ -z "$beta_tip" ] || ! is_ancestor "$c" "$beta_tip" || break
        revs+=("$c")
        labels+=("$(g log -1 --format='%h %s (%cs)' "$c")")
      done < <(g rev-list --first-parent --max-count=10 "$main")
      pick "Select the main commit for beta (newest first):" 1 "${labels[@]}"
      want_rev=${revs[picked - 1]}
      if [ -z "$beta_tip" ]; then
        bootstrap=1
        info "there is no beta branch. This release makes it."
      fi
      ;;
    stable)
      labels=()
      revs=()
      while read -r c; do
        [ -z "$stable_tip" ] || ! is_ancestor "$c" "$stable_tip" || break
        # Below the first beta release the first-parent chain is main's history.
        is_beta_release "$c" || break
        revs+=("$c")
        labels+=("HinterOS $(version_at "$c").${c:0:7} beta ($(g log -1 --format=%cs "$c"))")
        [ "${#revs[@]}" -lt 10 ] || break
      done < <(g rev-list --first-parent "$beta_tip")
      pick "Select the beta release for stable (newest first):" 1 "${labels[@]}"
      want_rev=${revs[picked - 1]}
      ;;
    hotfix)
      labels=()
      for b in "${names[@]}"; do labels+=("$b: $(g log -1 --format='%h %s (%cs)' "refs/heads/$b")"); done
      pick "Select the hotfix branch:" 1 "${labels[@]}"
      hotfix_branch=${names[picked - 1]}
      ;;
  esac

  if [ "$dry_run" = 0 ] && [ ! -f "$key" ]; then
    warn "the signing key $key does not exist"
    read -r -p "  Signing key file: " key || fail "no key"
    key=${key/#\~/$HOME}
    case "$key" in /*) ;; *) key=$PWD/$key ;; esac
  fi
}

if [ "$interactive" = 1 ]; then choose_release; fi

case "$mode" in
  beta) promote_beta ;;
  stable) promote_stable ;;
  hotfix) promote_hotfix ;;
esac
