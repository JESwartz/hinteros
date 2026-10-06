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

## Layout

| Path | Contents |
|---|---|
| `nixos/modules/` | HinterOS NixOS modules (session, apps, server, settings) |
| `nixos/hardware/` | Per-model hardware profiles layered on top of the `hardware.facter` report |
| `tests/vm/` | NixOS VM tests |
| `tests/couch/` | Manual couch-test checklists, one per milestone |

## License

GPL-3.0-only. See [LICENSE](LICENSE).
