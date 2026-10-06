Only the `unstable` base exists for now. `configDir` (flake.nix, flake.lock, state.json) is embedded in each generation at `$out/hinteros/`; `hinteros-config-sync` restores it into `/etc/hinteros` at boot (`hinteros.deviceConfig.*`) |# HinterOS

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
| `nixosModules.default` | All HinterOS modules plus the overlay; individual modules are `session`, `input`, `daemon`, `apps`, `firefox-kiosk`, `unfree`, `device-config`, `runtime`, `maintenance` and `overlay` |
| `overlays.default` | HinterOS packages: `hinteros-launcher`, `hinteros-session`, `hinteros-system` (from the component flakes) and the placeholder home app and `hinteros-firefox-kiosk` |
| `nixosConfigurations.vm` | Test VM that autologs in and starts the console session (cage in the VM, see `nixos/README.md`); `vm-gamescope` uses gamescope |
| `packages.x86_64-linux.vm`, `apps.x86_64-linux.vm` | `nix run .#vm` opens the VM in a window (software rendering) |
| `lib.mkDevice` | `mkDevice { state; configDir ? null; facterReport ? null; extraModules ? []; base ? "unstable" }` builds a device's `nixosSystem` from its state.json (design: `device-config.md` in the docs). `state` is checked by `nixos/modules/state.nix`: `schemaVersion` must be 1, unknown fields and unknown app ids fail evaluation. Today it maps `settings.ssh.enable` (opt-in; password login for the admin account only, see hardening.nix), `apps` (`steam`) and the first profile's user. Only the `unstable` base exists for now |
| `nixosConfigurations.devbox` | Mini PC #1, from `devices/devbox/` (checked-in `state.json`, Intel iGPU, PipeWire, gamescope on DRM, Steam). Deploy: `nixos-rebuild switch --flake .#devbox --target-host deploy@<box> --sudo` (the `deploy` user from `hinteros.dev`; the session user has no sudo); see `tests/couch/m0-spikes.md`. Steam and Plex HTPC (`hinteros.apps.plex`) are unfree and allowed only by name (`hinteros.unfreeAllowlist`); never put a Steam or Plex closure in a binary cache or ISO |
| `checks.x86_64-linux` | `pre-commit` (nixfmt, statix, deadnix), `apps` (eval tests: app registry and input keys, OSK settings, US layout, cage socket defaults, the gamescope version pin, unfree allowlist), `tv-apps` (VM test: Firefox kiosk profiles, YouTube TV User-Agent, daemon `apps.list` and `apps.launch`, Jellyfin starts), `typing` (VM test: the daemon's uinput keyboard types a URL and a password into Firefox over session API 0.4, and starts the OSK), `hardening` (VM test: unprivileged session user, admin sudo password, password SSH for the admin only, SSH off listens nowhere, dev deploy user), `hardening-eval` (eval tests for the dev assertions), `runtime-eval` (eval tests: scoped polkit rules, BlueZ/NetworkManager/systemd-boot hardening, snapshot wiring, boot counting, GC), `config-sync` (VM test: /etc/hinteros restored from the snapshot at boot, skipped without it), `runtime` (VM test: NetworkManager, BlueZ config, PipeWire socket, pkcheck allows/denies for the session user, boot-complete gate, low-disk warning), `mk-device` (eval tests for mkDevice and the state translation), `fake-steam` (the stub `steam` logs a `steam://rungameid` launch, a "Fake game" window shows, the fake Steam home with its 3 games and 3 tools is installed) and VM tests: `boot` (autologin, cage and the launcher up, OCR finds "HinterOS", both daemon sockets answer hello and ping), `gamescope` (headless gamescope in Steam mode plus the session daemon: base-layer property via xprop, over session API 0.4: `games.list` (tools filtered), fake game launch, Home, `apps.close`, Big Picture as app 769, a Steam Guard pop-up with `steam_attention` and `steam.focus`, all checked by OCR) and `input-layer` (InputPlumber with a fake pad: virtual target, intercept modes, DBus events) |
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
| `nixos/modules/` | HinterOS NixOS modules (session, input, daemon, apps, firefox-kiosk, unfree, state, fake-steam, device-config, runtime, maintenance) |
| `nixos/lib/` | `mkDevice` |
| `devices/` | Checked-in devices (`devbox`) |
| `nixos/overlay.nix`, `nixos/pkgs/` | The overlay and the packages it adds |
| `nixos/vm/` | Test VM configuration (shared by `nix run .#vm` and the VM tests) |
| `scripts/` | Dev scripts (`dev-override`) |
| `nixos/hardware/` | Per-model hardware profiles layered on top of the `hardware.facter` report |
| `tests/vm/` | NixOS VM tests |
| `tests/couch/` | Manual couch-test checklists, one per milestone |

## License

GPL-3.0-only. See [LICENSE](LICENSE).
