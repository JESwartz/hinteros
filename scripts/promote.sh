# promote: move a HinterOS channel (hinteros-docs/design/distribution.md, "The release pipeline",
# "Promote script checks"). Run by the owner on the dev machine:
#
#   nix run .#promote -- beta   [--rev <main commit>] [--bootstrap] [--security <sev>]
#   nix run .#promote -- stable [--rev <beta release commit>] [--expedite]
#   nix run .#promote -- hotfix <branch> [--rev <commit>] [--security <sev>]
#   common: [--dry-run] [--skip-ci] [--key <path>] [--yes]
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
usage: promote beta   [--rev <sha>] [--bootstrap] [--security <sev>] [options]
       promote stable [--rev <sha>] [--expedite] [options]
       promote hotfix <branch> [--rev <sha>] [--security <sev>] [options]
options: --dry-run  --skip-ci  --key <path>  --yes
  --dry-run    everything except signing and pushing
  --skip-ci    do not require green Forgejo commit statuses (until the CI runner exists)
  --key        signing key file (default $HINTEROS_RELEASE_KEY or ~/.ssh/hinteros/release_ed25519)
  --security   none|low|medium|high|critical: the release's Security trailer (otherwise asked)
  --bootstrap  first beta release: no previous beta tip to verify against
  --expedite   stable: a high/critical release after an hour on box #2
  --yes        answer the confirmation questions with yes (non-interactive use)
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
  printf '\npromote: refused, nothing was signed or pushed.\n' >&2
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
key=${HINTEROS_RELEASE_KEY:-$HOME/.ssh/hinteros/release_ed25519}

[ "$#" -gt 0 ] || {
  usage >&2
  exit 2
}
case "$1" in
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
[ "$bootstrap" = 0 ] || [ "$mode" = beta ] || die "--bootstrap only applies to promote beta"
[ "$expedite" = 0 ] || [ "$mode" = stable ] || die "--expedite only applies to promote stable"
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
  printf 'promote %s: DRY RUN (nothing is signed or pushed)\n' "$mode"
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/promote.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
repo=$tmp/repo
g() { git -C "$repo" "$@"; }

step "Fetching $url"
clone_args=(--bare --quiet)
[ -z "$local_repo" ] || clone_args+=(--reference-if-able "$local_repo" --dissociate)
git clone "${clone_args[@]}" "$url" "$repo" || fail "could not clone $url"
ok "fresh clone in a temporary directory; every ref below is the remote's (origin/*)"
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
  [ "$n" -gt 0 ] || fail "release/allowed_signers of $rev lists no key: no box could verify anything"
  info "$n key(s) in release/allowed_signers of ${rev:0:12}: $(cut -d' ' -f1 "$out" | tr '\n' ' ')"
}

# Is the signing key's public half in a signers file? Only the .pub file is read.
key_preflight() {
  local signers=$1 pub
  if [ ! -f "$key" ]; then
    if [ "$dry_run" = 1 ]; then
      warn "signing key $key does not exist (a real run needs it)"
      return 0
    fi
    fail "signing key $key does not exist (--key or HINTEROS_RELEASE_KEY)"
  fi
  if [ ! -f "$key.pub" ]; then
    info "no $key.pub next to the key: cannot check in advance that it is listed"
    return 0
  fi
  pub=$(cut -d' ' -f1,2 "$key.pub")
  if grep -qF " $pub" "$signers"; then
    ok "signing key $key is listed as: $(grep -F " $pub" "$signers" | cut -d' ' -f1)"
  else
    fail "the public half of $key is not in the allowed_signers the result is verified against"
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
    fail "${rev:0:12} does not verify against these signers: a box would reject it (unknown_signer)"
  fi
}

# Forgejo's combined commit status must be success, unless --skip-ci.
ci_check() {
  local sha=$1 what=$2 json state total
  step "CI status of $what ${sha:0:12}"
  if [ "$skip_ci" = 1 ]; then
    warn "************************************************************************"
    warn "CI CHECK SKIPPED (--skip-ci): nothing has tested ${sha:0:12} for you."
    warn "Run the checks yourself before promoting (TESTING.md), and drop --skip-ci"
    warn "once the Forgejo runner exists."
    warn "************************************************************************"
    return 0
  fi
  if [ -n "${PROMOTE_STATUS_CMD:-}" ]; then
    json=$("$PROMOTE_STATUS_CMD" "$sha") || fail "PROMOTE_STATUS_CMD failed for $sha"
  else
    [ -n "$api" ] && [ -n "$api_repo" ] \
      || fail "cannot derive the Forgejo API from $url: set PROMOTE_FORGEJO_API and PROMOTE_FORGEJO_REPO, or pass --skip-ci"
    info "GET $api/repos/$api_repo/commits/$sha/status"
    json=$(curl -fsS --max-time 30 "$api/repos/$api_repo/commits/$sha/status") \
      || fail "could not read the commit status from Forgejo"
  fi
  total=$(jq -r '.total_count // 0' <<<"$json")
  state=$(jq -r '.state // ""' <<<"$json")
  if [ "$total" = 0 ]; then
    fail "no CI statuses at all for ${sha:0:12}. There is no CI runner yet: pass --skip-ci until it exists (and test by hand)."
  fi
  jq -r '.statuses[] | "  [ci]   \(.context): \(.status)\(if .description then " (\(.description))" else "" end)"' <<<"$json"
  if [ "$state" != success ]; then
    fail "CI is '$state', not success. 'pending'/'Waiting to run' means no runner picked the job up: pass --skip-ci until the runner exists."
  fi
  ok "all $total CI statuses are success"
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
      warn "--security $security is lower than the highest trailer in range ($default)"
    fi
  elif [ "$dry_run" = 1 ] || [ ! -t 0 ]; then
    release_sev=$default
    info "would ask for the release severity (default: $default); using $default"
    [ "$dry_run" = 1 ] || fail "not interactive: pass --security"
  else
    read -r -p "  Security severity of this release [none/low/medium/high/critical] (default $default): " ans
    release_sev=${ans:-$default}
    case "$release_sev" in
      none | low | medium | high | critical) ;;
      *) fail "not a severity: $release_sev" ;;
    esac
  fi
  ok "release severity: $release_sev"
}

confirm() {
  local ans
  if [ "$assume_yes" = 1 ]; then
    ok "$1 yes (--yes)"
  elif [ "$dry_run" = 1 ]; then
    info "would ask: $1"
  elif [ -t 0 ]; then
    read -r -p "  $1 [y/N] " ans
    case "$ans" in
      y | Y | yes) ok "confirmed" ;;
      *) fail "not confirmed" ;;
    esac
  else
    fail "not interactive: '$1' needs --yes"
  fi
}

# The top section of release/notes.md (under the first "## <version>" heading), which must be
# for $2.
notes_of() {
  local rev=$1 version=$2 heading
  g show "$rev:release/notes.md" >"$tmp/notes.md" 2>/dev/null || fail "$rev has no release/notes.md"
  heading=$(grep -m1 '^## ' "$tmp/notes.md" | sed -e 's/^## *//' -e 's/[[:space:]]*$//') || true
  [ "$heading" = "$version" ] \
    || fail "release/notes.md: the top section is '## ${heading:-<none>}', release/version is $version"
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

# Creates the release commit (signed; unsigned with --dry-run) and prints its hash.
make_commit() {
  local tree=$1
  shift
  if [ "$dry_run" = 1 ]; then
    g commit-tree "$tree" "$@" -F "$tmp/msg"
  else
    env -u SSH_AUTH_SOCK git -C "$repo" -c gpg.format=ssh -c gpg.ssh.program=ssh-keygen \
      -c "user.signingkey=$key" commit-tree -S "$tree" "$@" -F "$tmp/msg"
  fi
}

show_commit() {
  local sha=$1
  if [ "$dry_run" = 1 ]; then
    step "The commit that would be signed (shown unsigned)"
  else
    step "The signed release commit $sha"
  fi
  # The headers without the signature block, then the message as is.
  g cat-file -p "$sha" | awk '
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
  g "${cred_args[@]}" push "$url" "$sha:refs/heads/$branch" || fail "push refused (someone moved $branch? it is never forced)"
  now=$(git ls-remote "$url" "refs/heads/$branch" | cut -f1)
  [ "$now" = "$sha" ] || fail "after the push, origin/$branch is '$now', not $sha"
  ok "origin/$branch = $sha"
}

# --- beta ----------------------------------------------------------------------------------

promote_beta() {
  local main beta_tip stable_tip target v bv sv tree new hot c listed=0
  main=$(tip main)
  [ -n "$main" ] || fail "origin/main does not exist"
  beta_tip=$(tip beta)
  stable_tip=$(tip stable)
  target=$(resolve "${want_rev:-$main}")

  step "Target: origin/main commit $target"
  info "$(g log -1 --format='%s (%an, %ad)' --date=short "$target")"
  if is_ancestor "$target" "$main"; then ok "it is on origin/main"; else fail "$target is not on origin/main"; fi
  if [ -z "$beta_tip" ]; then
    [ "$bootstrap" = 1 ] || fail "origin/beta does not exist yet: the first beta release needs --bootstrap"
    warn "BOOTSTRAP: no previous beta tip. The release commit's only parent is main."
  else
    [ "$bootstrap" = 0 ] || fail "--bootstrap, but origin/beta already exists ($beta_tip)"
    ok "previous beta tip: $beta_tip"
  fi

  ci_check "$target" "the main commit (unstable base)"

  step "Version"
  v=$(version_at "$target")
  [[ $v =~ $semver_re ]] || fail "release/version of the target is '${v:-<missing>}', not MAJOR.MINOR.PATCH"
  ok "release/version = $v"
  if [ -n "$beta_tip" ]; then
    bv=$(version_at "$beta_tip")
    [ "$v" != "$bv" ] || fail "release/version $v is the current beta's: bump it (every beta release has a new version)"
    if [[ $bv =~ $semver_re ]]; then
      semver_gt "$v" "$bv" || fail "release/version $v is not greater than beta's $bv"
      ok "$v > beta's $bv"
    else
      info "beta's tip has no valid release/version ('$bv')"
    fi
  fi
  if [ -n "$stable_tip" ]; then
    sv=$(version_at "$stable_tip")
    if [[ $sv =~ $semver_re ]]; then
      semver_gt "$v" "$sv" || fail "release/version $v is not greater than stable's $sv"
      ok "$v > stable's $sv"
    fi
  fi

  step "Hotfixes on beta/stable are on main"
  hot=()
  for b in beta stable; do [ -z "$(tip "$b")" ] || hot+=("refs/heads/$b"); done
  if [ "${#hot[@]}" -eq 0 ]; then
    ok "no beta or stable branch yet"
  else
    while read -r c; do
      [ -n "$c" ] || continue
      # Release commits that only re-point a tree (the bootstrap commit) change nothing.
      [ "$(g rev-parse "$c^{tree}")" != "$(g rev-parse "$c^1^{tree}" 2>/dev/null)" ] || continue
      warn "not on main: ${c:0:12} $(g log -1 --format=%s "$c")"
      listed=1
    done < <(g rev-list --no-merges "${hot[@]}" --not "$target")
    [ "$listed" = 0 ] || fail "merge stable (and beta) into main first, then promote that main commit"
    ok "every commit on ${hot[*]#refs/heads/} is reachable from the target"
  fi

  step "Changes"
  if [ -n "$beta_tip" ]; then
    info "$(g rev-list --count "$beta_tip..$target") commit(s) since the last beta release"
    lock_changes "$beta_tip" "$target"
  else
    lock_changes "" "$target"
  fi

  step "Security"
  if [ -n "$beta_tip" ]; then scan_security "$beta_tip..$target"; else scan_security "$target" --max-count=200; fi
  choose_security "$range_sev"

  step "Release notes"
  notes_of "$target" "$v"
  compose_message "$v"

  step "Signers the result is verified against"
  if [ -n "$beta_tip" ]; then
    info "the previous beta tip's release/allowed_signers (what a box on beta trusts)"
    signers_of "$beta_tip" "$tmp/verify.signers"
  else
    warn "BOOTSTRAP: no previous tip, so the NEW tree's own release/allowed_signers is used."
    warn "That only proves the commit is signed by a key this release lists; boxes take it on"
    warn "trust once, via hinteros-bootstrap-channel and the rev printed below."
    signers_of "$target" "$tmp/verify.signers"
  fi
  key_preflight "$tmp/verify.signers"

  step "Release commit"
  tree=$(g rev-parse "$target^{tree}")
  if [ -n "$beta_tip" ]; then
    info "tree of $target, parents $beta_tip (beta) and $target (main)"
    [ "$dry_run" = 1 ] || info "signing with $key: ssh-keygen asks for the passphrase"
    new=$(make_commit "$tree" -p "$beta_tip" -p "$target") || fail "signing failed"
  else
    info "tree of $target, single parent $target (main)"
    [ "$dry_run" = 1 ] || info "signing with $key: ssh-keygen asks for the passphrase"
    new=$(make_commit "$tree" -p "$target") || fail "signing failed"
  fi
  show_commit "$new"

  step "Checks on the result"
  [ "$(g rev-parse "$new^{tree}")" = "$tree" ] || fail "the result's tree is not $tree"
  ok "tree equals the tested main commit's ($tree)"
  if [ -n "$beta_tip" ]; then
    is_ancestor "$beta_tip" "$new" || fail "not a fast-forward from $beta_tip"
    ok "fast-forward from the previous beta tip"
  fi
  if [ -n "$stable_tip" ]; then
    is_ancestor "$stable_tip" "$new" || fail "origin/stable ($stable_tip) is not an ancestor of the result"
    ok "origin/stable is an ancestor of the result"
  else
    info "no origin/stable yet"
  fi
  if [ "$dry_run" = 1 ]; then
    info "would verify the signed commit against the signers above"
  else
    verify "$new" "$tmp/verify.signers"
  fi

  push_branch "$new" beta

  step "Done"
  if [ "$dry_run" = 1 ]; then
    info "dry run: beta would get a signed HinterOS $v commit with the tree above"
  else
    ok "beta is HinterOS $v: $new"
    info "move a box onto beta (once): sudo hinteros-bootstrap-channel beta $new"
    info "then dogfood on box #2 and run: nix run .#promote -- stable"
  fi
}

# --- stable --------------------------------------------------------------------------------

promote_stable() {
  local beta_tip stable_tip target v sv
  beta_tip=$(tip beta)
  stable_tip=$(tip stable)
  [ -n "$beta_tip" ] || fail "origin/beta does not exist: promote beta first"
  target=$(resolve "${want_rev:-$beta_tip}")

  step "Target: beta release commit $target"
  if g rev-list --first-parent "$beta_tip" | grep -qx "$target"; then
    ok "it is on origin/beta's first-parent chain"
  else
    fail "$target is not a first-parent commit of origin/beta (only beta release commits can go to stable)"
  fi
  v=$(version_at "$target")
  [[ $v =~ $semver_re ]] || fail "release/version of the target is '${v:-<missing>}'"
  [ "$(g log -1 --format=%s "$target")" = "HinterOS $v" ] \
    || fail "subject is '$(g log -1 --format=%s "$target")', not 'HinterOS $v': not a release commit"
  ok "release commit: HinterOS $v"
  g cat-file commit "$target" | grep -q '^gpgsig ' || fail "$target is not signed"
  ok "it carries a signature"

  if [ -n "$stable_tip" ]; then
    [ "$target" != "$stable_tip" ] || fail "origin/stable is already $target"
    is_ancestor "$stable_tip" "$target" \
      || fail "origin/stable ($stable_tip) is not an ancestor: a hotfix is not on beta yet (merge stable into main, promote beta)"
    ok "fast-forward from origin/stable $stable_tip"
    sv=$(version_at "$stable_tip")
    info "stable goes from ${sv:-?} to $v"
  else
    warn "origin/stable does not exist yet: it is created at $target"
  fi

  ci_check "$target" "the beta release (both bases)"

  step "Security (inherited from the beta releases)"
  if [ -n "$stable_tip" ]; then scan_security "$stable_tip..$target"; else scan_security "$target" --max-count=200; fi
  release_sev=$range_sev
  ok "severity of this stable release: $release_sev"

  step "Changes"
  lock_changes "$stable_tip" "$target"

  step "Dogfood"
  if [ "$expedite" = 1 ]; then
    case "$release_sev" in
      high | critical) ok "--expedite with a $release_sev release" ;;
      *) fail "--expedite is only for Security: high or critical releases (this is $release_sev)" ;;
    esac
    confirm "Has box #2 run HinterOS $v ($target) for at least an hour without problems?"
  else
    confirm "Has box #2 run HinterOS $v ($target) and passed the couch checklists for the changes?"
  fi

  step "Signature"
  if [ -n "$stable_tip" ]; then
    info "against the current stable tip's release/allowed_signers (what a box on stable trusts)"
    signers_of "$stable_tip" "$tmp/verify.signers"
  else
    warn "no previous stable tip: verifying against the target's OWN release/allowed_signers;"
    warn "boxes take the first stable on trust (ISO or hinteros-bootstrap-channel)."
    signers_of "$target" "$tmp/verify.signers"
  fi
  verify "$target" "$tmp/verify.signers"

  push_branch "$target" stable

  step "Done"
  if [ "$dry_run" = 1 ]; then
    info "dry run: stable would move to HinterOS $v ($target)"
  else
    ok "stable is HinterOS $v: $target"
  fi
  # TODO(M6 phase 3, ISO publishing): wait for CI's stable ISO, fetch its SHA256SUMS, create the
  # signed tag v<version> carrying them (git tag -s with the release key, no agent), push it and,
  # with a Forgejo token in the environment, create the release page.
  warn "TODO: the signed tag v$v with the ISO's SHA256SUMS and the release page are not automated yet."
}

# --- hotfix --------------------------------------------------------------------------------

promote_hotfix() {
  local stable_tip hot target v sv tree new
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
    || fail "$hotfix_branch is not based on the current origin/stable ($stable_tip): rebase it"
  [ "$target" != "$stable_tip" ] || fail "$hotfix_branch has nothing on top of stable"
  ok "based on origin/stable $stable_tip ($(g rev-list --count "$stable_tip..$target") commit(s) on top)"

  ci_check "$target" "the hotfix (both bases)"

  step "Version"
  v=$(version_at "$target")
  sv=$(version_at "$stable_tip")
  [[ $v =~ $semver_re ]] || fail "release/version of the target is '${v:-<missing>}'"
  [[ $sv =~ $semver_re ]] || fail "stable's release/version is '${sv:-<missing>}'"
  if [ "${v%.*}" != "${sv%.*}" ] || ! semver_gt "$v" "$sv"; then
    fail "release/version $v is not a patch bump of stable's $sv"
  fi
  ok "$sv -> $v (patch bump)"

  step "Changes"
  lock_changes "$stable_tip" "$target"

  step "Security"
  scan_security "$stable_tip..$target"
  choose_security "$range_sev"
  if [ "$release_sev" = none ]; then
    if [ "$dry_run" = 1 ]; then
      warn "a hotfix needs a Security severity (a real run refuses none)"
    else
      fail "a hotfix needs a Security severity (low, medium, high or critical)"
    fi
  fi

  step "Release notes"
  notes_of "$target" "$v"
  compose_message "$v"

  step "Signers the result is verified against"
  info "the current stable tip's release/allowed_signers (what a box on stable trusts)"
  signers_of "$stable_tip" "$tmp/verify.signers"
  key_preflight "$tmp/verify.signers"

  step "Release commit"
  tree=$(g rev-parse "$target^{tree}")
  info "tree of $target, single parent $stable_tip (stable)"
  [ "$dry_run" = 1 ] || info "signing with $key: ssh-keygen asks for the passphrase"
  new=$(make_commit "$tree" -p "$stable_tip") || fail "signing failed"
  show_commit "$new"

  step "Checks on the result"
  [ "$(g rev-parse "$new^{tree}")" = "$tree" ] || fail "the result's tree is not $tree"
  ok "tree equals the hotfix commit's ($tree)"
  is_ancestor "$stable_tip" "$new" || fail "not a fast-forward from $stable_tip"
  ok "fast-forward from origin/stable"
  if [ "$dry_run" = 1 ]; then
    info "would verify the signed commit against the signers above"
  else
    verify "$new" "$tmp/verify.signers"
  fi

  push_branch "$new" stable

  step "Done"
  if [ "$dry_run" = 1 ]; then
    info "dry run: stable would get a signed HinterOS $v hotfix commit"
  else
    ok "stable is HinterOS $v: $new"
  fi
  info "next: merge stable into main (ordinary merge), let CI run, then promote beta;"
  info "until then promote stable refuses and beta boxes see stable as not a fast-forward."
}

case "$mode" in
  beta) promote_beta ;;
  stable) promote_stable ;;
  hotfix) promote_hotfix ;;
esac
