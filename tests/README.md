# Tests

- `vm/`: NixOS VM tests (`boot`, `gamescope`, `input-layer`, `fake-steam`, `tv-apps`, `typing`, `config-sync`, `runtime`, `hardening`, `system-escalation`, `system-authz`, `system-jobs`, `install-offline`, `install-offline-hw`, `install-validation`, `polkit-agent`, `session-restart`, `store-install`); `vm/system/` holds the shared node (`node.nix`) and the Python socket clients the system tests run inside the VM
- `eval/`: eval-only tests (`hardening`: dev assertions; `mk-device`: mkDevice and state.json translation; `runtime-eval`: runtime/polkit/maintenance wiring; `daemon-eval`: daemon module, polkit policy, per-generation files; `state-check`: the daemon parses every state.json this repo ships or the installer writes; `apps`: app registry, streaming apps, input keys, OSK, layout, gamescope pin, unfree allowlist), run by `nix flake check` and CI.
- `scripts/`: tests of the repo's scripts without a VM (`promote`: scripts/promote.sh, run in a local checkout, against a temporary bare repo with throwaway keys, flake-input clones next to it and a stubbed Forgejo status API; also runnable as `PROMOTE=<bin/promote> bash tests/scripts/promote.sh`).
- `couch/`: manual checklists for each milestone's exit criterion, run on real hardware
  with no keyboard attached.

The full testing workflow is in the project docs (TESTING.md, kept locally).
