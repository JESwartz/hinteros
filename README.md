# HinterOS

A NixOS-based distro that turns a PC into a controller-driven gaming console and smart TV.
HinterOS is a layer of NixOS modules on top of nixpkgs, not a fork.

This is the system repository: the flake that assembles HinterOS, its NixOS modules,
hardware profiles and system tests.

## Repositories

| Repo | Contents |
|---|---|
| [`hinteros`](https://justsomeshed.com/JSwartz/HinterOS/hinteros) (this one) | System flake, NixOS modules, hardware profiles, VM tests |
| `hinteros-docs` | Project-wide docs: roadmap, testing workflow, decisions (kept locally, not published) |
| [`hinteros-launcher`](https://justsomeshed.com/JSwartz/HinterOS/hinteros-launcher) | Flutter launcher (the TV/console UI) |
| [`hinteros-daemon`](https://justsomeshed.com/JSwartz/HinterOS/hinteros-daemon) | Rust system daemon (controller input, Home button, app launching, settings, rebuilds) |

The system flake takes the launcher and daemon as flake inputs. Its `flake.lock` pins the
exact component revisions, so each branch of this repo (`main`, `beta`, `stable`) describes
one consistent system.

## Flake outputs

| Output | Contents |
|---|---|
| `nixosModules.default` | All HinterOS modules plus the overlay; individual modules are `session` and `overlay` |
| `overlays.default` | HinterOS packages (currently the placeholder home app) |
| `nixosConfigurations.vm` | Test VM that autologs in and starts the console session (cage in the VM, see `nixos/README.md`); `vm-gamescope` uses gamescope |
| `packages.x86_64-linux.vm`, `apps.x86_64-linux.vm` | `nix run .#vm` opens the VM in a window (software rendering) |
| `checks.x86_64-linux` | `pre-commit` (nixfmt, statix, deadnix) and the `boot` VM test (autologin, compositor and home app up, screenshot and OCR logged) |
| `devShells.default`, `formatter` | Dev shell with the lint tools and git hooks; `nix fmt` |

`nix flake check` runs everything above, including the VM test (needs `/dev/kvm`).

## Working against local component checkouts

`scripts/dev-override <nix subcommand> ...` runs a nix command with every component input
(`hinteros-launcher`, `hinteros-daemon`) overridden by the sibling checkout `../<name>`, using
`git+file:` so untracked build output is not copied. Inputs missing from `flake.nix` or without
a sibling directory are skipped.

```
scripts/dev-override flake check
scripts/dev-override build .#vm
```

## Layout

| Path | Contents |
|---|---|
| `nixos/modules/` | HinterOS NixOS modules (session, apps, server, settings) |
| `nixos/overlay.nix`, `nixos/pkgs/` | The overlay and the packages it adds |
| `nixos/vm/` | Test VM configuration (shared by `nix run .#vm` and the VM tests) |
| `scripts/` | Dev scripts (`dev-override`) |
| `nixos/hardware/` | Per-model hardware profiles layered on top of the `hardware.facter` report |
| `tests/vm/` | NixOS VM tests |
| `tests/couch/` | Manual couch-test checklists, one per milestone |

## License

GPL-3.0-only. See [LICENSE](LICENSE).
