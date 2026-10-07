#!@bash@
# hinteros-install: installs HinterOS from the installer ISO according to a JSON plan.
#
#   hinteros-install --plan plan.json [--validate-only]
#
# stdout carries one JSON object per line, for a UI to follow:
#   {"stage":"partition","percent":14,"level":"info","message":"..."}
# `level` is info, warn or error; an error line also has a `code` and the process then exits
# non-zero (2: the plan or the machine is not acceptable, nothing was touched; 1: failed
# part-way). The last line of a successful run has stage "done" and percent 100. Everything
# else (tool output) goes to stderr and to /var/log/hinteros-install.log.
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
LOG=${HINTEROS_INSTALL_LOG:-/var/log/hinteros-install.log}
MNT=/mnt
TARGET_LINK=/dev/hinteros-target
MIN_DISK_GIB=16
# Test hook: the command that writes the hardware report (VM tests feed a fixture).
FACTER=${HINTEROS_INSTALL_FACTER:-nixos-facter}

# Progress goes to the original stdout; anything a tool prints to stdout is moved to stderr.
exec 3>&1 1>&2

stage=validate
percent=0

progress() { # stage percent message [level] [code]
  jq -nc --arg stage "$1" --argjson percent "$2" --arg message "$3" --arg level "${4:-info}" \
    --arg code "${5:-}" \
    '{stage: $stage, percent: $percent, level: $level, message: $message}
     + (if $code == "" then {} else {code: $code} end)' >&3
  stage=$1
  percent=$2
  echo "[$1 $2%] $3" >&2
}

# fail EXITCODE CODE MESSAGE: report and stop.
fail() {
  progress "$stage" "$percent" "$3" error "$2"
  exit "$1"
}

# Unexpected failures (set -e) still end with an error line the UI can show.
on_error() {
  local rc=$? line=$1
  trap - ERR
  echo "--- last lines of $LOG" >&2
  tail -n 30 "$LOG" >&2 || true
  progress "$stage" "$percent" "unexpected failure (exit $rc, line $line); see $LOG" error internal
  exit 1
}
trap 'on_error $LINENO' ERR

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

usage() {
  cat >&2 <<'USAGE'
usage: hinteros-install --plan FILE|- [--validate-only]

Installs HinterOS on the disk named in the plan, erasing it. The plan is a JSON object, see
the README ("Installer"). With --validate-only the plan and the machine are checked and
nothing is touched.
USAGE
  exit 2
}

plan_file=
validate_only=0
while [ $# -gt 0 ]; do
  case $1 in
    --plan)
      [ $# -ge 2 ] || usage
      plan_file=$2
      shift 2
      ;;
    --validate-only)
      validate_only=1
      shift
      ;;
    -h | --help) usage ;;
    *) usage ;;
  esac
done
[ -n "$plan_file" ] || usage

mkdir -p "$(dirname "$LOG")"
: >>"$LOG"
chmod 0600 "$LOG"

[ "$(id -u)" -eq 0 ] || fail 2 not-root "hinteros-install must run as root"

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
PLAN=$(printf '%s' "$PLAN" | jq -c '{
  disk, hostname, admin, wifi,
  ssh: (.ssh // {enable: false}),
  channel: (.channel // "stable"),
  base: (.base // "unstable"),
  network: (.network // "auto"),
  apps: (.apps // []),
  acceptedTerms: (.acceptedTerms // {}),
  unknown: (keys - ["disk", "hostname", "admin", "ssh", "channel", "base", "network", "apps", "wifi", "acceptedTerms"])
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
  if curl -fsS --max-time 8 -o /dev/null https://cache.nixos.org/nix-cache-info >>"$LOG" 2>&1; then
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

if [ "$online" -eq 0 ] && [ "${#apps[@]}" -gt 0 ]; then
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
if mountpoint -q "$MNT"; then
  mnt_src=$(findmnt -no SOURCE "$MNT")
  case $(lsblk -rno PKNAME "$mnt_src" 2>/dev/null | head -n1) in
    "$(basename "$disk_real")") ;;
    *) fail 2 mnt-in-use "$MNT is mounted from $mnt_src, which is not on $disk" ;;
  esac
fi

progress validate 8 "Plan accepted: install on $disk ($((disk_bytes / 1024 / 1024 / 1024)) GiB), host name $hostname, apps: ${apps[*]:-none}"

if [ "$validate_only" -eq 1 ]; then
  progress "done" 100 "Plan and machine are fine (validate only; nothing was touched)"
  exit 0
fi

# ---------------------------------------------------------------------------------------------
# 2. Partition and format (disko), mounted at /mnt.
# ---------------------------------------------------------------------------------------------
progress partition 10 "Erasing and partitioning $disk"
if mountpoint -q "$MNT"; then
  run "Unmounting $MNT" umount -R "$MNT"
fi
# The disko layout names the disk /dev/hinteros-target; this link points it at the real one.
ln -sfn "$disk_real" "$TARGET_LINK"
run "Partitioning" "$DISKO_SCRIPT" --yes-wipe-all-disks
rm -f "$TARGET_LINK"
udevadm settle >>"$LOG" 2>&1 || true
if ! { mountpoint -q "$MNT" && mountpoint -q "$MNT/boot"; }; then
  fail 1 mount-failed "the new file systems are not mounted at $MNT"
fi
progress partition 20 "Disk is partitioned and mounted"

# ---------------------------------------------------------------------------------------------
# 3. The device config: /etc/hinteros.
# ---------------------------------------------------------------------------------------------
cfg=$MNT/etc/hinteros
install -d -m 0755 "$MNT/etc" "$cfg" "$MNT/var/lib/hinteros"

progress facter 22 "Detecting hardware"
if $FACTER -o "$cfg/facter.json" >>"$LOG" 2>&1 && jq -e . "$cfg/facter.json" >/dev/null 2>&1; then
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
jq -n --arg base "$base" --arg sv "$STATE_VERSION" --arg host "$hostname" --arg admin "$admin_user" \
  --argjson ssh "$ssh_enable" --argjson apps "$(plan '.apps')" '{
    schemaVersion: 1,
    base: $base,
    stateVersion: $sv,
    settings: {hostname: $host, ssh: {enable: $ssh}, admin: {user: $admin}},
    disk: {layout: "gpt-esp-ext4"},
    apps: $apps,
    profiles: []
  }' >"$cfg/state.json"

extra=
if [ -n "${HINTEROS_INSTALL_EXTRA_MODULE:-}" ]; then
  # Test hook: one more NixOS module for the installed system (the VM test adds its
  # instrumentation this way). Not part of the plan; unset on real installs.
  install -m 0644 "$HINTEROS_INSTALL_EXTRA_MODULE" "$cfg/extra-module.nix"
  extra=./extra-module.nix
fi
sed -e "s|%CHANNEL%|$channel|g" -e "s|%REPO%|$REPO_URL|g" -e "s|%EXTRA%|$extra|g" \
  "$TEMPLATE" >"$cfg/flake.nix"
# The lock pins hinteros (and everything it locks) to the revision on this installer, so the
# evaluation needs no network; `nix flake update hinteros` later moves it to the channel.
jq --arg ref "$channel" \
  '.nodes.hinteros.original.ref = $ref | .nodes.hinteros.locked.ref = "refs/heads/" + $ref' \
  "$OFFLINE_LOCK" >"$cfg/flake.lock"
chmod 0644 "$cfg/flake.nix" "$cfg/flake.lock" "$cfg/state.json"
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
# adds to it when apps are installed later.
(
  umask 0077
  jq -n --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson apps "$(plan -c .apps)" \
    --slurpfile idx "$CATALOG_INDEX" '
    [$apps[] as $a | $idx[0].apps[] | select(.id == $a and .terms != null)
       | {key: .id, value: [{version: .terms.version, accepted_at: $now, by: "installer"}]}]
    | from_entries' >"$MNT/var/lib/hinteros/terms-accepted.json"
)
chmod 0600 "$MNT/var/lib/hinteros/terms-accepted.json"
progress config 30 "Device configuration written to /etc/hinteros"

# ---------------------------------------------------------------------------------------------
# 4. Install.
# ---------------------------------------------------------------------------------------------
progress install 32 "Copying flake inputs to the new system"
# The inputs the lock pins are in this installer's store; the new system keeps them too, so a
# rebuild with an unchanged lock needs no network either.
xargs -a "$SOURCES_FILE" nix --extra-experimental-features nix-command copy --no-check-sigs --to "$MNT" \
  >>"$LOG" 2>&1 || fail 1 copy-failed "could not copy the flake inputs to $MNT; see $LOG"

progress install 36 "Building and installing the system"
install_flags=(--root "$MNT" --no-root-passwd --no-channel-copy
  --flake "path:$cfg#hinteros" --no-update-lock-file --log-format internal-json -v)
if [ "$online" -eq 0 ]; then
  # Offline: this installer's store is the only substituter. (nixos-install passes its own
  # --extra-substituters before these flags, so the list has to be set, not cleared.)
  install_flags+=(--option substituters "auto?trusted=1")
fi

# nix's internal-json log -> progress lines (copied/built paths of the build). nixos-install runs in
# the background writing to its own file; a reader turns that file into progress lines while it
# runs, and `wait` gives its real exit status (no race with the reader, whatever the reader does).
NIXLOG=$(mktemp)
# shellcheck disable=SC2016
progress_filter='
  foreach (inputs | select(startswith("@nix ")) | .[5:] | fromjson? | select(. != null)) as $e (
    {kinds: {}, prog: {}, last: -1, emit: null};
    .emit = null
    | if $e.action == "start" and ($e.type == 103 or $e.type == 104) then
        .kinds[($e.id | tostring)] = $e.type
      elif $e.action == "result" and $e.type == 105 and (.kinds[($e.id | tostring)] != null) then
        .prog[($e.id | tostring)] = $e.fields
        | ([.prog[] | .[0]] | add) as $done | ([.prog[] | .[1]] | add) as $exp
        | (if $exp > 0 then (36 + (($done / $exp) * 50 | floor)) else 36 end) as $pct
        | if $pct > .last then .last = $pct | .emit = {percent: $pct, message: "Installing: \($done) of \($exp) steps"} else . end
      else . end;
    select(.emit != null) | .emit)'
nixos-install "${install_flags[@]}" >"$NIXLOG" 2>&1 </dev/null &
install_pid=$!
while IFS= read -r p; do
  progress install "$(printf '%s' "$p" | jq -r .percent)" "$(printf '%s' "$p" | jq -r .message)"
done < <(tail -n +1 -F --pid="$install_pid" "$NIXLOG" 2>/dev/null | jq -cnR --unbuffered "$progress_filter" 2>/dev/null || true)
install_rc=0
wait "$install_pid" || install_rc=$?
cat "$NIXLOG" >>"$LOG"
if [ "$install_rc" != 0 ]; then
  # nix's own error messages (level 0 and 1 of the internal-json log, else the plain text).
  errs=$({ sed -n 's/^@nix //p' "$NIXLOG" \
      | jq -Rr 'fromjson? | select(.action == "msg" and .level <= 1) | .msg' 2>/dev/null \
      | sed -e 's/\x1b\[[0-9;]*m//g' | grep -a . | tail -n 6; \
    grep -av '^@nix ' "$NIXLOG" | tail -n 6; } || true)
  echo "--- nixos-install failed (exit $install_rc); last lines:" >&2
  printf '%s\n' "$errs" >&2
  rm -f "$NIXLOG"
  fail 1 install-failed "nixos-install failed (exit $install_rc): $(printf '%s' "$errs" | tail -n 4 | tr '\n' ' ' | cut -c1-600); see $LOG"
fi
rm -f "$NIXLOG"
progress install 90 "System installed, boot loader written"

# ---------------------------------------------------------------------------------------------
# 5. Snapshot, Wi-Fi profile, finish.
# ---------------------------------------------------------------------------------------------
progress snapshot 92 "Checking the config snapshot"
system=$(readlink -f "$MNT/nix/var/nix/profiles/system")
snap="$MNT$system/hinteros"
[ -d "$snap" ] || fail 1 snapshot-missing "the installed system has no config snapshot ($system/hinteros)"
for f in flake.nix flake.lock state.json; do
  if ! cmp -s "$snap/$f" "$cfg/$f"; then
    # Should not happen (the lock is final); the generation is the truth, so /etc/hinteros follows it.
    progress snapshot 93 "$f differs from the system's snapshot; restoring the snapshot" warn snapshot-differs
    install -m 0644 "$snap/$f" "$cfg/$f"
  fi
done
progress snapshot 95 "/etc/hinteros matches the installed generation"

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

progress finalize 97 "Flushing to disk"
sync
if ! umount -R "$MNT" >>"$LOG" 2>&1; then
  progress finalize 98 "Could not unmount $MNT cleanly; reboot after the disk activity stops" warn unmount-failed
fi
progress "done" 100 "HinterOS is installed (installer revision $ISO_REV). Remove the installer medium and reboot."
