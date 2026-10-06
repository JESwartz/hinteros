# Tests

- `vm/`: NixOS VM tests (`boot`, `gamescope`, `input-layer`, `fake-steam`, `tv-apps`, `typing`, `config-sync`, `runtime`)
- `eval/`: eval-only tests (`hardening`: dev assertions; `mk-device`: mkDevice and state.json translation; `runtime-eval`: runtime/polkit/maintenance wiring; `apps`: app registry, input keys, OSK, layout, gamescope pin, unfree allowlist), run by `nix flake check` and CI.
- `couch/`: manual checklists for each milestone's exit criterion, run on real hardware
  with no keyboard attached.

The full testing workflow is in the project docs (TESTING.md, kept locally).
