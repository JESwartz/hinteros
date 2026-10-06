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
| `lib.mkDevice` | `mkDevice { state; configDir ? null; facterReport ? null; extraModules ? []; base ? "unstable" }` builds a device's `nixosSystem` from its state.json (design: `device-config.md` in the docs). `state` is checked by `nixos/modules/state.nix`: `schemaVersion` must be 1, unknown fields and unknown app ids fail evaluation. It maps `settings.ssh.enable` (opt-in; password login for the admin account only, see hardening.nix), `settings.admin.user` (enables `hinteros.admin`; its password hash lives in the root-only `/var/lib/hinteros/admin-password-hash`, never in the state), `settings.hostname`, `stateVersion`, `disk.layout` (the installer's layout, `nixos/modules/disk.nix`), `apps` and the first profile's user. With a state, the default apps (jellyfin, youtube, crunchyroll, firefox) are enabled exactly when listed; `steam`, `plex-htpc` and `moonlight` are the other ids (`nixos/lib/app-ids.nix`). Only the `unstable` base exists for now |
| `nixosConfigurations.installer`, `packages.x86_64-linux.iso` | The installer ISO (`nix build .#iso`, see Installer below). `nixosModules.installer` is the same environment without the image bits, which the install VM tests run as a node |
| `nixosConfigurations.devbox` | Mini PC #1, from `devices/devbox/` (checked-in `state.json`, Intel iGPU, PipeWire, gamescope on DRM, Steam). Deploy: `nixos-rebuild switch --flake .#devbox --target-host deploy@<box> --sudo` (the `deploy` user from `hinteros.dev`; the session user has no sudo); see `tests/couch/m0-spikes.md`. Steam and Plex HTPC (`hinteros.apps.plex`) are unfree and allowed only by name (`hinteros.unfreeAllowlist`); never put a Steam or Plex closure in a binary cache or ISO |
| `checks.x86_64-linux` | `pre-commit` (nixfmt, statix, deadnix), `apps` (eval tests: app registry and input keys, OSK settings, US layout, cage socket defaults, the gamescope version pin, unfree allowlist), `tv-apps` (VM test: Firefox kiosk profiles, YouTube TV User-Agent, daemon `apps.list` and `apps.launch`, Jellyfin starts), `typing` (VM test: the daemon's uinput keyboard types a URL and a password into Firefox over session API 0.4, and starts the OSK), `hardening` (VM test: unprivileged session user, admin sudo password, password SSH for the admin only, SSH off listens nowhere, dev deploy user), `hardening-eval` (eval tests for the dev assertions), `runtime-eval` (eval tests: scoped polkit rules, BlueZ/NetworkManager/systemd-boot hardening, snapshot wiring, boot counting, GC), `config-sync` (VM test: /etc/hinteros restored from the snapshot at boot, skipped without it), `runtime` (VM test: NetworkManager, BlueZ config, PipeWire socket, pkcheck allows/denies for the session user, boot-complete gate, low-disk warning), `mk-device` (eval tests for mkDevice and the state translation), `fake-steam` (the stub `steam` logs a `steam://rungameid` launch, a "Fake game" window shows, the fake Steam home with its 3 games and 3 tools is installed) and VM tests: `boot` (autologin, cage and the launcher up, OCR finds "HinterOS", both daemon sockets answer hello and ping), `gamescope` (headless gamescope in Steam mode plus the session daemon: base-layer property via xprop, over session API 0.4: `games.list` (tools filtered), fake game launch, Home, `apps.close`, Big Picture as app 769, a Steam Guard pop-up with `steam_attention` and `steam.focus`, all checked by OCR) and `input-layer` (InputPlumber with a fake pad: virtual target, intercept modes, DBus events) |
| `checks.x86_64-linux.install-validation`, `install-offline` | VM tests of the installer. `install-validation`: bad plans (no admin password, an app that needs a network while offline, a missing, mounted, system or too small disk, BIOS boot, malformed fields) are refused before the disk is touched. `install-offline`: a VM with no network and an empty second disk installs a plan (YouTube and Firefox, ssh on, an admin account), then the installed disk is booted via UEFI and checked: session up, `/etc/hinteros` and its snapshot, the pinned lock, sshd with the admin's password, no password for the session user or root, the daemon's `apps.list` |
| `devShells.default`, `formatter` | Dev shell with the lint tools and git hooks; `nix fmt` |

`nix flake check` runs everything above, including the VM test (needs `/dev/kvm`).

## Installer

The ISO boots (UEFI or BIOS, hybrid image for USB sticks) into a root console that shows a notice
and starts nothing else. The controller-driven installer screens come from the launcher repo and
will drive the same backend; `hinteros.installer.ui.command` is the hook that starts them.

### Build the ISO and write it to a USB stick

```
nix build .#iso
ls -lh result/iso/*.iso
# Check the device with lsblk first; this erases the stick.
sudo dd if=result/iso/hinteros-installer-*.iso of=/dev/sdX bs=4M conv=fsync status=progress
```

`cp` onto the raw device works as well as `dd`. Build from a clean, committed checkout: the ISO
pins the generated device flake to this repository's revision, and a dirty tree has none (it gets
a placeholder revision and is only good for tests). Booting the stick needs UEFI mode with Secure
Boot off (neither the ISO nor systemd-boot is signed).

### Install from the console (the first hardware test)

Boot the stick, optionally connect to Wi-Fi (`nmtui`) for an online install, write a plan and run
the backend as root. The disk named in the plan is erased.

```
sudo hinteros-install --plan plan.json
```

An example is in `/etc/hinteros-installer/plan.example.json` on the ISO:

```json
{
  "disk": "/dev/nvme0n1",
  "hostname": "hinteros",
  "admin": { "user": "james", "password": "change-me-now" },
  "ssh": { "enable": false },
  "channel": "stable",
  "base": "unstable",
  "apps": ["youtube", "firefox"]
}
```

| Field | Meaning |
|---|---|
| `disk` | Whole-disk device path (`/dev/nvme0n1`, `/dev/disk/by-id/...`). Refused if it does not exist, is mounted (this includes the installer stick) or is under 16 GiB |
| `hostname` | Lowercase letters, digits and hyphens |
| `admin` | `user` plus `password` (plain text, hashed by the installer) or `hashedPassword` (`mkpasswd` output). Required: it is the only SSH login and the sudo account. The session user (`hinteros`) and root get no password |
| `ssh.enable` | sshd from the first boot, password login for the admin only. Default false |
| `channel` | `stable` or `beta`: the `ref` in the generated flake's input URL. Default `stable` |
| `base` | nixpkgs base; only `unstable` exists. Default `unstable` |
| `apps` | Catalog ids: `jellyfin`, `youtube`, `crunchyroll`, `firefox` (on the ISO, work offline) and `steam`, `plex-htpc`, `moonlight` (downloaded, online only). The installer UI pre-selects `youtube` and `firefox` |
| `wifi` | Optional `{ssid, psk}`: connects before the install and keeps the connection on the installed box |
| `network` | Optional: `auto` (default; online if cache.nixos.org answers), `online` (fail if not) or `offline` |

The plan may hold a plain-text password: keep it on tmpfs and delete it afterwards (`--plan -`
reads it from stdin). `--validate-only` checks the plan and the machine and touches nothing.

**Progress.** stdout is one JSON object per line, for example
`{"stage":"install","percent":57,"level":"info","message":"..."}`. Stages in order: `validate`
(0-8), `partition` (10-20), `facter` (22-26), `config` (28-30), `install` (32-90, from nix's own
progress), `snapshot` (92-95), `finalize` (97), `done` (100). `level` is `info`, `warn` or `error`.
An `error` line also has a `code` (`admin-password-missing`, `app-needs-network`, `disk-not-found`,
`disk-in-use`, `disk-too-small`, `not-uefi`, `install-failed`, ...) and the exit status is 2 (the
plan or the machine was refused, nothing was touched) or 1 (failed part-way). Tool output goes to
stderr and `/var/log/hinteros-install.log`.

**What it does.** Validate the plan and the machine; partition with disko (GPT, a 1 GiB ESP and an
ext4 root, found by partition label `hinteros-esp` / `hinteros-root`, no encryption; ext4 because
nothing here needs snapshots, it is the best-tested NixOS root and copes with power cuts at the
TV); `nixos-facter` writes `facter.json` (a failure only warns: the box then boots with generic
drivers); write `/etc/hinteros` (`flake.nix` from `nixos/templates/device-flake.nix.in`,
`flake.lock`, `state.json`); write the admin password hash to
`/var/lib/hinteros/admin-password-hash` (0600, referenced by the config, never in `state.json` or
the store); `nixos-install --no-root-passwd`; check that `/etc/hinteros` equals the generation's
snapshot; unmount.

### Offline installs

The ISO carries the closure of a default system (the base plus the four `onIso` apps in
`nixos/lib/app-ids.nix`), the sources of this repository and of every flake input it locks, and a
`flake.lock` for the generated device flake whose `hinteros` input points at the revision the ISO
was built from, with the same `narHash` (`nixos/lib/device-lock.nix` embeds this repository's own
lock, so every transitive input is pinned too). Nix resolves a locked input whose narHash is already
in the store without fetching, so `nixos-install --flake path:/mnt/etc/hinteros#hinteros` evaluates
and substitutes from the ISO's store. Online installs use the same lock, so the installed system is
the ISO's revision and nixpkgs (only extra apps are downloaded); the first `nix flake update
hinteros` on the box moves it to the channel. Steam, Plex and Moonlight are not on the ISO: they are
refused offline (`app-needs-network`) and downloaded during an online install. Nothing unfree is
ever on the ISO (`hinteros.forbidUnfree`).

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
| `nixos/modules/` | HinterOS NixOS modules (session, input, daemon, apps, firefox-kiosk, unfree, state, fake-steam, device-config, runtime, maintenance, hardening, disk) |
| `nixos/lib/` | `mkDevice`, `device-lock.nix` (the offline flake.lock), `app-ids.nix` (app ids and which are on the ISO) |
| `nixos/installer/`, `nixos/templates/` | The installer environment and ISO config; the `/etc/hinteros/flake.nix` template |
| `devices/` | Checked-in devices (`devbox`) |
| `nixos/overlay.nix`, `nixos/pkgs/` | The overlay and the packages it adds |
| `nixos/vm/` | Test VM configuration (shared by `nix run .#vm` and the VM tests) |
| `scripts/` | Dev scripts (`dev-override`) |
| `nixos/hardware/` | Per-model hardware profiles layered on top of the `hardware.facter` report |
| `tests/vm/` | NixOS VM tests |
| `tests/couch/` | Manual couch-test checklists, one per milestone |

## License

GPL-3.0-only. See [LICENSE](LICENSE).
