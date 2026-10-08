#!@bash@
# hinteros-install: installs HinterOS from the installer ISO according to a JSON plan.
#
#   hinteros-install --plan plan.json [--validate-only]
#
# Two stages. The SYSTEM stage installs the base HinterOS system with no catalog apps (state.json
# `apps: []`), offline from this medium's store if need be. The APPS stage then adds the selected
# apps to the installed system (build + activate for the next boot). Whatever happens to an app,
# the system stage's result stays: the box boots the last good generation.
#
# stdout carries one JSON object per line, for a UI to follow:
#   {"phase":"system","stage":"partition","percent":14,"level":"info","message":"..."}
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
phase=system
cur_app=
failed_apps=()
# Test hook: treat the apps stage as online (no offline restriction, any app id) although there is
# no network, so an online-only app fails to download. The system stage still follows the probe.
ONLINE_APPS_HOOK=${HINTEROS_INSTALL_ONLINE_APPS:-}

progress() { # stage percent message [level] [code] [extra-json-object]
  # Never backwards (the stages run several builds that each count from their own start).
  [ "$2" -ge "$percent" ] || set -- "$1" "$percent" "${@:3}"
  jq -nc --arg phase "$phase" --arg stage "$1" --argjson percent "$2" --arg message "$3" \
    --arg level "${4:-info}" --arg code "${5:-}" --arg app "$cur_app" --argjson extra "${6:-"{}"}" \
    '{phase: $phase, stage: $stage, percent: $percent, level: $level, message: $message}
     + (if $app == "" then {} else {app: $app} end)
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

progress validate 8 "Plan accepted: install on $disk ($((disk_bytes / 1024 / 1024 / 1024)) GiB), host name $hostname, apps: ${apps[*]:-none}"

if [ "$validate_only" -eq 1 ]; then
  progress "done" 100 "Plan and machine are fine (validate only; nothing was touched)" info "" '{"failed_apps": []}'
  exit 0
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
# 3. The device config: /etc/hinteros. The system stage installs it with no apps.
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
# state.json for a set of apps (a JSON array of ids).
write_state() {
  jq -n --arg base "$base" --arg sv "$STATE_VERSION" --arg host "$hostname" --arg admin "$admin_user" \
    --argjson ssh "$ssh_enable" --argjson apps "$1" '{
      schemaVersion: 1,
      base: $base,
      stateVersion: $sv,
      settings: {hostname: $host, ssh: {enable: $ssh}, admin: {user: $admin}},
      disk: {layout: "gpt-esp-ext4"},
      apps: $apps,
      profiles: []
    }' >"$cfg/state.json"
  chmod 0644 "$cfg/state.json"
}
write_state '[]'

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
# evaluation needs no network; `nix flake update hinteros` later moves it to the channel.
jq --arg ref "$channel" \
  '.nodes.hinteros.original.ref = $ref | .nodes.hinteros.locked.ref = "refs/heads/" + $ref' \
  "$OFFLINE_LOCK" >"$cfg/flake.lock"
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
        | (if $exp > 0 then ($lo + (($done / $exp) * ($hi - $lo) | floor)) else $lo end) as $pct
        | if $pct > .last then .last = $pct | .emit = {percent: $pct, message: "\($done) of \($exp) steps"} else . end
      else . end;
    select(.emit != null) | .emit)'

# nix_logged STAGE LO HI LABEL CMD...: runs CMD in the background with its output in files and
# turns nix's internal-json log into progress lines between LO and HI percent. Sets NIX_RC; the
# output is in $NIXLOG (stderr) and $NIXOUT (stdout) until the next call, and in the log file.
nix_logged() {
  local st=$1 lo=$2 hi=$3 label=$4 pid p
  shift 4
  rm -f "$NIXLOG" "$NIXOUT"
  NIXLOG=$(mktemp)
  NIXOUT=$(mktemp)
  echo "+ $*" >>"$LOG"
  "$@" >"$NIXOUT" 2>"$NIXLOG" </dev/null &
  pid=$!
  while IFS= read -r p; do
    progress "$st" "$(printf '%s' "$p" | jq -r .percent)" "$label: $(printf '%s' "$p" | jq -r .message)"
  done < <(tail -n +1 -F --pid="$pid" "$NIXLOG" 2>/dev/null | jq -cnR --unbuffered --argjson lo "$lo" --argjson hi "$hi" "$progress_filter" 2>/dev/null || true)
  NIX_RC=0
  wait "$pid" || NIX_RC=$?
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
progress install 32 "Copying flake inputs to the new system"
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

# install_system ONLINE(0|1): nixos-install of the device flake.
install_system() {
  local flags=(--root "$MNT" --no-root-passwd --no-channel-copy
    --flake "path:$cfg#hinteros" --no-update-lock-file --log-format internal-json -v "${subst_flags[@]}")
  if [ "$1" -eq 0 ]; then
    # Offline: this installer's store is the only substituter. (nixos-install passes its own
    # --extra-substituters before these flags, so the list has to be set, not cleared.)
    flags+=("${offline_flags[@]}")
  fi
  nix_logged install 36 70 "Installing the system" nixos-install "${flags[@]}"
}

progress install 36 "Building and installing the system"
sys_online=$online
attempt=1
while :; do
  install_system "$sys_online"
  [ "$NIX_RC" -eq 0 ] && break
  nix_failure
  if [ "$attempt" -ge 3 ]; then break; fi
  attempt=$((attempt + 1))
  if grep -aq 'installing the boot loader' "$NIXOUT" && efi_override; then
    # The system was built; writing the boot loader failed (EFI variables on this firmware?).
    progress install 36 "Installing the boot loader failed; retrying without EFI variables" warn bootloader-retry
    continue
  fi
  if [ "$sys_online" -eq 1 ] || { [ "$facter_ok" -eq 1 ] && [ ! -e "$cfg/facter.deferred" ]; }; then
    # Online (or with the hardware report applied) something could not be fetched or built:
    # fall back to exactly the generic system that is on this medium.
    : >"$cfg/facter.deferred"
    sys_online=0
    progress install 36 "The install with network access failed; retrying with the generic system from this installer" warn system-retry
    continue
  fi
  break
done
if [ "$NIX_RC" != 0 ]; then
  nix_cleanup
  fail 1 install-failed "nixos-install failed (exit $NIX_RC): $(printf '%s' "$NIX_ERRS" | tail -n 4 | tr '\n' ' ' | cut -c1-600); see $LOG"
fi
nix_cleanup
progress install 70 "System installed, boot loader written"

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
# 5. APPS STAGE: add the selected apps. The base system above stays bootable whatever happens.
# ---------------------------------------------------------------------------------------------
installed_apps=()
commit_started=0

json_array() { jq -nc '$ARGS.positional' --args "$@"; }

finish() { # leaves the run: flush, unmount, final line
  local failed_json msg
  failed_json=$(json_array "${failed_apps[@]}")
  progress finalize 97 "Flushing to disk"
  sync
  if ! umount -R "$MNT" >>"$LOG" 2>&1; then
    progress finalize 98 "Could not unmount $MNT cleanly; reboot after the disk activity stops" warn unmount-failed
  fi
  msg="HinterOS is installed (installer revision $ISO_REV). Remove the installer medium and reboot."
  if [ "${#failed_apps[@]}" -gt 0 ]; then
    msg="HinterOS is installed, but these apps could not be installed: ${failed_apps[*]} (they can be added later from the Store). Remove the installer medium and reboot."
  fi
  progress "done" 100 "$msg" info "" "{\"failed_apps\": $failed_json}"
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

# Best effort after an unexpected failure in the apps stage: the base system is what boots.
# shellcheck disable=SC2329 # the ERR trap of the apps stage
apps_rescue() {
  trap - ERR
  set +e
  failed_apps=("${apps[@]}")
  cur_app=
  write_state '[]'
  write_terms '[]'
  if [ "$commit_started" -eq 1 ]; then
    nixos-install --root "$MNT" --no-root-passwd --no-channel-copy --system "$base_system" >>"$LOG" 2>&1
  fi
  finish
}

if [ "${#apps[@]}" -gt 0 ]; then
  phase=apps
  apps_online=$online
  [ -n "$ONLINE_APPS_HOOK" ] && apps_online=1
  trap 'apps_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
  progress apps 74 "Adding the apps: ${apps[*]}"
  apps_flags=(--no-update-lock-file --no-link --print-out-paths --log-format internal-json -v "${subst_flags[@]}")
  if [ "$apps_online" -eq 0 ]; then
    apps_flags+=("${offline_flags[@]}")
  fi
  APPS_OUT=
  # build_apps JSON_ARRAY LO HI: the toplevel of the system with these apps -> $APPS_OUT, NIX_RC.
  build_apps() {
    write_state "$1"
    APPS_OUT=
    nix_logged apps "$2" "$3" "Building" nix --extra-experimental-features 'nix-command flakes' build \
      "path:$cfg#nixosConfigurations.hinteros.config.system.build.toplevel" --store "$MNT" \
      --extra-substituters "auto?trusted=1" "${apps_flags[@]}"
    if [ "$NIX_RC" -eq 0 ]; then
      APPS_OUT=$(tail -n 1 "$NIXOUT")
      [ -n "$APPS_OUT" ] && [ -e "$MNT$APPS_OUT" ] || NIX_RC=1
    fi
    [ "$NIX_RC" -eq 0 ]
  }

  good=()
  good_out=
  if build_apps "$(json_array "${apps[@]}")" 76 88; then
    good=("${apps[@]}")
    good_out=$APPS_OUT
  else
    nix_failure
    progress apps "$percent" "Building all the apps failed; trying them one at a time" warn apps-retry
    n=0
    for a in "${apps[@]}"; do
      cur_app=$a
      n=$((n + 1))
      lo=$((78 + (n - 1) * 10 / ${#apps[@]}))
      hi=$((78 + n * 10 / ${#apps[@]}))
      if build_apps "$(json_array "${good[@]}" "$a")" "$lo" "$hi"; then
        good+=("$a")
        good_out=$APPS_OUT
      else
        nix_failure
        failed_apps+=("$a")
        progress apps "$percent" "$a could not be installed: $(printf '%s' "$NIX_ERRS" | tail -n 3 | tr '\n' ' ' | cut -c1-400)" warn app-failed
      fi
    done
    cur_app=
  fi
  nix_cleanup

  if [ "${#good[@]}" -gt 0 ]; then
    # Switch the next boot to the system with the apps. This sets the profile and writes the boot
    # loader entry last; the base system's entry stays in the menu.
    write_state "$(json_array "${good[@]}")"
    progress apps 91 "Activating the system with: ${good[*]}"
    commit_started=1
    nix_logged apps 91 95 "Activating" nixos-install --root "$MNT" --no-root-passwd --no-channel-copy \
      --system "$good_out" "${subst_flags[@]}"
    if [ "$NIX_RC" -ne 0 ]; then
      nix_failure
      progress apps "$percent" "Could not activate the system with the apps; keeping the base system: $(printf '%s' "$NIX_ERRS" | tail -n 2 | tr '\n' ' ' | cut -c1-300)" warn apps-activate-failed
      for a in "${good[@]}"; do
        cur_app=$a
        failed_apps+=("$a")
        progress apps "$percent" "$a could not be activated" warn app-failed
      done
      cur_app=
      good=()
      # Back to the base system's profile and boot entry.
      nix_logged apps 95 96 "Restoring" nixos-install --root "$MNT" --no-root-passwd --no-channel-copy --system "$base_system"
      [ "$NIX_RC" -eq 0 ] || { nix_failure; nix_cleanup; fail 1 install-failed "could not restore the base system after the apps failed; see $LOG"; }
    fi
    nix_cleanup
  fi
  installed_apps=("${good[@]}")
  write_state "$(json_array "${installed_apps[@]}")"
  write_terms "$(json_array "${installed_apps[@]}")"
  if [ "${#installed_apps[@]}" -gt 0 ]; then
    snap="$MNT$(readlink -f "$MNT/nix/var/nix/profiles/system")/hinteros"
    [ -d "$snap" ] && check_snapshot "$snap"
  fi
  trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
fi

finish
