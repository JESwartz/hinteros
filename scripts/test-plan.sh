#!/usr/bin/env bash
# test-plan: which checks to run for a change, in three tiers.
#
#   scripts/test-plan.sh quick              eval checks only (a few minutes)
#   scripts/test-plan.sh targeted [BASE]    eval checks + the VM tests for what changed since BASE
#                                           (default origin/main), from the changed files and the
#                                           component revisions in flake.lock
#   scripts/test-plan.sh full               everything (once per release, before promoting a beta)
#   add --run to build them one at a time (throttled), else the list is printed
#
# VM tests run strictly one at a time: each boots its own VMs and this machine's memory is shared.
set -euo pipefail

EVAL=(runtime-eval profiles-eval daemon-eval mk-device hardening-eval installer-iso-eval
  offline-inputs state-check promote apps server-eval pre-commit)

# Area -> VM tests. A change to a test's own file always adds that test.
INSTALLER=(install-validation install-offline install-keep-data install-newer installer-ui installer-save-log)
PROFILES=(profiles-greeter profiles-switch profiles-pin profiles-lifecycle profiles-lock
  profiles-isolation guest system-authz)
APPS=(profile-apps profile-apps-system apps-box-features store-install)
SESSION=(gamescope session-restart input-layer)
SYSTEM=(system-authz system-jobs system-update system-escalation polkit-agent time-zone)
SANDBOX=(sandbox sandbox-apps sandbox-lan sandbox-pad gamescope-sandbox steam-sockets)
SERVER=(server-api server-network server-jellyfin server-jellyfin-signin)
# The daemon and the launcher touch nearly everything; this is the set that exercises each part
# once (session, profiles, apps, jobs, authorization, input, installer UI).
DAEMON=(system-authz system-jobs system-update profiles-greeter profiles-switch profiles-pin guest profile-apps
  session-restart gamescope input-layer runtime time-zone sandbox sandbox-lan server-api)
LAUNCHER=(installer-ui profiles-greeter gamescope typing input-layer)

mode=${1:-}
[ -n "$mode" ] || {
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}
shift
run=0
base=origin/main
for a in "$@"; do
  case "$a" in
    --run) run=1 ;;
    *) base=$a ;;
  esac
done
cd "$(git rev-parse --show-toplevel)"
mapfile -t ALL < <(nix eval --json .#checks.x86_64-linux --apply builtins.attrNames | jq -r '.[]')
is_check() { printf '%s\n' "${ALL[@]}" | grep -qx "$1"; }

vm=()
add() { for t in "$@"; do vm+=("$t"); done; }

case "$mode" in
  quick) ;;
  full)
    for t in "${ALL[@]}"; do
      printf '%s\n' "${EVAL[@]}" pre-commit | grep -qx "$t" || vm+=("$t")
    done
    ;;
  targeted)
    git rev-parse -q --verify "$base^{commit}" >/dev/null || {
      echo "test-plan: $base is not a commit (fetch first?)" >&2
      exit 2
    }
    while read -r f; do
      # Specific paths first: in `case`, * also matches /.
      case "$f" in
        tests/vm/system/profiles.nix) add "${PROFILES[@]}" ;;
        tests/vm/install/*) add "${INSTALLER[@]}" ;;
        tests/vm/fixtures/bootstrap-channel/*) add bootstrap-channel ;;
        tests/vm/system/*) add "${SYSTEM[@]}" ;;
        tests/vm/*/*) ;;
        tests/vm/*.nix)
          t=$(basename "$f" .nix)
          if is_check "$t"; then add "$t"; fi
          ;;
        nixos/pkgs/hinteros-install/* | nixos/installer/* | nixos/modules/disk.nix) add "${INSTALLER[@]}" ;;
        nixos/modules/profiles.nix) add "${PROFILES[@]}" ;;
        nixos/modules/state.nix) add "${PROFILES[@]}" time-zone install-validation install-keep-data ;;
        nixos/modules/time-zone.nix | nixos/lib/time-zone.nix) add time-zone ;;
        nixos/modules/device-config.nix) add config-sync time-zone ;;
        nixos/modules/app-env.nix | nixos/modules/apps.nix | nixos/modules/box-features.nix | nixos/modules/catalog.nix) add "${APPS[@]}" "${SANDBOX[@]}" ;;
        nixos/modules/session.nix | nixos/pkgs/gamescope/*) add "${SESSION[@]}" ;;
        nixos/modules/input.nix | nixos/pkgs/inputplumber/*) add input-layer typing profiles-switch ;;
        nixos/modules/daemon.nix) add "${SYSTEM[@]}" bootstrap-channel ;;
        nixos/pkgs/hinteros-bootstrap-channel/*) add bootstrap-channel ;;
        nixos/modules/hardening.nix) add hardening system-escalation ;;
        nixos/modules/maintenance.nix) add boot ;;
        nixos/modules/runtime.nix | nixos/modules/network-hardware.nix) add runtime runtime-settings ;;
        nixos/modules/firefox-kiosk.nix | nixos/modules/firefox-osk-chrome.js) add tv-apps typing ;;
        nixos/pkgs/fake-steam/*) add fake-steam gamescope ;;
        # What the installer builds from: the device flake template and lock, the ISO's offline
        # inputs, the app lists, the release keys and version.
        nixos/templates/* | nixos/lib/device-lock.nix | nixos/lib/offline-inputs.* | nixos/lib/allowed-signers.nix | nixos/modules/release.nix)
          add "${INSTALLER[@]}"
          ;;
        nixos/lib/app-ids.nix) add "${INSTALLER[@]}" "${APPS[@]}" ;;
        nixos/modules/generic-hardware.nix) add "${INSTALLER[@]}" install-offline-hw ;;
        nixos/lib/mk-device.nix | nixos/lib/device-outputs.nix) add config-sync install-validation install-keep-data ;;
        nixos/lib/app-entries.nix) add "${APPS[@]}" tv-apps ;;
        nixos/lib/local-networks.nix) add hardening sandbox-lan ;;
        nixos/lib/steam.nix) add steam-sockets fake-steam ;;
        nixos/modules/server.nix | nixos/modules/jellyfin-signin.*) add "${SERVER[@]}" ;;
        nixos/modules/branding.nix) add boot installer-ui ;;
        nixos/modules/diagnostics.nix) add installer-save-log ;;
        nixos/modules/video-hardware.nix | nixos/modules/default.nix | nixos/modules/overlay.nix | nixos/pkgs/placeholder-home.nix | nixos/vm/*)
          add boot gamescope
          ;;
        nixos/pkgs/firefox-kiosk.nix) add tv-apps typing ;;
        flake.nix)
          add boot
          echo "test-plan: flake.nix changed: check which tests it touches, or run the full tier" >&2
          ;;
      esac
    done < <(git diff --name-only "$base"...HEAD)
    # Components: compare the locked revisions.
    lockdiff=$(jq -r --slurpfile o <(git show "$base:flake.lock") '
      .nodes | to_entries[] | select(.value.locked.rev != null)
      | select($o[0].nodes[.key].locked.rev != .value.locked.rev) | .key' flake.lock)
    for k in $lockdiff; do
      case "$k" in
        hinteros-daemon) add "${DAEMON[@]}" ;;
        hinteros-launcher) add "${LAUNCHER[@]}" ;;
        hinteros-catalog) add "${APPS[@]}" tv-apps ;;
        nixpkgs*) echo "test-plan: nixpkgs changed: run the full tier" >&2 ;;
      esac
    done
    ;;
  *)
    echo "test-plan: unknown tier $mode (quick, targeted, full)" >&2
    exit 2
    ;;
esac

# Keep order, drop duplicates.
mapfile -t vm < <(printf '%s\n' "${vm[@]}" | awk 'NF && !seen[$0]++')
echo "eval: ${EVAL[*]}"
echo "vm (${#vm[@]}): ${vm[*]:-none}"
[ "$run" = 1 ] || exit 0

# Throttled: a memory cap in a user scope where there is a user manager (not on every CI runner).
T=(nice -n 19)
if systemd-run --user --scope -q true 2>/dev/null; then
  T=(systemd-run --user --scope -q -p MemoryHigh=12G -p MemoryMax=16G -p CPUWeight=idle nice -n 19)
fi
logs=${TMPDIR:-/tmp}
failed=()
for c in "${EVAL[@]}" "${vm[@]}"; do
  printf '== %s ... ' "$c"
  start=$(date +%s)
  if "${T[@]}" nix build --no-link --max-jobs 1 --cores 8 ".#checks.x86_64-linux.$c" >"$logs/test-plan.$c.log" 2>&1; then
    echo "ok ($(($(date +%s) - start)) s)"
  else
    echo "FAILED ($(($(date +%s) - start)) s, log $logs/test-plan.$c.log)"
    tail -n 40 "$logs/test-plan.$c.log" | sed 's/^/   | /'
    failed+=("$c")
  fi
done
[ "${#failed[@]}" -eq 0 ] || {
  echo "failed: ${failed[*]}"
  exit 1
}
