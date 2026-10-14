#!@bash@
# hinteros-install: installs HinterOS from the installer ISO according to a JSON plan.
#
#   hinteros-install --plan plan.json [--validate-only]
#   hinteros-install --check-newer [--channel stable|beta]
#   hinteros-install --info
#
# --info (offline, instant, no root): what this installer carries, as one JSON object,
#   {"iso":{"rev":...,"version":...},"channel":"stable"}
# (its revision, that revision's release/version and its default channel). Nothing is logged.
#
# --check-newer (online): is the channel's tip a newer HinterOS than this installer's revision,
# verified as a box verifies an update (an SSH signature by a key in this revision's
# release/allowed_signers, and a fast-forward from this revision)? Prints one JSON object,
#   {"channel":"stable","iso":{"rev":...,"version":...},"newer":{"rev","version","date","signer"}|null}
# or one error line (below) and exits non-zero. A plan's optional `rev` installs that newer
# revision instead of this installer's (online only; verified again before anything is touched).
#
# Two stages. The SYSTEM stage installs HinterOS (state.json schema 2: one spare account, p1 =
# hinteros, no profile, the box features the picked apps need; offline only those of the apps on
# this medium), offline from this medium's store if need be, in three steps, each with its own
# stage name and step_percent:
#   packages   (36-50) "Getting the package list" (nix build --dry-run; no step_percent), then the
#              packages the system needs are copied from this medium (offline) or downloaded
#              (online) into the target: "<done> of <total> packages" ("Nothing to copy" /
#              "Nothing to download" when there is none);
#   build      (50-66) what is not prebuilt is built: "Building <name> (<i> of <n>)", or
#              "<done> of <n> built" while nothing runs ("Nothing to build"). These lines also carry
#              `build` (the newest running build's name, without hash and version; absent when
#              none runs), `build_index` (1-based) and `build_total`;
#   bootloader (66-70) nixos-install --system sets the system profile and writes the boot loader.
# A retry (warn system-retry or bootloader-retry) starts again from `packages`; step_percent
# never goes back within one run of a stage. The APPS stage then builds the picked apps' env into
# the target and makes it the starter set
# (/nix/var/nix/profiles/hinteros/starter, /var/lib/hinteros/starter.json); the system is not
# rebuilt. Whatever happens to an app, the system stage's result stays.
#
# stdout carries one JSON object per line, for a UI to follow:
#   {"phase":"system","stage":"partition","percent":14,"level":"info","message":"..."}
#   {"phase":"system","stage":"build","percent":57,"level":"info","message":"Building hinteros-launcher (12 of 30)",
#    "step_percent":36,"build":"hinteros-launcher","build_index":12,"build_total":30}
# `phase` is "system" or "apps"; during the apps stage a line may carry `app` (an app id). An app
# that could not be installed gets {level:"warn", code:"app-failed", app, message}; the run still
# ends with exit status 0 and a final {stage:"done", failed_apps:[...]}.
# `level` is info, warn or error; an error line also has a `code` and the process then exits
# non-zero (2: the plan or the machine is not acceptable, nothing was touched; 1: failed
# part-way). The last line of a successful run has stage "done" and percent 100. Everything
# else (tool output) goes to stderr and to /var/log/hinteros-install.log, which also holds the
# build log of every derivation that failed.
#
# The design is in the system repo's README ("Installer").
set -Eeuo pipefail

TEMPLATE=@template@
DISKO_SCRIPT=@diskoScript@
OFFLINE_LOCK=@offlineLock@
SOURCES_FILE=@sourcesFile@
APPS_JSON=@appsJson@
CATALOG_INDEX=@catalogIndex@
STATE_VERSION=@stateVersion@
REPO_URL=@repoUrl@
ISO_REV=@isoRev@
ISO_VERSION=@isoVersion@
# Keys a newer channel tip must be signed by (ssh-keygen allowed_signers, namespace git).
ALLOWED_SIGNERS=@allowedSigners@
# The channel a plan without one gets (hinteros.installer.channel).
DEFAULT_CHANNEL=@defaultChannel@
LOG=${HINTEROS_INSTALL_LOG:-/var/log/hinteros-install.log}
MNT=/mnt
TARGET_LINK=/dev/hinteros-target
MIN_DISK_GIB=16
# Test hook: the command that writes the hardware report (VM tests feed a fixture).
FACTER=${HINTEROS_INSTALL_FACTER:-nixos-facter}
# Test hook: the URL whose answer means "online" (VM tests have no network; curl reads file://).
ONLINE_PROBE=${HINTEROS_INSTALL_ONLINE_PROBE:-https://cache.nixos.org/nix-cache-info}

# Progress goes to the original stdout; anything a tool prints to stdout is moved to stderr.
exec 3>&1 1>&2

stage=validate
percent=0
phase=system
cur_app=
cur_app_n=0 # 1-based position of cur_app among the apps being installed
apps_total=0
step_pct= # progress of the current step alone (0-100); empty = not measurable
failed_apps=()
# Test hook: treat the apps stage as online (no offline restriction, any app id) although there is
# no network, so an online-only app fails to download. The system stage still follows the probe.
ONLINE_APPS_HOOK=${HINTEROS_INSTALL_ONLINE_APPS:-}

# Besides the overall `percent` (monotonic over the whole install), a line may carry
# `step_percent` (0-100: how far the current stage or app is; absent = not measurable, the UI
# shows an indeterminate bar) and, in the apps phase while one app is being built, `app` with
# `app_index`/`app_total` (1-based). The UI draws one bar per step and per app from these.
progress() { # stage percent message [level] [code] [extra-json-object]
  # Never backwards (the stages run several builds that each count from their own start).
  [ "$2" -ge "$percent" ] || set -- "$1" "$percent" "${@:3}"
  jq -nc --arg phase "$phase" --arg stage "$1" --argjson percent "$2" --arg message "$3" \
    --arg level "${4:-info}" --arg code "${5:-}" --arg app "$cur_app" --argjson extra "${6:-"{}"}" \
    --arg step "$step_pct" --argjson an "$cur_app_n" --argjson at "$apps_total" \
    '{phase: $phase, stage: $stage, percent: $percent, level: $level, message: $message}
     + (if $step == "" then {} else {step_percent: ($step | tonumber)} end)
     + (if $app == "" then {} else {app: $app, app_index: $an, app_total: $at} end)
     + (if $code == "" then {} else {code: $code} end) + $extra' >&3
  stage=$1
  percent=$2
  echo "[$phase/$1 $2%] $3" >&2
}

# fail EXITCODE CODE MESSAGE: report and stop.
fail() {
  progress "$stage" "$percent" "$3" error "$2"
  exit "$1"
}

main_pid=$$
# Unexpected failures (set -e) still end with an error line the UI can show.
# shellcheck disable=SC2329 # the ERR trap
on_error() {
  local rc=$1 line=$2 cmd=$3
  # A failure in a subshell (a process substitution, a command substitution) ends that subshell;
  # the main shell sees it through the exit status or the output.
  [ "$BASHPID" = "$main_pid" ] || exit "$rc"
  trap - ERR
  echo "failed command (exit $rc, line $line): $cmd" >>"$LOG"
  echo "--- last lines of $LOG" >&2
  tail -n 30 "$LOG" >&2 || true
  progress "$stage" "$percent" "unexpected failure (exit $rc, line $line); see $LOG" error internal
  exit 1
}
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

# run DESCRIPTION CMD...: tool output goes to the log only.
run() {
  local what=$1
  shift
  echo "+ $*" >>"$LOG"
  if ! "$@" >>"$LOG" 2>&1 </dev/null; then
    echo "--- last lines of $LOG" >&2
    tail -n 30 "$LOG" >&2 || true
    fail 1 step-failed "$what failed; see $LOG"
  fi
}

# ---------------------------------------------------------------------------------------------
# A newer HinterOS on the channel: fetch the channel's tip from REPO_URL and verify it as a box
# verifies an update (hinteros-system's update.rs): an SSH signature by a key in this installer
# revision's allowed signers, and a fast-forward from ISO_REV. Only commits and the tip's
# release/version are downloaded (a partial clone), every git step has a time limit.
# ---------------------------------------------------------------------------------------------
SHORT_REV=12 # as update.rs: a tip without a readable release/version is named by its short rev
repo_scheme=${REPO_URL%%://*}
chk_dir=
tmp_dirs=()
# shellcheck disable=SC2329 # the EXIT trap
cleanup_tmp() { [ "${#tmp_dirs[@]}" -eq 0 ] || rm -rf "${tmp_dirs[@]}"; }
trap cleanup_tmp EXIT
# Results of check_channel: the tip, and the newer release (empty: none newer).
TIP_REV=
NEWER_REV=
NEWER_VERSION=
NEWER_DATE=0
NEWER_SIGNER=

# The steps that talk to the repo end within CHECK_BUDGET seconds together.
CHECK_BUDGET=120
chk_deadline=0

# lgit SECONDS ARGS...: git against chk_dir with no user or system config, only the repo's
# transport allowed, never prompting, killed after SECONDS (exit 124). stdout is the caller's.
# For local steps (no fetching of missing objects either); cgit for those that may download.
lgit() {
  local t=$1
  shift
  echo "+ git $*" >>"$LOG"
  timeout -k 5 "$t" env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
    GIT_ASKPASS=false SSH_ASKPASS=false LC_ALL=C GIT_NO_LAZY_FETCH="${no_lazy_fetch:-1}" \
    SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}" \
    git -c protocol.allow=never -c "protocol.$repo_scheme.allow=always" \
    -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 -c core.askPass=false \
    --git-dir "$chk_dir" "$@" </dev/null
}
# cgit SECONDS ARGS...: lgit that may fetch (also missing objects of the partial clone on demand),
# killed at the check's deadline too.
cgit() {
  local t=$1 left=$((chk_deadline - SECONDS))
  shift
  [ "$left" -gt 0 ] || return 124
  [ "$t" -le "$left" ] || t=$left
  no_lazy_fetch=0 lgit "$t" "$@"
}

# git_failed RC EXIT WHAT: a git step that could not reach the repo (or took too long).
git_failed() {
  if [ "$1" -eq 124 ] || [ "$1" -eq 137 ]; then
    fail "$2" timeout "$3: no answer from $REPO_URL in time; check the network connection"
  fi
  fail "$2" repo-unreachable "$3: cannot reach $REPO_URL (exit $1); check the network connection"
}

# The release version in a release/version file, as update.rs parses it: its only non-empty
# line, MAJOR.MINOR.PATCH with an optional -suffix, at most 32 characters; else nothing.
parse_version() {
  local lines
  lines=$(printf '%s\n' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | { grep -v '^$' || true; })
  [ "$(grep -c . <<<"$lines" || true)" -eq 1 ] || return 0
  if [ "${#lines}" -le 32 ] && [[ $lines =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    printf '%s' "$lines"
  fi
}

# check_channel CHANNEL EXIT: sets TIP_REV and, if the tip is a verified newer release, NEWER_*.
# A tip that is ISO_REV or older than it is not newer. Every failure is an error line and exit
# EXIT (2 during plan validation: nothing was touched).
check_channel() {
  local ch=$1 ex=$2 branch=$1 out rc tip raw size ver
  TIP_REV=
  NEWER_REV=
  if ! [[ $ISO_REV =~ ^[0-9a-f]{40}$ ]] || [ "$ISO_REV" = 0000000000000000000000000000000000000000 ]; then
    fail 2 iso-rev-unknown "this installer was built from an uncommitted tree and knows no revision to compare with"
  fi
  chk_deadline=$((SECONDS + CHECK_BUDGET))
  chk_dir=$(mktemp -d)
  tmp_dirs+=("$chk_dir")
  chk_dir=$chk_dir/repo.git
  env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git init -q --bare "$chk_dir" >>"$LOG" 2>&1
  lgit 10 config remote.origin.url "$REPO_URL"

  rc=0
  out=$(cgit 30 ls-remote origin "refs/heads/$branch" 2>>"$LOG") || rc=$?
  [ "$rc" -eq 0 ] || git_failed "$rc" "$ex" "Checking the $ch channel"
  tip=$(printf '%s\n' "$out" | awk -v r="refs/heads/$branch" '$2 == r {print $1}')
  [[ $tip =~ ^[0-9a-f]{40}$ ]] || fail "$ex" channel-missing "$REPO_URL has no $ch channel (branch $branch)"
  TIP_REV=$tip
  [ "$tip" != "$ISO_REV" ] || return 0

  # Commits and trees only; the one blob read below (release/version) is fetched on demand.
  rc=0
  cgit 90 fetch -q --no-tags --filter=blob:none origin "+refs/heads/$branch:refs/remotes/origin/$branch" \
    >>"$LOG" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || git_failed "$rc" "$ex" "Downloading the $ch channel"
  tip=$(lgit 10 rev-parse -q --verify "refs/remotes/origin/$branch^{commit}" 2>>"$LOG") \
    || fail "$ex" repo-unreachable "the $ch channel could not be read from $REPO_URL"
  TIP_REV=$tip
  [ "$tip" != "$ISO_REV" ] || return 0
  # Older than this installer (the channel was moved back): nothing newer. This revision is not
  # in the fetched history then; the partial clone asks the repo for it.
  if cgit 20 cat-file -e "$ISO_REV^{commit}" 2>>"$LOG" \
    && cgit 60 merge-base --is-ancestor "$tip" "$ISO_REV" 2>>"$LOG"; then
    return 0
  fi

  # The signature (update.rs Git::verify): present, SSH, by an allowed principal.
  raw=$(lgit 10 cat-file commit "$tip" 2>>"$LOG") || fail "$ex" repo-unreachable "cannot read the $ch channel's tip $tip"
  grep -q '^gpgsig ' <<<"$raw" \
    || fail "$ex" unsigned "the $ch channel's tip $tip is not signed; it is not offered"
  grep -q 'BEGIN SSH SIGNATURE' <<<"$raw" \
    || fail "$ex" unknown-signer "the $ch channel's tip $tip is not signed with an SSH key this installer trusts"
  rc=0
  out=$(lgit 30 -c gpg.format=ssh -c gpg.ssh.program=ssh-keygen \
    -c "gpg.ssh.allowedSignersFile=$ALLOWED_SIGNERS" verify-commit --raw "$tip" 2>&1) || rc=$?
  printf '%s\n' "$out" >>"$LOG"
  NEWER_SIGNER=$(sed -n '/Good "git" signature for /{s/.*Good "git" signature for \(.*\) with .* key .*/\1/p;q;}' <<<"$out")
  if [ "$rc" -ne 0 ] || [ -z "$NEWER_SIGNER" ]; then
    fail "$ex" unknown-signer "the $ch channel's tip $tip is not signed by a key this installer trusts"
  fi
  # Fast-forward only: the tip descends from this installer's revision.
  if ! { lgit 10 cat-file -e "$ISO_REV^{commit}" 2>>"$LOG" \
    && lgit 60 merge-base --is-ancestor "$ISO_REV" "$tip" 2>>"$LOG"; }; then
    fail "$ex" not-fast-forward "the $ch channel's tip $tip does not descend from this installer's revision $ISO_REV"
  fi

  # release/version (on demand from the partial clone; if the server will not hand out single
  # objects, the whole branch once).
  ver=
  if ! size=$(cgit 30 cat-file -s "$tip:release/version" 2>>"$LOG"); then
    cgit 60 fetch -q --no-tags --refetch origin "+refs/heads/$branch:refs/remotes/origin/$branch" \
      >>"$LOG" 2>&1 || true
    size=$(cgit 30 cat-file -s "$tip:release/version" 2>>"$LOG") || size=
  fi
  if [[ $size =~ ^[0-9]+$ ]] && [ "$size" -le 256 ]; then
    ver=$(parse_version "$(cgit 30 cat-file blob "$tip:release/version" 2>>"$LOG" || true)")
  fi
  NEWER_VERSION=${ver:-${tip:0:SHORT_REV}}
  NEWER_DATE=$(sed -n '/^$/q; s/^committer .* \([0-9][0-9]*\) [-+][0-9]*$/\1/p' <<<"$raw")
  NEWER_DATE=${NEWER_DATE:-0}
  NEWER_REV=$tip
}

usage() {
  cat >&2 <<'USAGE'
usage: hinteros-install --plan FILE|- [--validate-only | --state-dir DIR]
       hinteros-install --check-newer [--channel stable|beta]
       hinteros-install --info

Installs HinterOS on the disk named in the plan, erasing it. The plan is a JSON object, see
the README ("Installer"). With --validate-only the plan and the machine are checked and
nothing is touched. With --state-dir the plan is checked and the state.json files it would
produce are written to DIR (for tests).

--check-newer (needs the network) prints one JSON object: this installer's revision and
version and, if the channel (default: the installer's) has a newer, correctly signed release
that follows it, that release ("newer"; else null). A plan's "rev" installs it.

--info (offline, no root) prints one JSON object: this installer's revision and version and
its default channel, {"iso":{"rev":...,"version":...},"channel":...}.
USAGE
  exit 2
}

plan_file=
validate_only=0
state_dir=
check_newer=0
check_ch=$DEFAULT_CHANNEL
info=0
while [ $# -gt 0 ]; do
  case $1 in
    --plan)
      [ $# -ge 2 ] || usage
      plan_file=$2
      shift 2
      ;;
    --check-newer)
      check_newer=1
      shift
      ;;
    --info)
      info=1
      shift
      ;;
    --channel)
      [ $# -ge 2 ] || usage
      check_ch=$2
      shift 2
      ;;
    --validate-only)
      validate_only=1
      shift
      ;;
    --state-dir)
      [ $# -ge 2 ] || usage
      state_dir=$2
      shift 2
      ;;
    -h | --help) usage ;;
    *) usage ;;
  esac
done
if [ "$info" -eq 1 ]; then
  # Offline and instant: only what was built into this installer. No log, no root.
  [ "$check_newer" -eq 0 ] && [ -z "$plan_file" ] && [ "$validate_only" -eq 0 ] \
    && [ -z "$state_dir" ] && [ "$check_ch" = "$DEFAULT_CHANNEL" ] || usage
  jq -nc --arg irev "$ISO_REV" --arg iver "$ISO_VERSION" --arg ch "$DEFAULT_CHANNEL" \
    '{iso: {rev: $irev, version: $iver}, channel: $ch}' >&3
  exit 0
elif [ "$check_newer" -eq 1 ]; then
  [ -z "$plan_file" ] && [ "$validate_only" -eq 0 ] && [ -z "$state_dir" ] || usage
else
  [ -n "$plan_file" ] || usage
fi

if [ "$check_newer" -eq 1 ] && ! { mkdir -p "$(dirname "$LOG")" && : >>"$LOG"; } 2>/dev/null; then
  LOG=$(mktemp) # the check does not need root; without access to the install log it logs aside
fi
mkdir -p "$(dirname "$LOG")"
: >>"$LOG"
chmod 0600 "$LOG"

if [ "$check_newer" -eq 1 ]; then
  phase=check
  stage=check
  echo "=== hinteros-install --check-newer --channel $check_ch ($(date -u +%Y-%m-%dT%H:%M:%SZ))" >>"$LOG"
  case $check_ch in
    stable | beta) ;;
    *) fail 2 channel-invalid "channel must be stable or beta" ;;
  esac
  check_channel "$check_ch" 1
  jq -nc --arg ch "$check_ch" --arg irev "$ISO_REV" --arg iver "$ISO_VERSION" --arg rev "$NEWER_REV" \
    --arg ver "$NEWER_VERSION" --argjson date "$NEWER_DATE" --arg signer "$NEWER_SIGNER" \
    '{channel: $ch, iso: {rev: $irev, version: $iver},
      newer: (if $rev == "" then null else {rev: $rev, version: $ver, date: $date, signer: $signer} end)}' >&3
  echo "channel $check_ch: tip ${TIP_REV:-?}, newer: ${NEWER_REV:-none}" >>"$LOG"
  exit 0
fi

[ -n "$state_dir" ] || [ "$(id -u)" -eq 0 ] || fail 2 not-root "hinteros-install must run as root"

# ---------------------------------------------------------------------------------------------
# 1. Validate: the plan, then the machine. Nothing is touched before this is done.
# ---------------------------------------------------------------------------------------------
progress validate 0 "Checking the plan"

if [ "$plan_file" = - ]; then
  PLAN=$(cat)
else
  [ -r "$plan_file" ] || fail 2 plan-unreadable "cannot read plan file $plan_file"
  PLAN=$(cat "$plan_file")
fi
printf '%s' "$PLAN" | jq -e 'type == "object"' >/dev/null 2>&1 \
  || fail 2 plan-invalid "the plan is not a JSON object"

# The plan with defaults filled in; every later read goes through this.
PLAN=$(printf '%s' "$PLAN" | jq -c --arg default_channel "$DEFAULT_CHANNEL" '{
  disk, hostname, admin, wifi,
  ssh: (.ssh // {enable: false}),
  channel: (.channel // $default_channel),
  base: (.base // "unstable"),
  network: (.network // "auto"),
  apps: (.apps // []),
  acceptedTerms: (.acceptedTerms // {}),
  rev: (.rev // null),
  unknown: (keys - ["disk", "hostname", "admin", "ssh", "channel", "base", "network", "apps", "wifi", "acceptedTerms", "rev"])
}')

# Plan-level problems, all at once: [{field, code, message}].
problems=$(printf '%s' "$PLAN" | jq -c --slurpfile cat "$APPS_JSON" --slurpfile idx "$CATALOG_INDEX" '
  ($cat[0].onIso + $cat[0].onlineOnly) as $known
  | def bad(f; c; m): {field: f, code: c, message: m};
    [
      (.unknown[] | bad("."; "unknown-field"; "unknown plan field \(.)")),
      (if (.disk | type) != "string" or (.disk | startswith("/dev/") | not)
        then bad("disk"; "disk-missing"; "disk must be a device path such as /dev/nvme0n1") else empty end),
      (if (.hostname | type) != "string"
          or (.hostname | test("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$") | not)
        then bad("hostname"; "hostname-invalid"; "hostname must be 1-63 lowercase letters, digits or hyphens, not starting or ending with a hyphen") else empty end),
      (if (.admin | type) != "object"
        then bad("admin"; "admin-missing"; "an admin account (user and password) is required")
        else
          (if (.admin.user | type) != "string"
              or (.admin.user | test("^[a-z_][a-z0-9_-]{0,31}$") | not)
            then bad("admin.user"; "admin-user-invalid"; "admin user must be 1-32 lowercase letters, digits, - or _, starting with a letter or _") else empty end),
          (if (.admin.user | type) == "string"
              and ((.admin.user | IN("root", "hinteros", "nobody", "deploy", "sshd", "daemon", "nixbld"))
                   or (.admin.user | test("^(systemd-|nixbld)")))
            then bad("admin.user"; "admin-user-reserved"; "admin user name \(.admin.user) is reserved") else empty end),
          (if ((.admin.password | type) == "string" and (.admin.password | length) > 0)
              and ((.admin.hashedPassword | type) == "string")
            then bad("admin"; "admin-password-ambiguous"; "give either admin.password or admin.hashedPassword, not both")
           elif ((.admin.password | type) != "string" or (.admin.password | length) == 0)
              and ((.admin.hashedPassword | type) != "string" or (.admin.hashedPassword | length) == 0)
            then bad("admin.password"; "admin-password-missing"; "the admin account needs a password (admin.password or admin.hashedPassword)")
           else empty end),
          # The same minimum as the installer UI (hinteros-launcher, plan.dart minPassword); SSH
          # logs in with this password. A hash cannot be checked.
          (if (.admin.password | type) == "string" and (.admin.password | length) > 0
              and (.admin.password | length) < 8
            then bad("admin.password"; "admin-password-short"; "the admin password needs at least 8 characters") else empty end),
          (if (.admin.password | type) == "string" and (.admin.password | test("[\n\r\u0000]"))
            then bad("admin.password"; "admin-password-invalid"; "the admin password must not contain line breaks") else empty end),
          (if (.admin.hashedPassword | type) == "string"
              and (.admin.hashedPassword | test("^\\$[0-9a-z]+(\\$[^$:\\s]+)+$") | not)
            then bad("admin.hashedPassword"; "admin-hash-invalid"; "admin.hashedPassword is not a crypt(3) hash (mkpasswd output)") else empty end)
        end),
      (if (.ssh | type) != "object" or ((.ssh.enable // false) | type) != "boolean"
        then bad("ssh.enable"; "ssh-invalid"; "ssh.enable must be true or false") else empty end),
      (if (.channel | IN("stable", "beta") | not)
        then bad("channel"; "channel-invalid"; "channel must be stable or beta") else empty end),
      (if .rev != null and ((.rev | type) != "string" or (.rev | test("^[0-9a-f]{40}$") | not))
        then bad("rev"; "rev-invalid"; "rev must be a full 40-character commit id, as --check-newer reports it") else empty end),
      (if .base != "unstable"
        then bad("base"; "base-invalid"; "base must be unstable (the only base there is)") else empty end),
      (if (.acceptedTerms | type) != "object" or any(.acceptedTerms[]; type != "string")
        then bad("acceptedTerms"; "terms-invalid"; "acceptedTerms must map app ids to terms versions") else empty end),
      (if (.network | IN("auto", "online", "offline") | not)
        then bad("network"; "network-invalid"; "network must be auto, online or offline") else empty end),
      (if (.apps | type) != "array" or any(.apps[]; type != "string")
        then bad("apps"; "apps-invalid"; "apps must be a list of app ids")
        else
          (.apps[] | select(. as $a | $known | index($a) | not)
             | bad("apps"; "app-unknown"; "unknown app id \(.) (known: \($known | join(", ")))")),
          (if (.apps | length) != (.apps | unique | length)
            then bad("apps"; "app-duplicate"; "an app id is listed twice") else empty end),
          # Vendor terms: an app whose catalog entry has terms needs the user acceptance of
          # exactly the version in the catalog index of this installer.
          (. as $plan | .apps[] | . as $a
             | ($idx[0].apps[] | select(.id == $a and .terms != null)) as $e
             | select(($plan.acceptedTerms[$a] // null) != $e.terms.version)
             | bad("acceptedTerms"; "terms-not-accepted"; "the terms of \($e.name) (\($e.terms.title), version \($e.terms.version)) have not been accepted"))
        end),
      (if .wifi != null then
          (if (.wifi | type) != "object" or ((.wifi.ssid | type) != "string")
              or ((.wifi.ssid | length) < 1) or ((.wifi.ssid | utf8bytelength) > 32)
            then bad("wifi.ssid"; "wifi-invalid"; "wifi.ssid must be 1-32 bytes") else empty end),
          (if (.wifi | type) == "object" and .wifi.psk != null
              and ((.wifi.psk | type) != "string"
                   or ((.wifi.psk | test("^[0-9a-fA-F]{64}$") | not)
                       and ((.wifi.psk | length) < 8 or (.wifi.psk | length) > 63)))
            then bad("wifi.psk"; "wifi-invalid"; "wifi.psk must be 8-63 characters (or 64 hex digits)") else empty end)
        else empty end)
    ]')

report_problems() { # PROBLEMS_JSON: print each as an error line, exit 2 if any
  local n
  n=$(printf '%s' "$1" | jq 'length')
  [ "$n" -eq 0 ] && return 0
  printf '%s' "$1" | jq -c '.[]' | while IFS= read -r p; do
    progress validate 0 "$(printf '%s' "$p" | jq -r '.message')" error "$(printf '%s' "$p" | jq -r '.code')"
  done
  exit 2
}
report_problems "$problems"

plan() { local o=-r; if [ "$1" = -c ]; then o=-c; shift; fi; printf '%s' "$PLAN" | jq "$o" "$1"; }

disk=$(plan .disk)
hostname=$(plan .hostname)
admin_user=$(plan .admin.user)
ssh_enable=$(plan '.ssh.enable // false')
channel=$(plan .channel)
base=$(plan .base)
network_pref=$(plan .network)
mapfile -t apps < <(plan '.apps[]')
wifi_ssid=$(plan '.wifi.ssid // empty')
# The revision to install: this installer's (default), or a newer one --check-newer offered.
plan_rev=$(plan '.rev // empty')
newer=0
if [ -n "$plan_rev" ] && [ "$plan_rev" != "$ISO_REV" ]; then
  newer=1
fi
install_rev=$ISO_REV
install_version=$ISO_VERSION

# state.json (schema 2, profiles.md "Installer"): one spare account (p1 = hinteros) and no
# profile (first-boot mode creates the admin profile), no apps (each profile has its own; the
# picks become the starter set, below). `requirements` are the box features the picked apps need
# (Steam: graphics32, steam-devices), so the system stage already has them and a profile created
# from the starter set never waits for a rebuild. Into DIR (default: the device config).
write_state() {
  local dir=${1:-$cfg}
  jq -n --arg base "$base" --arg sv "$STATE_VERSION" --arg host "$hostname" --arg admin "$admin_user" \
    --argjson ssh "$ssh_enable" --argjson req "$requirements" '{
      schemaVersion: 2,
      base: $base,
      stateVersion: $sv,
      settings: {hostname: $host, ssh: {enable: $ssh}, admin: {user: $admin}, guest: {enable: true}},
      disk: {layout: "gpt-esp-ext4"},
      profiles: [{id: "p1", user: "hinteros"}],
      requirements: $req,
      services: []
    }' >"$dir/state.json"
  chmod 0644 "$dir/state.json"
}
json_array() { jq -nc '$ARGS.positional' --args "$@"; }
# The box features of these apps (JSON array of ids; catalog index v3 `box`), sorted.
app_requirements() {
  jq -c --slurpfile idx "$CATALOG_INDEX" \
    '. as $a | [$idx[0].apps[] | select(.id as $i | $a | index($i)) | (.box // [])[]] | unique' <<<"$1"
}
requirements=$(app_requirements "$(json_array "${apps[@]}")")
# The starter set (apps.md "Starter set"): which apps new profiles and guests start with.
write_starter() { # JSON array of app ids, [DIR]
  local dir=${2:-$MNT/var/lib/hinteros}
  (
    umask 0077
    jq -n --argjson ids "$1" --argjson now "$(date +%s)" \
      '{version: 1, ids: $ids, updated_at: $now, by: "installer"}' >"$dir/starter.json"
  )
  chmod 0600 "$dir/starter.json"
}

# --state-dir: write the state.json this plan would install (DIR/system; DIR/apps holds the same
# state, the apps being in the starter set, DIR/apps/starter.json) and stop. For the flake check
# that has hinteros-system parse them; nothing else is checked or touched, and root is not needed.
if [ -n "$state_dir" ]; then
  mkdir -p "$state_dir/system" "$state_dir/apps"
  write_state "$state_dir/system"
  write_state "$state_dir/apps"
  write_starter "$(json_array "${apps[@]}")" "$state_dir/apps"
  exit 0
fi

# The machine.
if [ ! -d /sys/firmware/efi ] && [ -z "${HINTEROS_INSTALL_ALLOW_BIOS:-}" ]; then
  # HINTEROS_INSTALL_ALLOW_BIOS is for the VM tests, whose installer VM is not booted via UEFI.
  fail 2 not-uefi "this machine did not boot in UEFI mode; HinterOS installs on UEFI machines only (check the firmware boot settings)"
fi

exec 9>/run/hinteros-install.lock
flock -n 9 || fail 2 already-running "another hinteros-install is running"

mem_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
if [ "$mem_kib" -lt $((3 * 1024 * 1024)) ]; then
  progress validate 1 "Only $((mem_kib / 1024)) MiB of memory; the install may fail on boxes with less than 4 GB" warn low-memory
fi

# Network: bring up Wi-Fi if the plan has it, then decide online or offline.
online=0
if [ "$network_pref" != offline ]; then
  if [ -n "$wifi_ssid" ]; then
    progress validate 2 "Connecting to Wi-Fi \"$wifi_ssid\""
    wifi_psk=$(plan '.wifi.psk // empty')
    nmcli radio wifi on >>"$LOG" 2>&1 || true
    nmcli device wifi rescan >>"$LOG" 2>&1 || true
    sleep 3
    if [ -n "$wifi_psk" ]; then
      nmcli -w 40 device wifi connect "$wifi_ssid" password "$wifi_psk" >>"$LOG" 2>&1 \
        || progress validate 2 "Could not connect to Wi-Fi \"$wifi_ssid\"" warn wifi-failed
    else
      nmcli -w 40 device wifi connect "$wifi_ssid" >>"$LOG" 2>&1 \
        || progress validate 2 "Could not connect to Wi-Fi \"$wifi_ssid\"" warn wifi-failed
    fi
  fi
  if curl -fsS --max-time 8 -o /dev/null "$ONLINE_PROBE" >>"$LOG" 2>&1; then
    online=1
  fi
fi
if [ "$network_pref" = online ] && [ "$online" -eq 0 ]; then
  fail 2 no-network "the plan asks for an online install but cache.nixos.org is not reachable"
fi
if [ "$online" -eq 1 ]; then
  progress validate 4 "Online install"
else
  progress validate 4 "Offline install: only the apps on this installer are available"
fi

if [ "$online" -eq 0 ] && [ -z "$ONLINE_APPS_HOOK" ] && [ "${#apps[@]}" -gt 0 ]; then
  offline_bad=$(printf '%s\n' "${apps[@]}" | jq -R . | jq -sc --slurpfile cat "$APPS_JSON" \
    '[.[] | select(. as $a | $cat[0].onIso | index($a) | not)]')
  if [ "$(printf '%s' "$offline_bad" | jq length)" -gt 0 ]; then
    fail 2 app-needs-network "these apps are not on the installer and need a network connection: $(printf '%s' "$offline_bad" | jq -r 'join(", ")'); connect to a network or deselect them (they can be added later from the Store)"
  fi
fi

# The disk.
disk_real=$(readlink -f "$disk" 2>/dev/null || true)
[ -n "$disk_real" ] && [ -b "$disk_real" ] \
  || fail 2 disk-not-found "$disk is not a block device on this machine"
[ "$(lsblk -dno TYPE "$disk_real" 2>/dev/null)" = disk ] \
  || fail 2 disk-not-a-disk "$disk is not a whole disk (it is a $(lsblk -dno TYPE "$disk_real" 2>/dev/null || echo unknown))"
# Mounted anywhere (the installer medium, an old install)? Leftovers of an earlier run of this
# script under /mnt are fine; they are unmounted before partitioning.
in_use=$(lsblk -rno MOUNTPOINTS "$disk_real" | tr ' ' '\n' | sed '/^$/d' | { grep -Ev "^$MNT(/|$)" || true; })
[ -z "$in_use" ] || fail 2 disk-in-use "$disk is in use (mounted at: $(printf '%s' "$in_use" | tr '\n' ' ')); it may be the installer medium"
disk_bytes=$(blockdev --getsize64 "$disk_real")
if [ "$disk_bytes" -lt $((MIN_DISK_GIB * 1024 * 1024 * 1024)) ]; then
  fail 2 disk-too-small "$disk is $((disk_bytes / 1024 / 1024 / 1024)) GiB; at least $MIN_DISK_GIB GiB are needed"
fi
# The installed system finds its partitions by GPT partition label (hinteros-esp, hinteros-root),
# and so does the partitioning script. A second disk (an old install, a USB stick) carrying those
# labels would make them ambiguous: udev links the label to either disk, so the new file systems
# could be made on, or mounted from, the wrong one. Refuse before anything is touched.
others=$(lsblk -J -p -o PATH,PKNAME,PARTLABEL 2>/dev/null | jq -r --arg d "$disk_real" '
  [.. | objects | select((.partlabel // "") | test("^hinteros-(esp|root)$"))
   | select((.pkname // "") != $d) | "\(.path) (\(.partlabel))"] | join(", ")' 2>/dev/null || true)
[ -z "$others" ] || fail 2 other-hinteros-disk "another disk already has HinterOS partitions: $others. The system finds its disks by partition label, so two such disks are ambiguous; unplug that disk or erase it first"
if mountpoint -q "$MNT"; then
  mnt_src=$(findmnt -no SOURCE "$MNT")
  case $(lsblk -rno PKNAME "$mnt_src" 2>/dev/null | head -n1) in
    "$(basename "$disk_real")") ;;
    *) fail 2 mnt-in-use "$MNT is mounted from $mnt_src, which is not on $disk" ;;
  esac
fi

# A newer revision than this installer's: online only, and only the channel's verified tip (the
# UI's word for it is not enough; the channel may also have moved on since it asked).
if [ "$newer" -eq 1 ]; then
  [ "$online" -eq 1 ] \
    || fail 2 rev-needs-network "the newer HinterOS ($plan_rev) is not on this installer and needs a network connection; connect to a network or install the version on this installer"
  progress validate 6 "Checking the newer HinterOS on the $channel channel"
  check_channel "$channel" 2
  if [ "$NEWER_REV" != "$plan_rev" ]; then
    newest=${NEWER_REV:-$ISO_REV}
    fail 2 rev-not-tip "$plan_rev is not the newest release on the $channel channel (that is $newest); check again"
  fi
  install_rev=$NEWER_REV
  install_version=$NEWER_VERSION
  progress validate 7 "HinterOS $install_version ($install_rev) on the $channel channel is signed by $NEWER_SIGNER and follows this installer's version"
fi

progress validate 8 "Plan accepted: install HinterOS $install_version on $disk ($((disk_bytes / 1024 / 1024 / 1024)) GiB), host name $hostname, apps: ${apps[*]:-none}"

if [ "$validate_only" -eq 1 ]; then
  progress "done" 100 "Plan and machine are fine (validate only; nothing was touched)" info "" '{"failed_apps": []}'
  exit 0
fi

# ---------------------------------------------------------------------------------------------
# 1b. A newer revision: download it and lock the device flake to it before the disk is touched,
# and read its catalog (the apps stage installs that revision's apps, with its vendor terms).
# ---------------------------------------------------------------------------------------------
staged=
# Apps of the plan the newer revision cannot install: id -> reason (warned in the apps stage).
declare -A skip_apps=()
if [ "$newer" -eq 1 ]; then
  progress fetch 9 "Downloading HinterOS $install_version"
  staged=$(mktemp -d)
  tmp_dirs+=("$staged")
  install -d "$staged/flake"
  sed -e "s|%CHANNEL%|$channel|g" -e "s|%REPO%|$REPO_URL|g" -e "s|%EXTRA%||g" "$TEMPLATE" >"$staged/flake/flake.nix"
  write_state "$staged/flake"
  echo "+ nix flake lock --override-input hinteros git+$REPO_URL?ref=$channel&rev=$install_rev" >>"$LOG"
  if ! timeout -k 10 1800 nix --extra-experimental-features 'nix-command flakes' flake lock \
    --option substitute true --override-input hinteros "git+$REPO_URL?ref=$channel&rev=$install_rev" \
    "path:$staged/flake" >>"$LOG" 2>&1 </dev/null; then
    fail 1 fetch-failed "could not download HinterOS $install_version ($install_rev); nothing was touched; see $LOG"
  fi
  locked=$(jq -r '.nodes[.nodes[.root].inputs.hinteros].locked.rev // ""' "$staged/flake/flake.lock")
  [ "$locked" = "$install_rev" ] \
    || fail 1 fetch-failed "the downloaded HinterOS is locked at '$locked', not $install_rev; nothing was touched"
  # That revision's catalog, in the shape of the Store index the rest of this script reads.
  # shellcheck disable=SC2016 # Nix, not shell
  catalog_apply='es: {
    apps = map (id: let e = es.${id}; in {
      inherit id;
      box = e.box or [ ];
      offered = (e.kind or "app") == "app" && e.status == "available" && (e.starter or null) != null;
      terms = if (e.terms or null) == null then null else { inherit (e.terms) version title; };
    }) (builtins.attrNames es);
  }'
  echo "+ nix eval (the catalog of $install_rev)" >>"$LOG"
  if ! timeout -k 10 900 nix --extra-experimental-features 'nix-command flakes' eval --json \
    --option substitute true --no-update-lock-file \
    "path:$staged/flake#nixosConfigurations.hinteros.config.hinteros.catalog.entries" \
    --apply "$catalog_apply" >"$staged/catalog.json" 2>>"$LOG" </dev/null; then
    fail 1 fetch-failed "could not read the app catalog of HinterOS $install_version; nothing was touched; see $LOG"
  fi
  CATALOG_INDEX=$staged/catalog.json
  # Picked apps that revision no longer offers, or whose vendor terms changed since the ones
  # accepted on this installer: not installed (the Store asks again later).
  while IFS=$'\t' read -r a why; do
    [ -n "$a" ] && skip_apps[$a]=$why
  done < <(json_array "${apps[@]}" | jq -r --slurpfile idx "$CATALOG_INDEX" \
    --argjson acc "$(plan -c .acceptedTerms)" --arg v "$install_version" '
    .[] as $a | ($idx[0].apps | map(select(.id == $a)) | first) as $e
    | if $e == null or ($e.offered | not) then "\($a)\tHinterOS \($v) does not offer \($a) in the installer"
      elif $e.terms != null and ($acc[$a] // null) != $e.terms.version then
        "\($a)\tthe terms of \($a) changed in HinterOS \($v) (\($e.terms.title), version \($e.terms.version)); accept them in the Store to add it"
      else empty end')
  keep=()
  for a in "${apps[@]}"; do [ -n "${skip_apps[$a]:-}" ] || keep+=("$a"); done
  requirements=$(app_requirements "$(json_array "${keep[@]}")")
  progress fetch 9 "HinterOS $install_version is downloaded"
fi

# ---------------------------------------------------------------------------------------------
# 2. Partition and format (disko), mounted at /mnt.
# ---------------------------------------------------------------------------------------------
progress partition 10 "Erasing and partitioning $disk"
if mountpoint -q "$MNT"; then
  run "Unmounting $MNT" umount -R "$MNT"
fi
# An earlier install on this disk: erase every signature first. disko skips mkfs on a partition
# that still shows a file system (a new partition at the old one's offsets would keep the old
# store), and the old labels must be gone before the new ones are made.
# shellcheck disable=SC2329 # run via `run`
wipe_target() {
  local part
  for part in $(lsblk -lnpo PATH,TYPE "$disk_real" | awk '$2 == "part" {print $1}'); do
    wipefs -a -f "$part"
  done
  wipefs -a -f "$disk_real"
  blockdev --rereadpt "$disk_real" || true
  udevadm settle || true
}
run "Erasing old signatures" wipe_target
# The disko layout names the disk /dev/hinteros-target; this link points it at the real one.
ln -sfn "$disk_real" "$TARGET_LINK"
run "Partitioning" "$DISKO_SCRIPT" --yes-wipe-all-disks
rm -f "$TARGET_LINK"
udevadm settle >>"$LOG" 2>&1 || true
if ! { mountpoint -q "$MNT" && mountpoint -q "$MNT/boot"; }; then
  fail 1 mount-failed "the new file systems are not mounted at $MNT"
fi
# The partitions are found by label, so make sure they are the ones on the target disk and that
# the root file system is new.
for m in "$MNT" "$MNT/boot"; do
  src=$(readlink -f "$(findmnt -no SOURCE "$m")")
  [ "$(lsblk -no PKNAME -p "$src" | head -n1)" = "$disk_real" ] \
    || fail 1 wrong-partition "$m is mounted from $src, which is not on $disk; refusing to install there"
done
stale=$(find "$MNT" -mindepth 1 -maxdepth 1 ! -name lost+found ! -name boot -printf '%f\n')
[ -z "$stale" ] || fail 1 stale-filesystem "the new root file system is not empty ($(printf '%s' "$stale" | tr '\n' ' ')); an old install was not erased"
progress partition 20 "Disk is partitioned and mounted"

# ---------------------------------------------------------------------------------------------
# 3. The device config: /etc/hinteros (schema 2; apps are per profile).
# ---------------------------------------------------------------------------------------------
cfg=$MNT/etc/hinteros
install -d -m 0755 "$MNT/etc" "$cfg" "$MNT/var/lib/hinteros"

progress facter 22 "Detecting hardware"
facter_ok=0
if $FACTER -o "$cfg/facter.json" >>"$LOG" 2>&1 && jq -e . "$cfg/facter.json" >/dev/null 2>&1; then
  facter_ok=1
  if [ "$online" -eq 1 ]; then
    progress facter 26 "Hardware report written; it is applied by this install"
  else
    # Offline: install exactly the generic system that is on this medium (prebuilt, so nothing
    # is built). A report changes the system (firmware, microcode, initrd modules, ...), which
    # then has to be built, and that needs a network. The box applies the report with its first
    # online rebuild or update (hinteros-facter-release removes the marker once it is online).
    : >"$cfg/facter.deferred"
    progress facter 26 "Hardware report written; it is applied by the first rebuild once the box is online"
  fi
else
  rm -f "$cfg/facter.json"
  progress facter 26 "Hardware detection failed; continuing with generic hardware support" warn facter-failed
fi

progress config 28 "Writing the device configuration"
write_state

# Extra modules of the generated flake: the test hook, and the boot loader override.
extra_mods=()
write_flake() {
  sed -e "s|%CHANNEL%|$channel|g" -e "s|%REPO%|$REPO_URL|g" -e "s|%EXTRA%|${extra_mods[*]}|g" \
    "$TEMPLATE" >"$cfg/flake.nix"
  chmod 0644 "$cfg/flake.nix"
}
if [ -n "${HINTEROS_INSTALL_EXTRA_MODULE:-}" ]; then
  # Test hook: one more NixOS module for the installed system (the VM test adds its
  # instrumentation this way). Not part of the plan; unset on real installs.
  install -m 0644 "$HINTEROS_INSTALL_EXTRA_MODULE" "$cfg/extra-module.nix"
  extra_mods+=(./extra-module.nix)
fi
# Where EFI variables cannot be written (efivarfs missing or read-only) bootctl would fail the whole
# install; the box then boots through the fallback path (EFI/BOOT/BOOTX64.EFI) instead.
efi_override_done=0
efi_override() {
  [ "$efi_override_done" -eq 0 ] || return 1
  cat >"$cfg/installer-overrides.nix" <<'NIX'
{ lib, ... }:
{
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
}
NIX
  chmod 0644 "$cfg/installer-overrides.nix"
  extra_mods+=(./installer-overrides.nix)
  efi_override_done=1
  write_flake
}
write_flake
if [ ! -w /sys/firmware/efi/efivars ]; then
  efi_override
  progress config 29 "EFI variables are not writable here; the boot loader goes to the fallback path only" warn efivars-unavailable
fi
# The lock pins hinteros (and everything it locks) to the revision on this installer, so the
# evaluation needs no network; `nix flake update hinteros` later moves it to the channel. A newer
# revision: the lock made for it above (same inputs: flake.nix differs only in its modules).
if [ "$newer" -eq 1 ]; then
  install -m 0644 "$staged/flake/flake.lock" "$cfg/flake.lock"
else
  jq --arg ref "$channel" \
    '.nodes.hinteros.original.ref = $ref | .nodes.hinteros.locked.ref = "refs/heads/" + $ref' \
    "$OFFLINE_LOCK" >"$cfg/flake.lock"
fi
chmod 0644 "$cfg/flake.lock"
chmod 0644 "$cfg"/facter.*  2>/dev/null || true

# The admin password: a hash in a root-only file the config points at. Never in the store, never
# in state.json.
hash_file=$MNT/var/lib/hinteros/admin-password-hash
(
  umask 0077
  if [ "$(plan '(.admin.hashedPassword // "") | length')" -gt 0 ]; then
    plan .admin.hashedPassword | tr -d '\n' >"$hash_file"
  else
    plan .admin.password | tr -d '\n' | mkpasswd -m sha-512 -s | tr -d '\n' >"$hash_file"
  fi
)
chmod 0600 "$hash_file"
[ "$(wc -c <"$hash_file")" -gt 8 ] || fail 1 hash-failed "could not hash the admin password"
# Which vendor terms the user accepted here: id -> [{version, accepted_at, by}]. Root only; the box
# adds to it when apps are installed later. Only apps that were actually installed are recorded:
# it starts empty and the apps stage fills it.
write_terms() { # JSON array of installed app ids
  (
    umask 0077
    jq -n --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson apps "$1" \
      --slurpfile idx "$CATALOG_INDEX" '
      [$apps[] as $a | $idx[0].apps[] | select(.id == $a and .terms != null)
         | {key: .id, value: [{version: .terms.version, accepted_at: $now, by: "installer"}]}]
      | from_entries' >"$MNT/var/lib/hinteros/terms-accepted.json"
  )
  chmod 0600 "$MNT/var/lib/hinteros/terms-accepted.json"
}
write_terms '[]'
progress config 30 "Device configuration written to /etc/hinteros"

# ---------------------------------------------------------------------------------------------
# nix helpers: progress from nix's own log, and the full build log of whatever fails.
# ---------------------------------------------------------------------------------------------
NIXLOG=
NIXOUT=
NIX_RC=0
NIX_ERRS=
# The filter turns nix's internal-json log (stderr) into progress, one tab-separated line per
# step: percent, step_percent, message, extra fields (a JSON object). $mode:
#   combined  copies (103) and builds (104) together, "<done> of <expected> steps" (the apps stage);
#   packages  copies only, "<done> of <total> packages";
#   build     builds only, "Building <name> (<i> of <n>)" / "<done> of <n> built", with the running
#             builds (105) for `build`, `build_index` and `build_total`.
# $total (packages, build): the count `nix build --dry-run` gave. nix's own `expected` grows while
# it works through the closure (it said "1 of 1" long before the end), so it only counts where it
# is larger. A line is printed when step_percent goes up (and in build mode when the running build
# changes); step_percent never goes down.
# shellcheck disable=SC2016
progress_filter='
  def pct(d; t): if t > 0 then ((d * 100 / t) | floor) else 0 end;
  def name: sub(".*/"; "") | sub("^[0-9a-z]{32}-"; "") | sub("\\.drv$"; "") | sub("-[0-9][^-]*$"; "");
  foreach (inputs | select(startswith("@nix ")) | .[5:] | fromjson? | select(. != null)) as $e (
    {kinds: {}, prog: {}, run: [], last: (if $mode != "combined" and $total > 0 then 0 else -1 end),
     lastb: null, emit: null, touch: false};
    .emit = null | .touch = false
    | ($e.id | tostring) as $id
    | if $e.action == "start" and (($e.type == 103 and $mode != "build") or ($e.type == 104 and $mode != "packages")) then
        .kinds[$id] = $e.type
      elif $mode == "build" and $e.action == "start" and $e.type == 105 then
        .run += [{id: $id, name: ($e.fields[0] | tostring | name)}] | .touch = true
      elif $mode == "build" and $e.action == "stop" and any(.run[]; .id == $id) then
        .run |= map(select(.id != $id)) | .touch = true
      elif $e.action == "result" and $e.type == 105 and (.kinds[$id] != null) then
        .prog[$id] = $e.fields | .touch = (.run == [])
      else . end
    | ([.prog[] | .[0]] | add // 0) as $done | ([.prog[] | .[1]] | add // 0) as $exp
    | if $mode == "combined" then
        (if $exp > 0 then ($lo + (($done / $exp) * ($hi - $lo) | floor)) else $lo end) as $pct
        | pct($done; $exp) as $step
        | if $step > .last then .last = $step | .emit = [$pct, $step, "\($done) of \($exp) steps", {}] else . end
      else
        ([$done, (if $total > 0 then $total else $exp end)] | max) as $t
        | ([pct($done; $t), .last] | max) as $step
        | ($lo + (if $t > 0 then ($done / $t) * ($hi - $lo) | floor else 0 end)) as $pct
        | if $mode == "packages" then
            if $step > .last then .last = $step | .emit = [$pct, $step, "\($done) of \($t) packages", {}] else . end
          else
            (.run | last | .name // null) as $b
            | if .touch and ($step > .last or $b != .lastb) then
                .last = $step | .lastb = $b
                | ([$done + 1, $t] | min) as $i
                | .emit = [$pct, $step,
                    (if $b == null then "\($done) of \($t) built" else "Building \($b) (\($i) of \($t))" end),
                    ({build_index: $i, build_total: $t} + (if $b == null then {} else {build: $b} end))]
              else . end
          end
      end;
    select(.emit != null) | .emit | "\(.[0])\t\(.[1])\t\(.[2])\t\(.[3] | tojson)")'

# nix_logged MODE STAGE LO HI LABEL TOTAL CMD...: runs CMD in the background with its output in
# files and turns nix's internal-json log into progress lines between LO and HI percent (MODE and
# TOTAL: see progress_filter; MODE quiet: no progress lines). LABEL (may be empty) goes before each
# message. Sets NIX_RC, and NIX_STEP and NIX_EXTRA to the last line's step_percent and extra
# fields (empty: no line); the output is in $NIXLOG (stderr) and $NIXOUT (stdout) until the next
# call, and in the log file.
nix_logged() {
  local mode=$1 st=$2 lo=$3 hi=$4 label=$5 total=$6 pid pc sp msg extra
  shift 6
  rm -f "$NIXLOG" "$NIXOUT"
  NIXLOG=$(mktemp)
  NIXOUT=$(mktemp)
  NIX_STEP=
  NIX_EXTRA=
  echo "+ $*" >>"$LOG"
  "$@" >"$NIXOUT" 2>"$NIXLOG" </dev/null &
  pid=$!
  if [ "$mode" != quiet ]; then
    while IFS=$'\t' read -r pc sp msg extra; do
      step_pct=$sp
      NIX_STEP=$sp
      NIX_EXTRA=$extra
      progress "$st" "$pc" "${label:+$label: }$msg" info "" "$extra"
    done < <(tail -n +1 -F --pid="$pid" "$NIXLOG" 2>/dev/null | jq -rnR --unbuffered --arg mode "$mode" \
      --argjson lo "$lo" --argjson hi "$hi" --argjson total "$total" "$progress_filter" 2>/dev/null || true)
  fi
  NIX_RC=0
  wait "$pid" || NIX_RC=$?
  step_pct=
  cat "$NIXLOG" "$NIXOUT" >>"$LOG"
}

# After a failed nix_logged: put everything needed to diagnose it in the log (nix's error messages
# in full, and the build log of every derivation that failed, from `nix log`) and set NIX_ERRS to
# the last few lines.
nix_failure() {
  local all drv
  all=$({ sed -n 's/^@nix //p' "$NIXLOG" \
      | jq -Rr 'fromjson? | select(.action == "msg" and .level <= 1) | .msg' 2>/dev/null \
      | sed -e 's/\x1b\[[0-9;]*m//g'; \
    grep -av '^@nix ' "$NIXLOG" "$NIXOUT" | sed 's/^[^:]*://'; } || true)
  # The most telling lines first (the failing builder, a failed download), else the last ones.
  NIX_ERRS=$(printf '%s\n' "$all" | { grep -aE 'builder for|unable to download|Could not resolve|error: |No space left|out of memory|killed' || true; } | { grep -av 'dependency failed' || true; } | head -n 4)
  [ -n "$NIX_ERRS" ] || NIX_ERRS=$(printf '%s\n' "$all" | { grep -a . || true; } | tail -n 6)
  { echo "=== nix error messages (exit $NIX_RC)"; printf '%s\n' "$all"; } >>"$LOG"
  for drv in $(printf '%s\n' "$all" | { grep -aE 'builder for|Cannot build|build of|failed' || true; } \
      | { grep -aoE '/nix/store/[a-z0-9]{32}-[^] ,;:'\''"]*\.drv' || true; } | sort -u | head -n 8); do
    {
      echo "=== nix log $drv"
      nix --extra-experimental-features nix-command log --store "$MNT" "$drv" 2>&1 \
        || nix --extra-experimental-features nix-command log "$drv" 2>&1 \
        || echo "(no build log kept)"
    } >>"$LOG"
  done
  echo "--- nix failed (exit $NIX_RC); last lines:" >&2
  printf '%s\n' "$NIX_ERRS" >&2
}

nix_cleanup() { rm -f "$NIXLOG" "$NIXOUT"; }

# ---------------------------------------------------------------------------------------------
# 4. SYSTEM STAGE: install the base system, no apps.
# ---------------------------------------------------------------------------------------------
progress packages 32 "Copying flake inputs to the new system"
# The inputs the lock pins are in this installer's store; the new system keeps them too, so a
# rebuild with an unchanged lock needs no network either.
xargs -a "$SOURCES_FILE" nix --extra-experimental-features nix-command copy --no-check-sigs --to "$MNT" \
  >>"$LOG" 2>&1 || fail 1 copy-failed "could not copy the flake inputs to $MNT; see $LOG"

# nix turns substitution off as soon as the machine has no network interface with an address
# ("you don't have Internet access; disabling some network-dependent features"), local store
# substituters included. Without this an offline install on a box without a cable substituted
# nothing and tried to build the world from source (bash-5.3.tar.gz and friends).
subst_flags=(--option substitute true)
offline_flags=(--option substituters "auto?trusted=1")

# The system stage, in three steps (see the top of this file): `packages` (nix build --dry-run
# finds what is needed, then the packages to fetch are copied or downloaded into the target),
# `build` (the system's derivation, built in the target), `bootloader` (nixos-install --system:
# the system profile and the boot loader; it builds nothing). The nix calls are the build
# nixos-install does itself (nix build --store /mnt --extra-substituters auto?trusted=1, the
# installer's own store), split so that each step can show its own count.
sys_stage=packages # the step that runs (warnings and errors are reported with it)
sys_offline=0      # 1: the nix calls use only this installer's store
SYS_FLAGS=()       # the store and substituter flags of every nix call
SYS_DRV=           # the system's derivation (from the dry run)
SYS_TOPLEVEL=      # its output: what the boot loader step installs
SYS_BUILDS=()      # derivations the dry run lists as to be built
# Builds use the target disk for their temporary files (as nixos-install does), not the
# installer's memory.
sys_tmp=$(mktemp -d -p "$MNT")
tmp_dirs+=("$sys_tmp")

# sys_nix CMD-ARGS...: nix with flakes, temporary files on the target.
# shellcheck disable=SC2329 # run via nix_logged
sys_nix() { env TMPDIR="$sys_tmp" nix --extra-experimental-features 'nix-command flakes' "$@"; }

# dry_list built|fetched FILE: the store paths `nix build --dry-run` lists under that heading
# ("these N derivations will be built:" / "this path will be fetched (...):", one indented path
# per line).
dry_list() {
  awk -v w="$1" '
    /^(these [0-9]+ derivations|this derivation) will be built:/ { s = (w == "built"); next }
    /^(these [0-9]+ paths|this path) will be fetched/ { s = (w == "fetched"); next }
    /^[[:space:]]+\/nix\/store\// { if (s) print $1; next }
    { s = 0 }' "$2"
}

# sys_packages ONLINE(0|1): the package list, then the packages to fetch, into the target.
sys_packages() {
  local fetch=() n word=copy
  [ "$1" -eq 0 ] || word=download
  sys_stage=packages
  sys_offline=$((1 - $1))
  SYS_FLAGS=(--store "$MNT" --extra-substituters "auto?trusted=1" "${subst_flags[@]}")
  if [ "$sys_offline" -eq 1 ]; then
    # Offline: this installer's store is the only substituter (set the list, after the extra one).
    SYS_FLAGS+=("${offline_flags[@]}")
  fi
  step_pct=
  progress packages 36 "Getting the package list"
  nix_logged quiet packages 36 36 "" 0 sys_nix build "${SYS_FLAGS[@]}" --no-update-lock-file \
    --dry-run --json --no-link "path:$cfg#nixosConfigurations.hinteros.config.system.build.toplevel"
  [ "$NIX_RC" -eq 0 ] || return 1
  SYS_DRV=$(jq -r '.[0].drvPath // empty' "$NIXOUT" 2>>"$LOG" || true)
  SYS_TOPLEVEL=$(jq -r '.[0].outputs.out // empty' "$NIXOUT" 2>>"$LOG" || true)
  if [ -z "$SYS_DRV" ] || [ -z "$SYS_TOPLEVEL" ]; then
    echo "nix build --dry-run named no system derivation and output" | tee -a "$NIXLOG" >>"$LOG"
    NIX_RC=1
    return 1
  fi
  mapfile -t SYS_BUILDS < <(dry_list built "$NIXLOG")
  mapfile -t fetch < <(dry_list fetched "$NIXLOG")
  n=${#fetch[@]}
  echo "system: ${#SYS_BUILDS[@]} to build, $n to $word: $SYS_DRV -> $SYS_TOPLEVEL" >>"$LOG"
  if [ "$n" -eq 0 ]; then
    step_pct=100
    progress packages 50 "Nothing to $word"
    step_pct=
    return 0
  fi
  step_pct=0
  progress packages 36 "0 of $n packages"
  nix_logged packages packages 36 50 "" "$n" sys_nix build "${SYS_FLAGS[@]}" --no-link \
    --log-format internal-json -v "${fetch[@]}"
  [ "$NIX_RC" -eq 0 ] || return 1
  if [ "$NIX_STEP" != 100 ]; then
    step_pct=100
    progress packages 50 "$n of $n packages"
    step_pct=
  fi
}

# sys_build: the system's derivation, built in the target (the dry run wrote it there).
sys_build() {
  local n=${#SYS_BUILDS[@]} out
  sys_stage=build
  if [ "$n" -gt 0 ]; then
    step_pct=0
    progress build 50 "0 of $n built" info "" "{\"build_index\":1,\"build_total\":$n}"
  fi
  nix_logged build build 50 66 "" "$n" sys_nix build "${SYS_FLAGS[@]}" --no-link --print-out-paths \
    --log-format internal-json -v "$SYS_DRV^*"
  [ "$NIX_RC" -eq 0 ] || return 1
  out=$(tail -n 1 "$NIXOUT")
  if [ "$out" != "$SYS_TOPLEVEL" ]; then
    echo "the system built is ${out:-nothing}, not $SYS_TOPLEVEL" | tee -a "$NIXLOG" >>"$LOG"
    NIX_RC=1
    return 1
  fi
  step_pct=100
  if [ -z "$NIX_STEP" ] && [ "$n" -eq 0 ]; then
    progress build 66 "Nothing to build" info "" '{"build_index":0,"build_total":0}'
  elif [ "$NIX_STEP" != 100 ]; then
    # nix built more than the dry run said: its own count, as in the last line.
    [[ $NIX_EXTRA =~ \"build_total\":([0-9]+) ]] && [ "${BASH_REMATCH[1]}" -gt "$n" ] && n=${BASH_REMATCH[1]}
    progress build 66 "$n of $n built" info "" "{\"build_index\":$n,\"build_total\":$n}"
  fi
  step_pct=
}

# sys_bootloader: nixos-install --system sets the target's system profile to the system built and
# writes the boot loader (it builds nothing).
sys_bootloader() {
  local flags=(--root "$MNT" --no-root-passwd --no-channel-copy --system "$SYS_TOPLEVEL" "${subst_flags[@]}")
  # nixos-install passes its own --extra-substituters; offline the list is set, as above.
  [ "$sys_offline" -eq 0 ] || flags+=("${offline_flags[@]}")
  sys_stage=bootloader
  step_pct=
  progress bootloader 66 "Installing the boot loader"
  nix_logged quiet bootloader 66 66 "" 0 nixos-install "${flags[@]}"
  [ "$NIX_RC" -eq 0 ]
}

# install_system ONLINE(0|1): the three steps; NIX_RC and sys_stage tell how far it got.
install_system() {
  sys_packages "$1" && sys_build && sys_bootloader
}

# An offline system stage installs exactly what this medium carries: the box features of the
# picked apps on it (none: free ISO apps need none), not those of an online-only app (Steam's
# graphics32 needs 32-bit Mesa, which is not on the medium). Such an app's features come with the
# box's first online rebuild or update (hinteros-system adds what the profiles' envs need).
offline_state() {
  requirements=$(app_requirements "$(json_array "${apps[@]}" | jq -c --slurpfile cat "$APPS_JSON" \
    '[.[] | select(. as $a | $cat[0].onIso | index($a))]')")
  write_state
}

sys_online=$online
[ "$sys_online" -eq 1 ] || offline_state
attempt=1
while :; do
  if install_system "$sys_online"; then break; fi
  [ "$NIX_RC" -ne 0 ] || NIX_RC=1
  nix_failure
  if [ "$attempt" -ge 3 ]; then break; fi
  attempt=$((attempt + 1))
  if [ "$sys_stage" = bootloader ] && efi_override; then
    # The system was built; writing the boot loader failed (EFI variables on this firmware?). The
    # override changes the system (its boot loader script), so it is built again from the
    # package list; nearly all of it is in the target already.
    progress bootloader "$percent" "Installing the boot loader failed; retrying without EFI variables" warn bootloader-retry
    continue
  fi
  if [ "$newer" -eq 1 ]; then
    # This installer does not carry the newer system, so there is no offline fallback; only the
    # hardware report can be left out (the box applies it with its next rebuild).
    if [ "$facter_ok" -eq 1 ] && [ ! -e "$cfg/facter.deferred" ]; then
      : >"$cfg/facter.deferred"
      progress "$sys_stage" "$percent" "The install with the hardware report failed; retrying with generic hardware support" warn system-retry
      continue
    fi
    break
  fi
  if [ "$sys_online" -eq 1 ] || { [ "$facter_ok" -eq 1 ] && [ ! -e "$cfg/facter.deferred" ]; }; then
    # Online (or with the hardware report applied) something could not be fetched or built:
    # fall back to exactly the generic system that is on this medium.
    : >"$cfg/facter.deferred"
    sys_online=0
    offline_state
    progress "$sys_stage" "$percent" "The install with network access failed; retrying with the generic system from this installer" warn system-retry
    continue
  fi
  break
done
if [ "$NIX_RC" != 0 ]; then
  nix_cleanup
  fail 1 install-failed "nixos-install failed (exit $NIX_RC): $(printf '%s' "$NIX_ERRS" | tail -n 4 | tr '\n' ' ' | cut -c1-600); see $LOG"
fi
nix_cleanup
step_pct=100
progress bootloader 70 "System installed, boot loader written"
step_pct=
rm -rf "$sys_tmp"

progress snapshot 72 "Checking the config snapshot"
base_system=$(readlink -f "$MNT/nix/var/nix/profiles/system")
snap="$MNT$base_system/hinteros"
[ -d "$snap" ] || fail 1 snapshot-missing "the installed system has no config snapshot ($base_system/hinteros)"
check_snapshot() { # restore /etc/hinteros from the generation (its truth) if it differs
  local f
  for f in flake.nix flake.lock state.json; do
    if ! cmp -s "$1/$f" "$cfg/$f"; then
      progress snapshot "$percent" "$f differs from the system's snapshot; restoring the snapshot" warn snapshot-differs
      install -m 0644 "$1/$f" "$cfg/$f"
    fi
  done
}
check_snapshot "$snap"
progress snapshot 73 "/etc/hinteros matches the installed generation"

if [ -n "$wifi_ssid" ]; then
  # Keep the connection so the box is online at first boot.
  conn_dir=/etc/NetworkManager/system-connections
  if [ -d "$conn_dir" ]; then
    install -d -m 0755 "$MNT/etc/NetworkManager/system-connections"
    for f in "$conn_dir"/*; do
      [ -f "$f" ] || continue
      if grep -qxF "ssid=$wifi_ssid" "$f"; then
        install -m 0600 "$f" "$MNT/etc/NetworkManager/system-connections/$(basename "$f")"
      fi
    done
  fi
fi

# ---------------------------------------------------------------------------------------------
# 5. APPS STAGE: the starter set. The system above is not touched.
# ---------------------------------------------------------------------------------------------
installed_apps=()

finish() { # leaves the run: flush, unmount, final line
  local failed_json msg
  failed_json=$(json_array "${failed_apps[@]}")
  progress finalize 97 "Flushing to disk"
  sync
  if ! umount -R "$MNT" >>"$LOG" 2>&1; then
    progress finalize 98 "Could not unmount $MNT cleanly; reboot after the disk activity stops" warn unmount-failed
  fi
  if [ "$newer" -eq 1 ]; then
    msg="HinterOS $install_version is installed (revision $install_rev, downloaded from the $channel channel)."
  else
    msg="HinterOS $install_version is installed (revision $install_rev, from this installer)."
  fi
  if [ "${#failed_apps[@]}" -gt 0 ]; then
    msg="$msg These apps could not be installed: ${failed_apps[*]} (they can be added later from the Store)."
  fi
  msg="$msg Remove the installer medium and reboot."
  progress "done" 100 "$msg" info "" "$(jq -nc --argjson f "$failed_json" --arg rev "$install_rev" \
    --arg v "$install_version" '{failed_apps: $f, rev: $rev, version: $v}')"
  exit 0
}

# shellcheck disable=SC2329 # the ERR trap of the apps stage
apps_error() {
  local rc=$1 line=$2 cmd=$3
  [ "$BASHPID" = "$main_pid" ] || exit "$rc"
  echo "apps stage: failed command (exit $rc, line $line): $cmd" >>"$LOG"
  progress apps "$percent" "unexpected failure in the apps stage (exit $rc); keeping the base system" warn apps-internal
  apps_rescue
}

# Best effort after an unexpected failure in the apps stage: an empty starter set (the system
# itself is untouched by this stage).
# shellcheck disable=SC2329 # the ERR trap of the apps stage
apps_rescue() {
  trap - ERR
  set +e
  failed_apps=("${apps[@]}")
  cur_app=
  rm -f "$profiles_dir/starter" "$profiles_dir"/starter-*-link
  write_starter '[]'
  write_terms '[]'
  finish
}

# The starter env (apps.md "Installer and first boot"): the same `config.hinteros.appEnv.build`
# as on the box, against the target's configuration, built into the target's store, and set as
# the target's /nix/var/nix/profiles/hinteros/starter. Offline, every subset of the apps on this
# installer is in its store already (nixos/installer). No profile is created here: first-boot mode
# sets the admin profile's apps to this env.
profiles_dir=$MNT/nix/var/nix/profiles/hinteros
install -d -m 0755 "$MNT/nix/var/nix/profiles" "$profiles_dir" "$profiles_dir/apps"
phase=apps
apps_online=$online
[ -n "$ONLINE_APPS_HOOK" ] && apps_online=1
trap 'apps_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
progress apps 74 "Preparing the starter apps: ${apps[*]:-none}"
env_flags=(--impure --no-link --print-out-paths --log-format internal-json -v "${subst_flags[@]}")
if [ "$apps_online" -eq 0 ]; then
  env_flags+=("${offline_flags[@]}")
fi
ENV_OUT=
# build_env JSON_ARRAY LO HI: the starter env of these apps -> $ENV_OUT, NIX_RC.
build_env() {
  ENV_OUT=
  nix_logged combined apps "$2" "$3" "Building" 0 nix --extra-experimental-features 'nix-command flakes' build \
    --store "$MNT" --extra-substituters "auto?trusted=1" "${env_flags[@]}" --expr \
    "(builtins.getFlake \"path:$cfg\").nixosConfigurations.hinteros.config.hinteros.appEnv.build (builtins.fromJSON ''$1'')"
  if [ "$NIX_RC" -eq 0 ]; then
    ENV_OUT=$(tail -n 1 "$NIXOUT")
    # Inside the target: the env is a tree of absolute /nix/store symlinks, which seen from the
    # installer point into the installer's store. An env that is not on this medium (a newer
    # revision's, whose manifest names another system_rev) is only in the target's store.
    if [ -z "$ENV_OUT" ] || ! chroot "$MNT" "$base_system/sw/bin/test" -e "$ENV_OUT/share/hinteros/apps.json"; then
      echo "the env built (${ENV_OUT:-no output}) has no share/hinteros/apps.json in the target" >>"$LOG"
      NIX_RC=1
    fi
  fi
  [ "$NIX_RC" -eq 0 ]
}

good=()
good_out=
# One build per app, each adding the app to those that already worked: the progress bar then
# follows one app at a time, and an app that fails to build does not take the others with it.
# (Whatever an earlier build produced is in the store already, so only the new app costs time.)
apps_total=${#apps[@]}
n=0
for a in "${apps[@]}"; do
  cur_app=$a
  n=$((n + 1))
  cur_app_n=$n
  lo=$((76 + (n - 1) * 14 / apps_total))
  hi=$((76 + n * 14 / apps_total))
  step_pct=
  if [ -n "${skip_apps[$a]:-}" ]; then
    failed_apps+=("$a")
    progress apps "$hi" "$a could not be installed: ${skip_apps[$a]}" warn app-failed
    continue
  fi
  progress apps "$lo" "Installing $a ($n of $apps_total)"
  if build_env "$(json_array "${good[@]}" "$a")" "$lo" "$hi"; then
    good+=("$a")
    good_out=$ENV_OUT
    step_pct=100
    progress apps "$hi" "$a is built"
    step_pct=
  else
    nix_failure
    failed_apps+=("$a")
    progress apps "$percent" "$a could not be installed: $(printf '%s' "$NIX_ERRS" | tail -n 3 | tr '\n' ' ' | cut -c1-400)" warn app-failed
  fi
done
cur_app=
cur_app_n=0
if [ -z "$good_out" ]; then
  # No apps (none picked, or none worked): an empty starter env, so new profiles start alike.
  build_env '[]' 90 91 || { nix_failure; nix_cleanup; fail 1 install-failed "could not build the (empty) starter env; see $LOG"; }
  good_out=$ENV_OUT
fi
nix_cleanup
progress apps 92 "Setting the starter apps: ${good[*]:-none}"
ln -sfn "$good_out" "$profiles_dir/starter-1-link"
ln -sfn starter-1-link "$profiles_dir/starter"
installed_apps=("${good[@]}")
write_starter "$(json_array "${installed_apps[@]}")"
write_terms "$(json_array "${installed_apps[@]}")"
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

finish
