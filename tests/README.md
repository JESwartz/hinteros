# Tests

- `vm/`: NixOS VM tests (`boot`, `gamescope`, `input-layer`, `fake-steam`, `tv-apps`, `typing`, `config-sync`, `runtime`, `hardening`, `system-escalation`, `system-authz`, `system-jobs`, `install-offline`, `install-validation`); `vm/system/` holds the shared node (`node.nix`) and the Python socket clients the system tests run inside the VM
- `eval/`: eval-only tests (`hardening`: dev assertions; `mk-device`: mkDevice and state.json translation; `runtime-eval`: runtime/polkit/maintenance wiring; `daemon-eval`: daemon module, polkit policy, per-generation files; `apps`: app registry, input keys, OSK, layout, gamescope pin, unfree allowlist), run by `nix flake check` and CI.
- `couch/`: manual checklists for each milestone's exit criterion, run on real hardware
  with no keyboard attached.

The full testing workflow is in the project docs (TESTING.md, kept locally).
