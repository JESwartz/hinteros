# Tests

`checks.x86_64-linux` in `flake.nix` is the full list; each check's file starts with what it covers.

- `vm/`: NixOS VM tests, by group:
  - session and display: `boot`, `gamescope`, `gamescope-size`, `gamescope-sandbox`, `input-layer`, `fake-steam`, `typing`, `session-restart`, `runtime`, `runtime-settings`, `config-sync`, `time-zone`, `wifi-iwd`
  - apps and the app sandbox: `tv-apps`, `sandbox`, `sandbox-apps`, `sandbox-pad`, `sandbox-lan`, `steam-sockets`, `store-install`, `apps-box-features`, `profile-apps`, `profile-apps-system`
  - profiles: `profiles-greeter`, `profiles-switch`, `profiles-pin`, `profiles-isolation`, `profiles-lifecycle`, `profiles-lock`, `guest`
  - privileged service and hardening: `hardening`, `system-escalation`, `system-authz`, `system-jobs`, `polkit-agent`
  - installer: `install-offline`, `install-offline-hw`, `install-offline-m900`, `install-app-failure`, `install-validation`, `install-newer`, `install-keep-data`, `installer-ui`, `installer-save-log`
  - server: `server-api`, `server-network`, `server-jellyfin`, `server-jellyfin-signin`

  Not covered by a VM test yet (backlog, 1.0): an update end to end through `hinteros-job@`, that is `update.check`/`update.apply` from a signed channel repo (HOME, SSL_CERT_FILE, the fetch into the mirror, `ssh-keygen -Y verify` against the `/run/current-system` allowed_signers, the flake.lock rewrite) and `channel.set` to an older channel. Until then `daemon-eval` checks the job PATH and the allowed_signers file, and hinteros-system's `updates_are_verified` test covers the verify logic.

  `vm/system/` holds the shared node (`node.nix`) and the Python socket clients the system tests run inside the VM; `vm/install/` the installer tests' helpers.

- `eval/`: eval-only tests (`hardening-eval`: dev assertions and SSH firewall rules; `mk-device`: mkDevice and state.json translation; `runtime-eval`: runtime/polkit/maintenance wiring; `daemon-eval`: daemon module, polkit policy, per-generation files; `state-check`: the daemon parses every state.json this repo ships or the installer writes; `apps`: app registry, streaming apps, input keys, OSK, layout, gamescope pin and patches, unfree allowlist; `profiles-eval`: accounts, guest, greeter and per-profile session wiring; `server-eval`: the M10 services, their firewall and units; `installer-iso-eval`: the ISO's own configuration; `offline-inputs`: every build-time input of an offline install is on the ISO), run by `nix flake check` and CI.
- `scripts/`: tests of the repo's scripts without a VM (`promote`: scripts/promote.sh, run in a local checkout, against a temporary bare repo with throwaway keys, flake-input clones next to it and a stubbed Forgejo status API; also runnable as `PROMOTE=<bin/promote> bash tests/scripts/promote.sh`).
- `couch/`: manual checklists for each milestone's exit criterion, run on real hardware
  with no keyboard attached.

The full testing workflow is in the project docs (TESTING.md, kept locally).
