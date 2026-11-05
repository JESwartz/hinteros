# HinterOS

[HinterOS](https://hinteros.org) is a NixOS-based distro that turns a PC into a controller-driven
gaming console and smart TV. It is a layer of NixOS modules on top of nixpkgs, not a fork.

Website: https://hinteros.org

This is the system repository: the flake that assembles HinterOS, its NixOS modules,
hardware profiles and system tests.

## Repositories

| Repo | Contents |
|---|---|
| [`hinteros`](https://justsomeshed.com/JSwartz/HinterOS/hinteros) (this one) | System flake, NixOS modules, hardware profiles, VM tests |
| `hinteros-docs` | Project-wide docs: roadmap, testing workflow, decisions (kept locally, not published) |
| [`hinteros-launcher`](https://justsomeshed.com/JSwartz/HinterOS/hinteros-launcher) | Flutter launcher (the TV/console UI) |
| [`hinteros-daemon`](https://justsomeshed.com/JSwartz/HinterOS/hinteros-daemon) | Rust system daemon (controller input, Home button, app launching, settings, rebuilds) |
| [`hinteros-catalog`](https://justsomeshed.com/JSwartz/HinterOS/hinteros-catalog) | The App Store catalog (apps and services) |

Development (pushes, the web UI) is on Forgejo at justsomeshed.com. Boxes, installers and the
flake inputs fetch the repos read-only from `https://git.hinteros.org/<repo>.git`.

The system flake takes the launcher, daemon and catalog as flake inputs. Its `flake.lock` pins the
exact component revisions, so each branch of this repo (`main`, `beta`, `stable`) describes
one consistent system.

## Flake outputs

| Output | Contents |
|---|---|
| `nixosModules.default` | All HinterOS modules plus the overlay; individual modules are `session`, `input`, `daemon`, `catalog`, `apps`, `firefox-kiosk`, `unfree`, `device-config`, `runtime`, `maintenance`, `hardening`, `state`, `cache`, `generic-hardware`, `fake-steam`, `installer` (the installer environment, see Installer) and `overlay` (flake.nix lists them) |
| `overlays.default` | HinterOS packages: `hinteros-launcher` and `hinteros-osk` (launcher flake), `hinteros-session`, `hinteros-system` and `hinteros-osk-firefox-extension` (daemon flake), and from this repo the placeholder home app, `hinteros-fake-steam`, `hinteros-firefox-kiosk` and the patched `gamescope` and `inputplumber` |
| `nixosConfigurations.vm` | Test VM that autologs in and starts the console session (cage in the VM, see `nixos/README.md`); `vm-gamescope` uses gamescope |
| `packages.x86_64-linux.vm`, `apps.x86_64-linux.vm` | `nix run .#vm` opens the VM in a window (software rendering) |
| `packages.x86_64-linux.promote`, `apps.x86_64-linux.promote` | `nix run .#promote`: the release tool (see "Releases and channels"); `checks.promote` tests it against a temporary repo with throwaway keys |
| `lib.catalogIds` | `{ <id> = { name; kind; status; statusReason; }; }` for every catalog entry, tombstones included (the catalog flake's own `lib.catalogIds`): what `hinteros-system` evaluates (`nix eval --json ...#lib.catalogIds`, no import-from-derivation) against a target revision to tell which apps an update adds or retires. A 1.0 daemon reads it from every later revision, so after 1.0 fields are only added; an unknown `kind` counts as not an app |
| `lib.installerCatalog` | `{ version = 1; entries = [ { id; offered; boxFeatures; terms = { version; title; } or null; } ]; }`: what an installer reads from a newer revision it installs (a plan's `rev`): which entries it offers, their box features and vendor terms. A compatibility interface (an ISO installs newer revisions for years): fields may be added and installers ignore them; `version` changes only when an older installer would misread the entries, and such an installer refuses that revision (`fetch-failed`). Checked by `installer-iso-eval` |
| `lib.deviceOutputs` | `deviceOutputs <config dir>` is what a device flake outputs (`nixos/lib/device-outputs.nix`): `nixosConfigurations.hinteros` from the dir's `state.json`, `facter.json` (not while `facter.deferred` exists) and an optional `extra.nix`, so `/etc/hinteros/flake.nix` never needs rewriting on an installed box |
| `lib.mkDevice` | `mkDevice { state; configDir ? null; facterReport ? null; selfFlake ? null; extraModules ? []; base ? state.base or "unstable" }` builds a device's `nixosSystem` from its state.json (design: `device-config.md` in the docs). `state` is checked by `nixos/modules/state.nix`: `schemaVersion` must be 2, and `base`, `stateVersion`, `profiles`, `requirements` and `services` are required; bad values of known fields fail evaluation, unknown fields are ignored (a box on an older channel evaluates the newer state; a change that is not safe to ignore bumps `schemaVersion`). It maps `settings.ssh.enable` (opt-in; password login for the admin account only, see hardening.nix), `settings.admin.user` (enables `hinteros.admin`; its password hash lives in the root-only `/var/lib/hinteros/admin-password-hash`, never in the state), `settings.hostname`, `settings.cleanup` (the automatic clean-up, storage.md: `{ "enable": true, "frequency": "weekly", "keepSystem": 5, "keepProfiles": 5 }`; `frequency` is `daily`, `weekly` or `monthly`, the keep counts 1 to 10; an absent object or field is these defaults; other values fail evaluation. It becomes `hinteros.maintenance.{gc.enable,gc.dates,keepGenerations,keepProfileGenerations}`, see `nixos/README.md`), `settings.timeZone` (time-zone.md: a zone name of tzdata such as `"America/Chicago"`, absent = `UTC`; other values fail evaluation. It is not baked into the generation: `nixos/modules/time-zone.nix` points `/etc/localtime` at it from the live state.json at activation, and hinteros-system changes both at once), `stateVersion`, `disk` (`{ "layout": "gpt-esp-btrfs", "rootUuid": ..., "espUuid": ... }`, the installer's layout, `nixos/modules/disk.nix`), `profiles` (`[{ "id": "p1" }]`; `p<N>` is the Unix user `hinteros-p<N>`, uid 20000+N), `requirements` (box features) and `services`. With a state no box-wide app is on: apps are per profile (`nixos/modules/app-env.nix`). Apps come from the `hinteros-catalog` flake input (`nixos/modules/catalog.nix`): every entry becomes a `hinteros.apps.<id>` (settings from the entry's `app`, icon fields written into session.toml for the daemon to resolve at runtime, its restricted `nixos` module while enabled, its unfree package names in `hinteros.unfreeAllowlist`). Without a state (test VMs) the installer's `onIso` apps (jellyfin-desktop, youtube, firefox: on the ISO and offered by the installer; the Store-only streaming apps are on the ISO too but stay off) are on with the session. `nixos/lib/app-ids.nix` derives the installer's lists (onIso, online-only, preselected) from the catalog. The Store index and vendor terms are installed at `share/hinteros/catalog.json` and `share/hinteros/terms/`. Only the `unstable` base exists for now. `configDir` (flake.nix, flake.lock, state.json) is embedded in each generation at `$out/hinteros/`; `hinteros-config-sync` restores it into `/etc/hinteros` at boot (`hinteros.deviceConfig.*`) |
| `nixosConfigurations.installer`, `packages.x86_64-linux.iso` | The installer ISO (`nix build .#iso`, see Installer below). `nixosModules.installer` is the same environment without the image bits, which the install VM tests run as a node |
| `nixosConfigurations.devbox` | The M0/M1 config of mini PC #1 from before the installer, from `devices/devbox/` (checked-in `state.json` without `disk`, placeholder ext4 mounts by label, Intel iGPU, PipeWire, gamescope on DRM, Steam), for the M0 spike checklist (`tests/couch/m0-spikes.md`) on a NixOS installed by hand. **Never deploy it to a box the installer made** (btrfs subvolumes mounted by UUID, `state.json` with `disk`): that generation does not boot there. Such a box, the dev box included, updates from its channel (`promote`, Settings -> Updates). Steam and Plex HTPC (`hinteros.apps.plex-htpc`) are unfree and allowed only by name (derived from the enabled catalog entries into `hinteros.unfreeAllowlist`). Unfree policy: the ISO is fully free (`forbidUnfree` with no `unfreeExceptions`, Steam included); the cache job sets `forbidUnfree` and `unfreeExceptions = config.hinteros.catalog.cacheableUnfree` (Steam, `delivery = "download"` in the catalog); Plex is never cached |
| `checks.x86_64-linux` | `pre-commit` (nixfmt, statix, deadnix), `state-check` (builds: `hinteros-system check-state`, the daemon's own parser, over `devices/*/state.json`, the VM fixtures and the `state.json` files `hinteros-install --state-dir` writes for representative plans, plus the same after Store-only apps are added; a plan with an admin password shorter than 8 characters is refused), `apps` (eval tests: app registry from the catalog, every catalog entry evaluating in a device, the ISO and the cache job config, icon fields, gamescope mode files, input keys, OSK settings, US layout, cage socket defaults, the gamescope version pin, unfree allowlist, the Store-only streaming apps: kept out of the installer lists, listed as kiosk entries when installed), `sandbox` (VM test: an app started by `apps.launch` runs in the bwrap sandbox and reaches none of the HinterOS sockets, the D-Bus buses, uinput, the Wayland socket or the real home; X and sound playback work, recording only with `mic` (the others get the play-only pulse socket, which also refuses module loading); `~/Downloads` only with `downloads`, `/dev/input` only with `gamepad`; an `apps.set_permission` opt-out applies on the next launch), `sandbox-lan` (VM test, three nodes: a router with DNS on the home network, an "internet" host on a documentation address behind it, the box with a server on loopback: a sandboxed app without `lan` gets no TCP to the router (IPv4, on-link IPv6, link-local) or to loopback, no UDP to it, to multicast or broadcast, while DNS over the router (UDP and TCP) and the internet work; with `lan` everything works; a denial applies at the next start; the filter follows a session daemon restart (new cgroup) and `/etc/resolv.conf`, fails closed without hinteros-system and is cleared when the session daemon stops), `steam-sockets` (VM test: Steam's FHS bwrap, run as `.run-free`, has a tmpfs over `/run/hinteros` and `$XDG_RUNTIME_DIR/hinteros`, so no `system.sock`, `session.sock` or `osk.sock`; the app envs stay read-only; stock steam-run sees the sockets), `tv-apps` (VM test: Firefox kiosk profiles in the app sandbox, YouTube TV User-Agent, daemon `apps.list` and `apps.launch`, a Store-only streaming app (Netflix) launches in its own profile, Jellyfin starts), `typing` (VM test: the daemon's uinput keyboard types a URL and a password into Firefox over session API 0.8, and starts the OSK), `hardening` (VM test: unprivileged session user, admin sudo password, password SSH for the admin only and only from the local networks (a global IPv6 source is refused, the firewall rules are listed), SSH off listens nowhere, dev deploy user; profiles: no keyboard access, a profile not in front frozen), `hardening-eval` (eval tests for the dev assertions and the SSH firewall rules), `runtime-eval` (eval tests: scoped polkit rules, BlueZ/NetworkManager/systemd-boot hardening, snapshot wiring, boot counting, GC, `settings.cleanup`: defaults, frequencies, keep counts, refused values; `settings.timeZone`: the activation wiring, valid, absent and refused zones), `config-sync` (VM test: /etc/hinteros restored from the snapshot at boot, skipped without it), `runtime` (VM test: NetworkManager, BlueZ config, PipeWire socket, pkcheck allows/denies for the session user, boot-complete gate, low-disk warning), `installer-ui` (VM test: the installer environment boots into the launcher in `--installer` mode under cage as root, OCR sees the welcome screen, the catalog index and terms are in the profile, the console is the fallback), `runtime-settings` (VM test: session API 0.7 against the real NetworkManager, PipeWire (null sink), logind/polkit and BlueZ's bus policy: `network.status`, `bluetooth.status` unavailable cleanly, the session user reaches org.bluez and another user does not, `audio.outputs`, `power.capabilities`, `display.modes` under cage), `mk-device` (eval tests for mkDevice and the state translation), `daemon-eval` (eval and build test: the patched InputPlumber, the daemon's pointer theme environment, the system service sandbox, the time zone helper unit (`hinteros-time-zone-apply`: /etc/hinteros and /run/hinteros only, no network or capabilities; systemd-timedated present), the job unit template, polkit actions and rules, `release.json`, `channels.json` and `allowed_signers` contents, the signer format check, the device flake template's input line), VM tests of the privileged service, which run the real daemon, polkit, logind and systemd (`tests/vm/system/`): `system-escalation` (as the session user, hostile input straight at `system.sock`: unknown fields, forged `uid`/paths/URLs, wrong types, bad framing, non-UTF-8, oversize, nesting bombs, a connection flood; every request refused, same service process, `/etc/hinteros` untouched, no job started, rate limiting, audit entries, the sandbox it runs in), `system-authz` (read-only for members; non-members cannot connect; a member that does not own seat0 gets `permission_denied`/`seat`; the session user passes; `ssh.set` gives `authentication_required`; a rules file returning NO is honored; `pkcheck` per action; audit decisions) and `polkit-agent` (VM test, real polkitd and PAM: the launcher path over the session socket, `system.ssh.set` -> `authentication_requested`, wrong passwords, a client not named `hinteros-launcher` refused, cancel, the right admin password -> job -> sshd on; **the build is a stub**), `session-restart` (VM test: `session.restart` replaces the greetd session, launcher and session daemon, twice; greetd has `Restart=always`), `store-install` (VM test: `store.list`, `system.apps.install`/`remove` through the session socket, terms refusal and `terms-accepted.json`, `delete_data` that never follows symlinks out of the home, hostile `apps.*` input; **the build is a stub**), `install-offline-m900` (the install-offline VM test with the real report of a Lenovo M900), `install-offline-hw` (VM test: an offline install with an Intel mini PC hardware report builds no package, the report is deferred), and `time-zone` (VM test: `/etc/localtime` from the live state.json at boot, `time_zone.get`/`list`/`set` (system API 0.8, relayed in session API 0.16) with and without the admin PIN, unknown zones refused, the change at once through systemd-timedated (one link, timedated names the zone; a timedated that missed a change is restarted) and after a reboot (config-sync keeps the live zone), the helper unable to make any other entry of /etc, activation falling back to UTC and idempotent), and `system-jobs` (`job_busy`, cancel before activation, failing build, job events, `base.set` with a real switch that restarts `hinteros-system` during its own job, `rollback` restoring the previous generation and the `/etc/hinteros` snapshot; **the build is a stub**: see the test header), `boot`, `install-offline` and the others below. `system-update` (signed updates end to end in the job unit: `update.check`, `update.apply`, `channel.check` and `channel.set` to an older channel from a local signed channel repo; unsigned, untrusted-key, bad-signature and not-fast-forward tips refused, also by the apply job itself; the flake.lock rewrite and a real switch; **the build is a stub**). `update-verify` (an https git server and cache VMs) is not implemented yet. `fake-steam` (the stub `steam` logs a `steam://rungameid` launch, a "Fake game" window shows, the fake Steam home with its 3 games and 3 tools is installed) and VM tests: `boot` (autologin, cage and the launcher up, OCR finds "HinterOS", both daemon sockets answer hello and ping), `gamescope` (headless gamescope in Steam mode plus the session daemon: base-layer property via xprop, over session API 0.8: `games.list` (tools filtered), fake game launch, Home, `apps.close`, Big Picture as app 769, a Steam Guard pop-up with `steam_attention` and `steam.focus`, all checked by OCR), `gamescope-size` (headless gamescope at 1920x1080 and at 1280x1024 with a smaller nested size: the home app and a daemon-launched X11 app that never ask for fullscreen fill the output edge to edge in a screenshot, their windows, the Xwayland `:0` root and the first `wl_output` equal the output size, `GDK_BACKEND=x11`, gamescope output in the journal; see `nixos/README.md` "Display size") and `input-layer` (InputPlumber with a fake pad: virtual target, intercept modes, DBus events, a profile loaded at runtime and `SendEvent` clicks that answer and reach the virtual mouse: the overlay's InputPlumber patch) |
| `scripts/test-plan.sh` `quick`, `targeted [BASE]` or `full`, optional `--run` | Which checks to run: `quick` = the eval checks (minutes); `targeted` = those plus only the VM tests for what changed since BASE (default `origin/main`; changed files and the daemon, launcher and catalog revisions in `flake.lock`); `full` = every check, once per release before promoting a beta. `--run` builds them one at a time, throttled (a memory-capped user scope where `systemd-run --user` works, else `nice`), and prints the end of a failing log. VM tests never run two at once. The targeted map covers the installer's inputs (templates, device lock, offline inputs, app lists, release keys), the sandbox, server, VM and hardware modules; a change to `flake.nix` or nixpkgs asks for the full tier. CI (`.forgejo/workflows/check.yml`) runs `targeted` on branch pushes and `full` on `main`, `beta` and `stable`, one run per branch (a newer push cancels the older run) |
| `checks.x86_64-linux.install-validation`, `install-offline`, `install-keep-data`, `install-app-failure`, `offline-inputs` | VM tests of the installer. `install-keep-data`: install, boot, marker files in `/home`, `/srv` and `/var/lib/hinteros`, a damaged ESP, a reinstall with `keepData` that turns SSH on and gives no hostname or password, boot: the hostname and password are kept, SSH is on, the markers and the files in `/var/lib/hinteros` are unchanged, the ESP has its volume id, a new generation exists; what is refused (no install, a newer schema, another layout, a wrong UUID, a broken `state.json`) with the disk unchanged; `--list-disks` on the way. `install-validation`: bad plans (no admin password or one shorter than 8 characters, an app that needs a network while offline, a missing, mounted, system or too small disk, another disk with HinterOS partition labels, BIOS boot, malformed fields, a missing or wrong `diskSeq`, the target unplugged and plugged in again (PCI remove and rescan: same name, new disk sequence number) after the plan was made or, through the test hook `HINTEROS_INSTALL_BEFORE_WIPE`, just before erasing) are refused before the disk is touched. The install tests add the `diskSeq` of the VM's disk to their plans at run time (`tests/vm/install/copy-plan.py`). `install-app-failure`: the same install onto a disk that already holds an old HinterOS install, with one online-only app (`steam`, between `youtube` and `firefox`; test hook `HINTEROS_INSTALL_ONLINE_APPS`) that cannot be downloaded in the VM: exit 0, `failed_apps` lists it, the box boots, `state.json` excludes it, the other apps are installed. `offline-inputs`: every build-time input of what an offline install builds is on the ISO (`nixos/lib/offline-inputs.nix`). The install VMs have only the installer's own store and no network interface. `install-offline`: a VM with no network and an empty second disk installs a plan (YouTube and Firefox, ssh on, an admin account), then the installed disk is booted via UEFI and checked: session up, `/etc/hinteros` and its snapshot, the pinned lock, sshd with the admin's password, no password for the session user or root, the daemon's `apps.list` |
| `devShells.default`, `formatter` | Dev shell with the lint tools and git hooks; `nix fmt` |

`nix flake check` runs everything above, including the VM tests (needs `/dev/kvm`; hours, and every VM test at once): use `scripts/test-plan.sh` instead.

## Releases and channels

Boxes follow the `stable` or `beta` branch of this repo and only install a tip that is signed by
a key listed in `release/allowed_signers` of the generation they are running (design:
`distribution.md` in the docs). Versions are semver; 1.0 is the first public release (0.x were
internal pre-releases) and ships on the `unstable` nixpkgs base only. `release/version` is still
0.7.0, so the first 1.0 beta needs `promote -- beta --version 1.0.0` (the default is the next
patch); the daemon and the launcher are 1.0.0 already. Commits on `main` are not signed; the owner
promotes them:

| Path or command | What it is |
|---|---|
| `release/version`, `release/notes.md` | The release's version (`MAJOR.MINOR.PATCH`) and the release notes, newest first, with what changed since the last stable release under `## Unreleased` on top (the release commit's message). On `main` the version is the latest stable release's (merged back from `stable`); each beta and stable release commit writes its own. Nobody changes the version by hand: `promote` does |
| `release/allowed_signers`, `release/cache-keys` | Release signing keys and binary cache keys every generation trusts (`nixos/modules/release.nix`). Release key fingerprint: `SHA256:NuERttXtUYjtSTqt7kHUqs7TW6rWSHjHOIUlOOADpCE` (ED25519, `hinteros-release`) |
| `nix run .#promote` | **The way to release.** Shows where `main`, `beta` and `stable` are and asks, with numbered menus: what to release where (main → beta, beta → stable, a hotfix branch → stable), which commit, the security severity, the version, and whether to edit the release notes (in `$EDITOR`). It always shows the finished commit for review and asks before signing and pushing. Takes only `--dry-run`, `--skip-ci` and `--key`; for a commit with no CI status at all it asks whether to go on without CI for that commit. The rows below are the same steps with flags instead of questions, for scripts |
| `nix run .#promote -- beta [--rev <main commit>]` | A signed release commit with the tree of the `main` commit, parents `beta` and `main`, verified against the current beta's signers, pushed as a fast-forward. Only `release/version` differs from the tree: the next patch after the current beta and stable, whichever is higher (0.7.1, 0.7.2, 0.7.3 on top of 0.7.0; `--bump minor`, `--bump major` or `--version <v>` for another, the menu asks with the next patch as default). A box shows the version and the commit: `0.7.2.<commit> beta`. The very first one needs `--bootstrap` |
| `nix run .#promote -- stable [--rev <beta release>]` | Shows the changes since the last stable release and asks for the version: the beta release's own by default (beta 0.7.3 → 0.7.3 stable; patch, minor, major after the newest beta, or typed; `--bump <b>` or `--version <v>` without asking), then signs a commit on top of the beta release that only writes it to `release/version` and names the notes section, after the dogfood confirmation (`--expedite` for high/critical security releases). A box shows `0.8.0 stable`. Then merge `stable` into `main` |
| `nix run .#promote -- hotfix hotfix/<name>` | A signed commit with the hotfix branch's tree on top of `stable`, as the next patch after the current stable and beta, so that no beta number is taken twice (stable 0.7.1, beta 0.7.3: hotfix 0.7.4; the branch leaves `release/version` alone and adds an `## Unreleased` notes section; `Security:` severity required); then merge `stable` into `main` |
| `nix run .#promote -- tag [--rev <stable release>]` | After a stable release (or a hotfix): builds the release ISO from that commit (`nix build git+file:...?rev=<commit>#iso`, never from a work tree), writes its `SHA256SUMS` and makes the signed tag `v<version>` on the commit, signed with the release key (no agent) and verified against the release's `release/allowed_signers`; the tag's message body is `SHA256SUMS` itself. It shows the tag for review, asks, and pushes it (never forced). The menus offer it while the stable release has no tag. Upload the ISO and `SHA256SUMS` by hand (see "Check a release ISO") |
| `sudo hinteros-bootstrap-channel [--allow-downgrade] <stable\|beta> <rev>` | On a box, over SSH: move it onto a channel at a rev once, outside the update UI (boxes installed before they trusted the release key). A rev that does not descend from the box's current one (older, or another line) is refused without `--allow-downgrade`: an older system may not read the state a newer one wrote. Tested end to end by the `bootstrap-channel` VM test (its testHooks build; the shipped one has no test hooks). A box whose system predates the script runs it from that very rev: `sudo nix run "git+https://git.hinteros.org/hinteros.git?ref=beta&rev=<rev>#hinteros-bootstrap-channel" -- beta <rev>` |

Run `promote` in your checkout of this repo. It does not trust the remote for what it signs (the
Forgejo server can add commits and set CI green): the target must be on your local `main` (or the
local hotfix branch), and that branch must be the same commit as on `origin`; otherwise it stops
("Pull and review first" or "Push first"). A beta release must verify against the release
signers before it goes to stable. Before signing it shows what changed since the channel's last
release: the commits, a diffstat and, for each flake input whose lock changed, the old and new rev
with the input's commits in between when a clone of it is next to this checkout
(`../hinteros-daemon`, `../hinteros-launcher`, `../hinteros-catalog`; a new rev that is not in
that clone is a warning). `promote` works on a temporary clone of `origin`, prints every check, signs with
`~/.ssh/hinteros/release_ed25519` (or `--key`, `$HINTEROS_RELEASE_KEY`) without ssh-agent, so
the passphrase is asked each time, and never force-pushes. `--dry-run` does everything except
signing and pushing. The commit it releases needs a green CI status (Forgejo's combined status, from
`.forgejo/workflows/check.yml`): a pending one (the check still runs, or waits for a runner) stops
it; with no status at all the menus ask whether to go on for that commit only. `--skip-ci` (it
warns) skips the check, after the checks by hand (`scripts/test-plan.sh full --run`). The signed
`v<version>` tag with the ISO checksums is `promote tag`; uploading the ISO is by hand.

## Installer

The ISO (a hybrid image for USB sticks) starts in UEFI or BIOS mode, but installs only on a machine
that started it in UEFI mode (`not-uefi`). It boots into the controller-driven installer
screens: the launcher in `--installer` mode, run by cage on tty1 as root (`hinteros.installer.ui.command`),
reading the catalog index from `/run/current-system/sw/share/hinteros/` and driving the same backend
as below. If the UI exits, tty1 is the root console with a notice.

Release ISOs are uploaded by hand (to https://hinteros.org) with `SHA256SUMS`; the checksums are
also in the signed tag `v<version>` that `promote tag` makes ("Check a release ISO" below).

### Check a release ISO

Each release ISO's SHA256 checksum is in the signed tag `v<version>` of this repo (`promote tag`):
the tag ties the ISO to the release key, and the ISO's own `release/allowed_signers` then checks
every update of the boxes it installs. Before you write a downloaded ISO to a stick:

```
git clone https://git.hinteros.org/hinteros.git && cd hinteros
git show v1.0.0:release/allowed_signers | grep -v '^#' \
  | sed 's/^\([^ ]*\) /\1 namespaces="git" /' > /tmp/hinteros.signers
git -c gpg.ssh.allowedSignersFile=/tmp/hinteros.signers verify-tag v1.0.0   # Good "git" signature
ssh-keygen -lf <(git show v1.0.0:release/allowed_signers | grep -v '^#' | cut -d' ' -f2-3)
git tag -l --format='%(contents:body)' v1.0.0 > SHA256SUMS
sha256sum -c SHA256SUMS   # next to the downloaded hinteros-installer.iso
```

The key fingerprint must be the release key's above (`SHA256:NuERttXtUYjtSTqt7kHUqs7TW6rWSHjHOIUlOOADpCE`).

### Build the ISO and write it to a USB stick

Release ISOs and install instructions for users are on [hinteros.org](https://hinteros.org). To
build an ISO yourself:

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
a placeholder revision and is only good for tests; such an ISO is `result/iso/hinteros-installer-dirty.iso` and its boot menu says "dirty tree: tests only"). Installing needs the stick started in UEFI mode with Secure
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
  "version": 1,
  "disk": "/dev/nvme0n1",
  "diskSeq": 1,
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
| `version` | Optional: the plan format, default 1 (this installer reads 1). Every new plan field bumps it. A higher version is refused as a whole (`plan-newer`, exit 2): an installer never ignores a field it does not know (`unknown-field`), because it could change what is erased. Not a whole number of 1 or more: `plan-version-invalid`. The JSON the backend prints (`--info`, `--list-disks`, `--check-newer`, progress lines) only gains fields: readers ignore fields they do not know |
| `disk` | Whole-disk device path (`/dev/nvme0n1`, `/dev/disk/by-id/...`). Refused if it does not exist, is mounted (this includes the installer stick) or is under 16 GiB |
| `diskSeq` | Required: the kernel's disk sequence number of that disk (`lsblk -o PATH,DISK-SEQ`, `/sys/class/block/<name>/diskseq`). Every attach gets a new one, never used again until the next boot, so a disk unplugged and another (or the same) plugged in under the same name does not match. Checked when the plan is checked, after the newer-`rev` download and again just before the disk is erased; a mismatch stops the install before anything is touched (`disk-changed`, exit 2; the UI goes back to the disk choice). Not an integer of 1 or more: `disk-seq-invalid` |
| `hostname` | Lowercase letters, digits and hyphens |
| `admin` | `user` plus `password` (plain text, hashed by the installer) or `hashedPassword` (`mkpasswd` output). Required: it is the only SSH login and the sudo account. The session users (`hinteros-p<N>`) and root get no password |
| `ssh.enable` | sshd from the first boot, password login for the admin only. Default false |
| `channel` | `stable` or `beta`: the `ref` in the generated flake's input URL. Default: the installer's own channel, `hinteros.installer.channel` (`stable`; a beta ISO sets `beta`); a `keepData` plan keeps the install's channel. On a beta installer, `stable` needs `rev` (the stable tip): the beta revision on the ISO is no stable release (`channel-needs-rev`; a `keepData` plan takes no `rev`, so a stable install needs a stable installer) |
| `base` | nixpkgs base; only `unstable` exists. Default `unstable` |
| `apps` | Catalog ids, listed from the catalog's `starter` entries (`nixos/lib/app-ids.nix`): the `onIso` apps (`jellyfin-desktop`, `youtube`, `firefox`; on the ISO, work offline) and `steam`, `vacuum-tube` and `plex-htpc` (downloaded, or built on the box for Plex; online only; nothing unfree is on the ISO). The installer offers exactly these six; Crunchyroll, Moonlight and the streaming apps are Store-only. The installer UI pre-selects `youtube` and `firefox` |
| `acceptedTerms` | Optional `{"<id>": "<terms version>"}`. An app whose catalog entry has vendor terms (Steam, Plex) is refused (`terms-not-accepted`) unless the accepted version equals the version in the catalog index on this installer. The accepted ones are recorded on the box in `/var/lib/hinteros/terms-accepted.json` (root, 0600): `{"version": 1, "accepted": {"<id>": [{"version": ..., "accepted_at": ..., "by": "installer"}]}}`, only for the apps that were installed |
| `wifi` | Optional `{ssid, psk}`: connects before the install and keeps the connection on the installed box |
| `network` | Optional: `auto` (default; online if cache.nixos.org answers), `online` (fail if not) or `offline` |
| `keepData` | Optional, default false. `true`: a reinstall that repairs in place, nothing is erased (below). Such a plan takes `disk`, `diskSeq`, `network`, `wifi` and, optionally, `channel`, `hostname`, `admin` (the password is optional) and `ssh`: those given replace the settings of the install, the others are kept (without `channel` the box stays on the channel of its `flake.lock`; the installer's channel only if that is unknown). Any of `base`, `apps`, `acceptedTerms` or `rev` is refused (`keep-data-field`) |
| `rev` | Optional: the HinterOS revision to install (40 hex digits). Absent or this installer's own revision: install the version on the installer (offline if need be). Another revision must be the newer release `--check-newer` reported (see below); it is verified again before anything is touched and needs the network |

The plan may hold a plain-text password: keep it on tmpfs and delete it afterwards (`--plan -`
reads it from stdin). `--validate-only` checks the plan and the machine and touches nothing. With a newer `rev` it also checks that the network is there and the revision verifies (below). `--state-dir DIR` (tests) checks the plan only and writes the `state.json` files the install would produce (`DIR/system`, `DIR/apps`).

**Progress.** stdout is one JSON object per line, for example
`{"phase":"system","stage":"build","percent":57,"level":"info","message":"..."}`. `phase` is
`system` or `apps` (see below); during the apps stage a line may also carry `app` (a catalog id).
Stages in order: `validate` (0-8), `fetch` (9, only when installing a newer `rev`), `partition` (10-20), `facter` (22-26), `config` (28-30),
`packages` (32-50), `build` (50-66), `bootloader` (66-70), `snapshot` (72-73) - all phase `system` -
then, if the plan has apps, `apps` (74-96, phase `apps`), `finalize` (97), `done` (100). Percentages
never go backwards. A line may carry `step_percent` (0-100, how far the current step is; absent: not
measurable). The system install is three steps, each with its own count:
`packages` first gets the package list (`nix build --dry-run`, no `step_percent`), then copies the
packages from the ISO (offline) or downloads them (online) into the target, `"<done> of <total>
packages"` (or `"Nothing to copy"` / `"Nothing to download"`); `build` builds what is not prebuilt,
`"Building <name> (<i> of <n>)"` or `"<done> of <n> built"` (`"Nothing to build"`), and these
lines also carry `build` (the name of the newest running build, without hash and version; absent
when none runs), `build_index` (1-based), `build_total` and, with `build`, `build_percent` (how far
that build is, 0..99, from its stdenv phase as in hinteros-system's `nixlog.rs`; absent before its
first standard phase and for builders without phases), and `step_percent` counts the running
builds by their phase too; `bootloader` runs
`nixos-install --system` with the built system (the system profile and the boot loader) and ends
with `"System installed, boot loader written"`. A retry (`warn`, code `system-retry` or
`bootloader-retry`) starts again from `packages`. `level` is `info`, `warn` or `error`. An `error` line also has a `code`
(`admin-password-missing`, `admin-password-short`, `app-needs-network`, `disk-not-found`, `disk-changed`, `disk-in-use`, `disk-too-small`,
`other-hinteros-disk`, `not-uefi`, `install-failed`, `rev-needs-network`, `fetch-failed`, ...) and the exit status is 2 (the plan or the
machine was refused, nothing was touched) or 1 (the base system could not be installed). Tool
output goes to stderr and `/var/log/hinteros-install.log`; when a build fails the log also holds
nix's error messages in full and the build log (`nix log`) of every derivation that failed.
The `done` line also carries `rev` and `version`: the HinterOS revision and release that were
installed (its message names them too).

**Two stages.** Installing HinterOS and installing the apps are separate, so a broken app can
never cost the user the system:

1. **System stage** (phase `system`): the base system with no catalog apps (`state.json`
   `apps: []`), offline from the ISO's store if need be. It ends with a bootable box. If it fails
   online (a download, or the hardware report does not build), it is retried once as the generic
   offline system from the ISO (not for a newer `rev`, below); if it still fails the run exits 1.
2. **Apps stage** (phase `apps`, only if the plan lists apps): the selected apps are built into the
   installed system (`nix build` of the full config against the new root; offline for the `onIso`
   apps, downloading for the others) and made the next boot's generation with
   `nixos-install --system`, which writes the boot entry last; the base generation stays in the
   boot menu. If building all apps together fails, they are tried one at a time and the ones that
   build are installed; each failure gets a line
   `{"phase":"apps","level":"warn","code":"app-failed","app":"<id>","message":"..."}`. If activating
   fails, the base system is put back. `state.json` and `terms-accepted.json` list only the apps
   that were actually installed. The run still exits **0** when the system stage succeeded, and
   ends with `{"stage":"done","percent":100,"failed_apps":["<id>",...]}` (empty if none).

**Keep data.** A plan with `keepData: true` installs a new system on a disk that holds HinterOS and erases nothing. It is refused, exit 2, nothing touched, unless the disk holds an install this installer can read: `keep-no-install` (no partitions `hinteros-esp` and `hinteros-root`), `keep-not-btrfs`, `keep-unreadable`, `keep-no-subvolumes` (`root`, `nix`, `home`, `srv`), `keep-state-unreadable` (`etc/hinteros/state.json` does not parse, or has no valid `schemaVersion` or `disk.espUuid`), `keep-layout` (`disk.layout` is not `gpt-esp-btrfs`), `keep-schema-newer`, `keep-uuid-mismatch` (`disk.rootUuid` is not this file system's). The other-disk check does not apply: nothing is partitioned. Stages: `validate`, `mount` (10-20, in place of `partition`), `facter`, `config`, `packages`, `build`, `bootloader`, `snapshot`, `finalize`, `done`. The subvolumes are mounted; `/etc/hinteros` keeps `state.json` and `extra.nix` and gets this installer's `flake.nix` and `flake.lock` and a new hardware report, as a normal install; the system goes into the existing store. As the last step before the boot loader the ESP is formatted again with the volume id in `disk.espUuid` (so a damaged ESP is repaired and the UUID holds). A run that fails before the new system is installed (exit 1) puts back `/etc/hinteros`, the admin password hash and the boot files it saved before formatting (a damaged ESP that does not mount has none), so the old system boots as it was; once the new system is installed the saved copy is deleted; the hook `HINTEROS_INSTALL_NIXOS_INSTALL` (tests) replaces `nixos-install` to check this. The plan's `hostname`, `admin.user` and `ssh.enable`, where given, replace `settings.hostname`, `settings.admin.user` and `settings.ssh.enable` in `state.json`; the rest of `state.json` stays. A plan password replaces the admin password; without one the password stays (refused with `admin-password-missing` if the install has no admin account). There is no apps stage, and the admin password (unless the plan gives one), `terms-accepted.json`, the starter set, app envs, `/var/lib/hinteros`, `/home` and `/srv` are not touched. If the system built is the same as the current generation, Nix makes no new generation; the boot loader is still written. Offline, a box with `requirements` or `services` that are not on the medium needs what they need from its own store; if the store lacks it the install fails with `install-failed` and needs a network; the box is put back as above.

`hinteros-install --list-disks` (offline; needs root to look inside a disk) prints `lsblk --json -b -o NAME,PATH,SIZE,MODEL,TRAN,TYPE,RM,MOUNTPOINTS,DISK-SEQ` with `existing` added to every whole disk: `{"version":"1.0.0","channel":"stable","profiles":2,"hostname":"livingroom","admin":"alice","ssh":false,"schemaOk":true}` or `null`. `version` is the installed release, absent if unknown; `hostname` and `admin` are `state.json`'s settings, absent if not set, and `ssh` is `settings.ssh.enable`; `profiles` counts `state.json`'s accounts; `schemaOk` says a `keepData` plan is accepted on this disk. `null`: no readable install, the disk is in use, or an install runs. A disk is mounted read-only without replaying its log; an unreadable disk gives `null`, never an error. Locks: an install holds `/run/hinteros-install.lock` exclusively from its validation to its end (it may erase any disk) and waits up to 100 s for listings to end, then refuses with `already-running`. A listing takes that lock shared without waiting; while an install holds it, no disk is looked into (every `existing` is `null`). Listings look into disks in turn on `/run/hinteros-install.probe.lock` (a listing waits up to 45 s, else it looks into no disk), so one never takes a disk another mounted for a disk in use; the rest of a listing runs side by side with others. A listing stopped with SIGTERM (the launcher stops one after 60 s) waits for the mount it was doing (up to 35 s) and undoes it before it ends, still holding both locks.

**What it does.** Validate the plan and the machine (including: no other disk may carry the
partition labels `hinteros-esp` / `hinteros-root`, because the partitioning script finds them by label;
`other-hinteros-disk`; and it must still be the disk the plan was made for, `diskSeq`); check
that again right before erasing (`disk-changed`, `other-hinteros-disk`); stop the device-mapper and RAID devices an old system left active on the target (LVM, md), erase old signatures on it and partition with disko (GPT, a 1 GiB
ESP and one btrfs file system with the subvolumes `root` (`/`, with `/var`), `nix`, `home` and `srv`,
`compress=zstd:1,noatime`, no snapshots, no encryption; the installed system mounts them by UUID,
`state.json` `disk.rootUuid` and `disk.espUuid`, read with `blkid` after formatting), then check that
the file systems are on the target disk and the new subvolumes are empty;
`nixos-facter` writes `facter.json` (a failure only warns: the box then boots with generic
drivers). An **offline install applies no hardware report**: it installs exactly the generic system
that is prebuilt on the ISO (`nixos/modules/generic-hardware.nix`: common storage, USB, NVMe and card
reader modules in the initrd, redistributable firmware, both CPU microcodes) so it builds nothing
big whatever the machine is, and leaves `facter.deferred` next to `facter.json`; the device flake
ignores the report while that marker exists, `hinteros-facter-release` removes it once the box is
online, and the next rebuild or update applies the report. Online installs apply it at once; write
`/etc/hinteros` (`flake.nix` from `nixos/templates/device-flake.nix.in`, `flake.lock`,
`state.json`); write the admin password hash to `/var/lib/hinteros/admin-password-hash` (0600,
referenced by the config, never in `state.json` or the store); build the system into the new root
as `nixos-install` would (`nix build --store /mnt`, in the three steps above) and install it with
`nixos-install --system --no-root-passwd`;
check that `/etc/hinteros` equals the generation's snapshot; the apps stage; unmount. Where EFI
variables cannot be written (efivarfs missing or read-only, or the boot loader step failed once)
`extra.nix` in the config dir sets `boot.loader.efi.canTouchEfiVariables = false` and the box boots through the
fallback path `EFI/BOOT/BOOTX64.EFI`. After the boot loader is written, the firmware entries "Linux Boot Manager" (and its fallback) that point at a partition this run erased are removed, so the boot menu does not grow by two entries per install; entries of other disks stay, also of unplugged ones. A `VenHw` entry (some firmware turns entries into one) names no partition: it is removed only when no other disk has an EFI system partition.

**nix and the network.** nix switches substitution off as soon as the machine has no network
interface with an address ("you don't have Internet access; disabling some network-dependent
features"), local-store substituters included. An offline install on a box without a cable therefore
substituted nothing and tried to build the whole system from source, ending in "Reason: 1
dependency failed" after a failed download of `bash-5.3.tar.gz`. Every nix call of the installer
passes `--option substitute true`. NixOS test VMs always have a user-mode `eth0`, which is why this
went unnoticed: the install tests now run the installer with only its own store image and no NIC at
all.

### What the installer carries

The UI asks the backend which HinterOS the stick carries and which channel it is for, so it can
show that version and pick the channel before anything goes online:

```
hinteros-install --info
{"iso":{"rev":"<40 hex>","version":"0.7.0"},"channel":"stable"}
```

`iso.rev` is the revision the installer is built from (`hinteros.installer.isoRev`; all zeros for
an ISO built from a dirty tree), `iso.version` that revision's `release/version`, `channel` the
installer's channel (`hinteros.installer.channel`, the default `channel` of a plan). It is built
into the installer: no network, no root, nothing logged, one line on stdout, exit 0. A beta
installer's `iso.version` is the beta release's own version, as on a box. Tested by
`install-validation`.

### A newer HinterOS than the ISO's

With a network, the installer can install the newest release of its channel instead of the one
on the stick. The UI asks the backend, shows both versions and lets the person choose; the ISO's
version stays the default and the only choice offline.

```
hinteros-install --check-newer [--channel stable|beta]   # default: the installer's channel
{"channel":"stable","iso":{"rev":"<40 hex>","version":"0.7.0"},"newer":{"rev":"<40 hex>","version":"0.7.1","date":1767225600,"signer":"release"}}
```

It fetches the channel's tip from the repo (`hinteros.update.repo`; a partial clone: commits and
trees, plus the tip's `release/version`) and verifies it as a box verifies an update
(hinteros-system's `update.rs`): an SSH signature by a key in **this installer's**
`release/allowed_signers` (`hinteros.update.allowedSigners`) and a fast-forward from the ISO's
revision. `newer` is null when the tip is the ISO's revision or older. `version` is the tip's
`release/version`, or its first 12 hex digits if it has none; `date` is the commit time (Unix
seconds). One object on stdout, exit 0. On failure, one error line in the progress format
(`{"phase":"check","stage":"check","level":"error","code":...,"message":...}`) and exit 1
(`repo-unreachable`, `timeout`, `channel-missing`, `unsigned`, `unknown-signer`,
`not-fast-forward`) or 2 (`channel-invalid`, `iso-rev-unknown`: an ISO built from a dirty tree).
No root needed. Every git step has a time limit and the steps that talk to the repo stop after 2
minutes together (`timeout`): the check takes a few seconds normally and never much over 2 minutes.

A plan with that `rev` installs it: validation needs the network (`rev-needs-network`) and checks
the channel again (`rev-not-tip` if the tip has moved on, the codes above if it does not
verify; exit 2); then, before the disk is touched, the `fetch` stage downloads the revision, locks
the device flake to it (`nix flake lock --override-input hinteros
git+<repo>?ref=<channel>&rev=<rev>`, as hinteros-system and `hinteros-bootstrap-channel` do) and
reads its catalog (`lib.installerCatalog`; `fetch-failed`, exit 1, also for a format this installer does not know). The system and apps stages build from that lock, so
the apps are that revision's: a picked app it no longer offers, or whose vendor terms changed, is
an `app-failed` warning (the Store asks again later). There is no offline fallback: if the system
stage fails (also after one retry without the hardware report) the run exits 1, and the UI offers
to try again or to go back to the ISO's version. Tested by `install-newer` (a local channel repo
with throwaway keys; `HINTEROS_INSTALL_ONLINE_PROBE` stands in for the network).

### Offline installs

Tested by `install-offline-hw`: the installer is fed the report of an Intel mini PC (bare metal, i915,
NVMe, Realtek and Intel NICs, `tests/vm/fixtures/facter-intel-minipc.json`) through the
`HINTEROS_INSTALL_FACTER` hook and the install must succeed offline building only configuration
assemblies (no `bash`, kernel, firmware or microcode builds). A VM's own report changes nothing,
which is how this bug once passed.

`install-offline-m900` is the same install-and-boot test as `install-offline` (YouTube + Firefox ESR with
the OSK extension, ssh, an admin, UEFI boot into the session) with the real nixos-facter report of the
owner's Lenovo ThinkCentre M900 (Skylake i5-6500T, Intel HD 530, I219-LM/e1000e, SATA SSD, Realtek
ALC233) through the `HINTEROS_INSTALL_FACTER` hook: no package derivation is built, the report is
written, deferred and byte-identical on the installed disk. A control then removes the marker and
`nix build --dry-run`s the device config; the log lines `M900-CONTROL:` list what the first online
update would build: only configuration assemblies (udev rules/hwdb, the `eno1` link and address
units, dhcpcd/sysctl units, `system-path`, `etc`, the initrd and the kernel's `modules-shrunk`, the
system itself), no firmware, microcode or other package. The report applies no firmware or
microcode of its own because the generic system already carries them
(`nixos/modules/generic-hardware.nix`). The fixture `tests/vm/fixtures/facter-lenovo-m900.json` is the
real report with the per-unit identifiers replaced by fixed dummies: the serial numbers of the two
disks (SATA SSD, the installer USB stick; also inside their `/dev/disk/by-id` names and the SSD's
WWN), the monitor's EDID serial, and the unit number in the board's SMBIOS version. It has no MAC
address, UUID, filesystem label or hostname (nixos-facter does not record them); vendor/device IDs,
drivers, modules, CPU features and graphics are untouched.

The ISO also has: wired DHCP without any UI action (an Ethernet profile for NetworkManager, no
dhcpcd), firmware, cage with `-s` so Ctrl+Alt+F2 reaches a root console on tty2 (HinterOS motd;
sshd is off) and a blank cursor theme for the UI session; `installer-ui` tests keys reaching the UI,
the tools, the motd and the VT switch.

### Diagnosing a box

Every HinterOS system (devices and the ISO) has `pciutils`, `usbutils`, `ethtool`, `iw`, `lshw`,
`nixos-facter` and:

- `hinteros-diagnose [--full]`: a report that fits one or two TV screens (photograph it): `ip -br
  link`, carrier, speed, EEE, driver and firmware per interface (`ethtool`), PCI network devices
  (`lspci -nnk`), kernel log lines for NIC drivers and firmware loading, `nmcli device` and
  `general`, Wi-Fi and `rfkill`.
- `back` (alias `installer`, ISO): from the tty2 console to the installer screens on tty1; it restarts the UI if it is not running or tty1 does not come to the front, but never while `hinteros-install` holds its lock (the UI runs the install in its own unit, so a restart would kill it), and a reminder is printed above every tty2 prompt. The UI's stderr goes to the journal (and so into `hinteros-save-log`'s `journal.txt`).
- `hinteros-save-log /dev/sdX` (ISO): saves the install log, journal, dmesg, the `hinteros-diagnose`
  output, nmcli, lspci, lsusb, lsblk and a `nixos-facter` report in a timestamped folder on a second
  USB stick. Give the whole stick or one partition (a whole stick uses its first partition with a
  filesystem); FAT32, exFAT, NTFS (kernel `ntfs3`) and ext4 work. It refuses the installer stick and
  the target disk, and says what is wrong when the stick is read-only, full or has another
  filesystem. Tested by `installer-save-log`.

An Ethernet port that `nmcli device` shows as `unavailable` has no carrier: check the cable and LEDs
first (`hinteros-diagnose` shows `carrier=0 link=no`). The wired profile turns EEE off and Wi-Fi
power saving is off (`nixos/modules/network-hardware.nix`); the NIC drivers are all in-tree (r8169
including RTL8125, igc, e1000e, igb, r8152, ax88179_178a, cdc_ncm, cdc_ether).

The ISO also carries the build-time inputs of the small derivations an install builds (etc, units, the
initrd, the toplevel ...): `nixos/lib/offline-inputs.nix` derives them from the derivations of several
representative devices (no apps, each app alone, all apps, ssh on and off) and the `offline-inputs`
flake check fails if a different set of devices needs an output that is not on the ISO. Without
them nix builds the missing input and its inputs, down to the bootstrap tools.

The ISO carries the closure of a default system (the base plus the three `onIso` apps in
`nixos/lib/app-ids.nix`: jellyfin-desktop, youtube and firefox; the Store-only streaming apps whose catalog entry has `onIso` are on it too, off), the sources of this repository and of every flake input it locks, and a
`flake.lock` for the generated device flake whose `hinteros` input points at the revision the ISO
was built from, with the same `narHash` (`nixos/lib/device-lock.nix` embeds this repository's own
lock, so every transitive input is pinned too). Nix resolves a locked input whose narHash is already
in the store without fetching, so `nixos-install --flake path:/mnt/etc/hinteros#hinteros` evaluates
and substitutes from the ISO's store. Online installs use the same lock, so the installed system is
the ISO's revision and nixpkgs (only extra apps are downloaded); the first `nix flake update
hinteros` on the box moves it to the channel. Steam is not on the ISO: it is
refused offline (`app-needs-network`) and downloaded during an online install. Nothing unfree is
ever on the ISO (`hinteros.forbidUnfree`).

## Working against local component checkouts

`scripts/dev-override <nix subcommand> ...` runs a nix command with every component input
(`hinteros-launcher`, `hinteros-daemon`, `hinteros-catalog`) overridden by the sibling checkout `../<name>`, using
`git+file:` so untracked build output is not copied. Inputs missing from `flake.nix` or without
a sibling directory are skipped.

```
scripts/dev-override flake check
scripts/dev-override build .#vm
```

## Layout

| Path | Contents |
|---|---|
| `nixos/modules/` | HinterOS NixOS modules, one file per area (session, input, daemon, apps, app-env, catalog, profiles, state, disk, device-config, runtime, maintenance, hardening, server, time-zone, box-features, branding, ...; `default.nix` imports them all) |
| `nixos/lib/` | `mkDevice`, `device-outputs.nix`, `device-lock.nix` (the offline flake.lock), `offline-inputs.nix`, `app-ids.nix` (app ids and which are on the ISO) and other helpers |
| `nixos/installer/`, `nixos/templates/` | The installer environment and ISO config; the `/etc/hinteros/flake.nix` template |
| `devices/` | Checked-in devices (`devbox`) |
| `nixos/overlay.nix`, `nixos/pkgs/` | The overlay and the packages it adds |
| `nixos/vm/` | Test VM configuration (shared by `nix run .#vm` and the VM tests) |
| `scripts/` | Dev scripts (`dev-override`) and the release tool (`promote.sh`) |
| `release/` | Version, release notes, release signing keys, cache keys |
| `nixos/hardware/` | Per-model hardware profiles layered on top of the `hardware.facter` report |
| `tests/vm/` | NixOS VM tests |
| `tests/couch/` | Manual couch-test checklists, one per milestone |

## License

GPL-3.0-only. See [LICENSE](LICENSE).
