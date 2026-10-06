# Tests

- `vm/`: NixOS VM tests (`boot`, `gamescope`, `input-layer`, `fake-steam`)
- `eval/`: eval-only tests (`mk-device`: mkDevice and state.json translation, good and bad input), run by `nix flake check` and CI.
- `couch/`: manual checklists for each milestone's exit criterion, run on real hardware
  with no keyboard attached.

The full testing workflow is in the project docs (TESTING.md, kept locally).
