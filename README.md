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
| `nixosModules.default` | All HinterOS modules plus the overlay; individual modules are `session`, `input`, `daemon`, `catalog`, `apps`, `firefox-kiosk`, `unfree`, `device-config`, `runtime`, `maintenance` and `overlay` |
| `overlays.default` | HinterOS packages: `hinteros-launcher`, `hinteros-session`, `hinteros-system` (from the component flakes) and the placeholder home app and `hinteros-firefox-kiosk` |
| `nixosConfigurations.vm` | Test VM that autologs in and starts the console session (cage in the VM, see `nixos/README.md`); `vm-gamescope` uses gamescope |
| `packages.x86_64-linux.vm`, `apps.x86_64-linux.vm` | `nix run .#vm` opens the VM in a window (software rendering) |
| `lib.mkDevice` | `mkDevice { state; configDir ? null; facterReport ? null; extraModules ? []; base ? "unstable" }` builds a device's `nixosSystem` from its state.json (design: `device-config.md` in the docs). `state` is checked by `nixos/modules/state.nix`: `schemaVersion` must be 1, unknown fields and unknown app ids fail evaluation (ids are the catalog's; tombstoned ids are accepted and do nothing). It maps `settings.ssh.enable` (opt-in; password login for the admin account only, see hardening.nix), `settings.admin.user` (enables `hinteros.admin`; its password hash lives in the root-only `/var/lib/hinteros/admin-password-hash`, never in the state), `settings.hostname`, `stateVersion`, `disk.layout` (the installer's layout, `nixos/modules/disk.nix`), `apps` and the first profile's user. With a state, exactly the listed catalog apps are enabled. Apps come from the `hinteros-catalog` flake input (`nixos/modules/catalog.nix`): every entry becomes a `hinteros.apps.<id>` (settings from the entry's `app`, icon fields written into session.toml for the daemon to resolve at runtime, its restricted `nixos` module while enabled, its unfree package names in `hinteros.unfreeAllowlist`). Without a state the `onIso` apps (jellyfin, youtube, crunchyroll, firefox) are on with the session. `nixos/lib/app-ids.nix` derives the installer's lists (onIso, online-only, preselected) from the catalog. The Store index and vendor terms are installed at `share/hinteros/catalog.json` and `share/hinteros/terms/` Only the `unstable` base exists for now |
| `nixosConfigurations.installer`, `packages.x86_64-linux.iso` | The installer ISO (`nix build .#iso`, see Installer below). `nixosModules.installer` is the same environment without the image bits, which the install VM tests run as a node |
| `nixosConfigurations.devbox` | Mini PC #1, from `devices/devbox/` (checked-in `state.json`, Intel iGPU, PipeWire, gamescope on DRM, Steam). Deploy: `nixos-rebuild switch --flake .#devbox --target-host deploy@<box> --sudo` (the `deploy` user from `hinteros.dev`; the session user has no sudo); see `tests/couch/m0-spikes.md`. Steam and Plex HTPC (`hinteros.apps.plex-htpc`) are unfree and allowed only by name (derived from the enabled catalog entries into `hinteros.unfreeAllowlist`). Unfree policy: the ISO is fully free (`forbidUnfree` with no `unfreeExceptions`, Steam included); the cache job sets `forbidUnfree` and `unfreeExceptions = config.hinteros.catalog.cacheableUnfree` (Steam, `cache = true` in the catalog); Plex is never cached |
| `checks.x86_64-linux` | `pre-commit` (nixfmt, statix, deadnix), `apps` (eval tests: app registry from the catalog, every catalog entry evaluating in a device, the ISO and the cache job config, icon fields, gamescope mode files, input keys, OSK settings, US layout, cage socket defaults, the gamescope version pin, unfree allowlist), `tv-apps` (VM test: Firefox kiosk profiles, YouTube TV User-Agent, daemon `apps.list` and `apps.launch`, Jellyfin starts), `typing` (VM test: the daemon's uinput keyboard types a URL and a password into Firefox over session API 0.7, and starts the OSK), `hardening` (VM test: unprivileged session user, admin sudo password, password SSH for the admin only, SSH off listens nowhere, dev deploy user), `hardening-eval` (eval tests for the dev assertions), `runtime-eval` (eval tests: scoped polkit rules, BlueZ/NetworkManager/systemd-boot hardening, snapshot wiring, boot counting, GC), `config-sync` (VM test: /etc/hinteros restored from the snapshot at boot, skipped without it), `runtime` (VM test: NetworkManager, BlueZ config, PipeWire socket, pkcheck allows/denies for the session user, boot-complete gate, low-disk warning), `installer-ui` (VM test: the installer environment boots into the launcher in `--installer` mode under cage as root, OCR sees the welcome screen, the catalog index and terms are in the profile, the console is the fallback), `runtime-settings` (VM test: session API 0.7 against the real NetworkManager, PipeWire (null sink), logind/polkit and BlueZ's bus policy: `network.status`, `bluetooth.status` unavailable cleanly, the session user reaches org.bluez and another user does not, `audio.outputs`, `power.capabilities`, `display.modes` under cage), `mk-device` (eval tests for mkDevice and the state translation), `daemon-eval` (eval and build test: the system service sandbox, the job unit template, polkit actions and rules, `release.json`, `channels.json` and `allowed_signers` contents, the signer format check, the device flake template's input line), VM tests of the privileged service, which run the real daemon, polkit, logind and systemd (`tests/vm/system/`): `system-escalation` (as the session user, hostile input straight at `system.sock`: unknown fields, forged `uid`/paths/URLs, wrong types, bad framing, non-UTF-8, oversize, nesting bombs, a connection flood; every request refused, same service process, `/etc/hinteros` untouched, no job started, rate limiting, audit entries, the sandbox it runs in), `system-authz` (read-only for members; non-members cannot connect; a member that does not own seat0 gets `permission_denied`/`seat`; the session user passes; `ssh.set` gives `authentication_required`; a rules file returning NO is honored; `pkcheck` per action; audit decisions) and `system-jobs` (`job_busy`, cancel before activation, failing build, job events, `base.set` with a real switch that restarts `hinteros-system` during its own job, `rollback` restoring the previous generation and the `/etc/hinteros` snapshot; **the build is a stub**: see the test header), `boot`, `install-offline` and the others below. `update-verify` (git server and cache VMs) is not implemented yet.
 `fake-steam` (the stub `steam` logs a `steam://rungameid` launch, a "Fake game" window shows, the fake Steam home with its 3 games and 3 tools is installed) and VM tests: `boot` (autologin, cage and the launcher up, OCR finds "HinterOS", both daemon sockets answer hello and ping), `gamescope` (headless gamescope in Steam mode plus the session daemon: base-layer property via xprop, over session API 0.7: `games.list` (tools filtered), fake game launch, Home, `apps.close`, Big Picture as app 769, a Steam Guard pop-up with `steam_attention` and `steam.focus`, all checked by OCR) and `input-layer` (InputPlumber with a fake pad: virtual target, intercept modes, DBus events) |
| `checks.x86_64-linux.install-validation`, `install-offline` | VM tests of the installer. `install-validation`: bad plans (no admin password, an app that needs a network while offline, a missing, mounted, system or too small disk, BIOS boot, malformed fields) are refused before the disk is touched. `install-offline`: a VM with no network and an empty second disk installs a plan (YouTube and Firefox, ssh on, an admin account), then the installed disk is booted via UEFI and checked: session up, `/etc/hinteros` and its snapshot, the pinned lock, sshd with the admin's password, no password for the session user or root, the daemon's `apps.list` |
| `devShells.default`, `formatter` | Dev shell with the lint tools and git hooks; `nix fmt` |

`nix flake check` runs everything above, including the VM test (needs `/dev/kvm`).

## Installer

The ISO boots (UEFI or BIOS, hybrid image for USB sticks) into the controller-driven installer
screens: the launcher in `--installer` mode, run by cage on tty1 as root (`hinteros.installer.ui.command`),
reading the catalog index from `/run/current-system/sw/share/hinteros/` and driving the same backend
as below. If the UI exits, tty1 is the root console with a notice.

### Build the ISO and write it to a USB stick

```
nix build .#iso
ls -lh result/iso/*.iso (about 3.8 GB)
# Check the device with lsblk first; this erases the stick.
sudo dd if=result/iso/hinteros-installer.iso of=/dev/sdX bs=4M conv=fsync status=progress
```

Verify the stick before booting it (a bad or fake-capacity stick shows up as read errors near
the end of the device and a stage 1 that waits for `/dev/disk/by-label/HINTEROS`):

```
sudo cmp -n $(stat -c%s result/iso/hinteros-installer.iso) result/iso/hinteros-installer.iso /dev/sdX && echo OK
```

**Ventoy: untested.** Ventoy keeps the ISO as a file and exposes it through `/dev/mapper/ventoy`; its NixOS support hooks a scripted stage 1, and this ISO uses a systemd stage 1 that looks for the file system label `HINTEROS`. It may fail with "timed out waiting for /dev/disk/by-label/HINTEROS". If it does, write the ISO with `dd` (or `cp`). A stage-1 fallback that scans `/dev/dm-*` for the volume ID is backlog (it needs a Ventoy stick to test).

The ISO boots quietly with the HinterOS name in the boot menu; the menu has a second entry,
"(debug: verbose boot)", with kernel, udev and stage 1 logs. Stage 1 waits up to five minutes for the
stick (`DefaultDeviceTimeoutSec`), and the initrd carries the USB host (xhci, ehci, ohci, uhci) and
storage (usb_storage, uas, sd_mod) drivers. Installed devices boot quietly too (`hinteros.boot.quiet`,
`nixos/modules/branding.nix`).

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
  "apps": ["youtube", "firefox"],
  "acceptedTerms": {}
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
| `apps` | Catalog ids, listed from the catalog: the `onIso` apps (`jellyfin`, `youtube`, `crunchyroll`, `firefox`; on the ISO, work offline) and the other `installer` ones (`steam`, `plex-htpc`, `moonlight`; downloaded, online only; nothing unfree is on the ISO). The installer UI pre-selects `youtube` and `firefox` |
| `acceptedTerms` | Optional `{"<id>": "<terms version>"}`. An app whose catalog entry has vendor terms (Steam, Plex) is refused (`terms-not-accepted`) unless the accepted version equals the version in the catalog index on this installer. The accepted ones are recorded on the box in `/var/lib/hinteros/terms-accepted.json` (root, 0600): `{"<id>": [{"version", "accepted_at", "by": "installer"}]}` |
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
