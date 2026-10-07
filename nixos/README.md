# NixOS

- `modules/`: the HinterOS NixOS modules, exported by the flake as `nixosModules`.
  - `session.nix`: greetd autologin into gamescope running the home app.
    Options: `hinteros.session.enable`, `.user` (default `hinteros`), `.compositor`
    (`gamescope` or `cage`), `.environment`, `.homeApp`
    (package, default `pkgs.hinteros-launcher`; `pkgs.hinteros-placeholder-home` is kept for debugging), `.gamescope.package`, `.gamescope.extraArgs`, `.gamescope.reviewedVersion`. The compositor gets `XKB_DEFAULT_LAYOUT=us` (the daemon types US key codes). The gamescope version is pinned: the daemon vendors gamescope's private `gamescope_input_method` protocol (3.16.31), so evaluation fails with another version until `reviewedVersion` is updated after re-checking the daemon's protocol XML.
    `.launcherAppId` (4100000000) and `.reaperPackage`: under gamescope (always `-e`, Steam mode) the home app runs as
    `hinteros-session reaper SteamLaunch AppId=<id> -- <home app>`, so gamescope gives its windows the launcher app id.
    The daemon user unit retries until gamescope's Xwayland (`:0`) is up. `.gamescope.backend` (`drm`, `headless`, `wayland`, `sdl`; default: gamescope chooses).
  - `input.nix`: `hinteros.input.enable` (default: the session is enabled). InputPlumber with polkit,
    the session user in group `inputplumber` and its udev rules. `ManageAllDevices` is set by the session daemon.
  - `daemon.nix`: `hinteros.daemon.enable`, `.group` (default `hinteros`), `.session.package`,
    `.system.package`, `.osk.{enable,package,summon}` (the on-screen keyboard, `hinteros-osk` from the launcher package; `[osk]` in session.toml; default chord Guide+Y), `.logLevel`. A systemd user service `hinteros-session` for the session user
    (socket `$XDG_RUNTIME_DIR/hinteros/session.sock`, started with `--config` of a `session.toml` generated from
    `.session.settings`, a TOML-format attrset; defaults: `launcher.app_id`, `gamescope.*` (disabled on cage, where `wayland_display` is `wayland-0` and the user unit gets `DISPLAY=:0`), `osk.*`, `steam.path`) and a root system service `hinteros-system`
    (`/run/hinteros/system.sock`, 0660, group `hinteros`, which the session user joins). What the system service
    needs (hinteros-daemon README, "What the system module must provide"): `hinteros-system.service` with `RuntimeDirectoryPreserve=yes`,
    `StateDirectory=hinteros` (0700), `ProtectSystem=strict` + `ReadWritePaths=/run/hinteros`, `MemoryDenyWriteExecute`,
    `SystemCallFilter=@system-service`, `AF_UNIX` only and `CapabilityBoundingSet=CAP_SYS_PTRACE` (audit reads `/proc/<pid>/exe`);
    the template `hinteros-job@.service` (root, network, no `ProtectSystem`, `ExecStart=hinteros-system job %i`, PATH with nix, git, openssh,
    nixos-facter, `restartIfChanged = stopIfChanged = false` so the switch a job performs never restarts it); the polkit actions
    `org.hinteros.system.{settings,rebuild,update.check,update.apply,rollback,channel,jobs.cancel}` (default no) and `.ssh` (`auth_admin`)
    in `share/polkit-1/actions/org.hinteros.system.policy`, and `/etc/polkit-1/rules.d/50-hinteros.rules` granting all but `.ssh` to the `hinteros` group;
    both daemon packages in `systemPackages`; and the per-generation files in `sw/share/hinteros/`: `release.json` (`{version, dev}`;
    `hinteros.release.version`), `update/channels.json` (`hinteros.update.repo`, branches `stable`/`beta`; the device flake's input line
    `git+<repo>?ref=<branch>` is generated from the same option by the installer) and `update/allowed_signers` from
    `hinteros.update.allowedSigners` (a list of `"<principal> ssh-ed25519 <key>"`, written in ssh-keygen format with `namespaces="git"`).
    **`allowedSigners` is empty by default: the owner must add his signing key (and an offline backup) before M6 releases.** With none,
    every update and channel check fails closed (git finds no matching principal, the daemon reports `update_verification_failed`/`unknown_signer`).
  - `state.nix`: `hinteros.state` (set by `lib.mkDevice`) is the decoded state.json; it asserts `schemaVersion` 1, rejects unknown fields and app ids, and maps `settings.ssh`, `settings.hostname`, `settings.admin` (admin account, hash file `/var/lib/hinteros/admin-password-hash`), `stateVersion`, `disk` (`disk.nix`), `apps` (a state enables exactly the listed default apps; ids in `lib/app-ids.nix`) and the first profile's user (TODO M7: one user per profile).
  - `disk.nix`: `hinteros.disk.enable` (state.json `disk`): the installer layout, ESP + ext4 root by partition label `hinteros-esp`/`hinteros-root`, systemd-boot, zram.
- `installer/`: `default.nix` (installer environment: `hinteros-install`, disko, offline closure and lock, `hinteros.installer.ui.command` hook) and `iso.nix` (installation-cd base); `pkgs/hinteros-install`, `templates/device-flake.nix.in`. See the repo README, "Installer".
  - `fake-steam.nix`: `hinteros.fakeSteam.enable` (tests only) installs the stub `steam` and a fake Steam home for the session user (`libraryfolders.vdf`, 3 games and 3 tools that `games.list` filters out, `librarycache` artwork) and points the daemon at it with `steam.dir`.
  - `apps.nix`: the app registry. `hinteros.apps.<id>` = { `enable`, `name`, `order`, `kind`, `package`, `command`, `kiosk.{url,userAgent,fullscreenOnly}`, `icon`, `unfreeName`, `input`, `backKey`, `backend` } becomes the daemon's `[[apps]]` (id, name, kind, icon, command) and installs the package. Defaults, enabled with the session: `jellyfin` (`pkgs.jellyfin-desktop`, the successor of jellyfin-media-player), `youtube` (Firefox kiosk at youtube.com/tv with a PlayStation 5 User-Agent, only for its profile; `hinteros.apps.youtube.backend = "vacuumtube"` switches to `pkgs.vacuum-tube`), `crunchyroll` (kiosk), `firefox` (plain, no `--kiosk`, fullscreen by the compositor). `plex` (`pkgs.plex-htpc`, unfree) exists but is off; the dev box enables it. Icons are generated at build time with ImageMagick: a coloured square and a letter, no logos. `input` (`gamepad`/`keyboard`) and `backKey` are written to session.toml (`input`, `back_key`); the web apps use `input = "keyboard"` (the daemon turns the pad into arrows, Enter and `back_key`; try `hinteros.apps.youtube.backKey = "backspace"` if Escape does not go back in YouTube TV).
  - `firefox-kiosk.nix`: `hinteros.firefoxKiosk.enable` (automatic with a kiosk app): `programs.firefox` with enterprise policies for all profiles (no first run or telemetry, no password prompts, Widevine and EME on, VA-API prefs), and `hinteros-firefox-kiosk [--user-agent UA] [--no-kiosk] <name> <url>`: Firefox on Xwayland (`MOZ_ENABLE_WAYLAND=0`), profile in `~/.local/share/hinteros/firefox/<name>`, UA override written to that profile's user.js.
  - `unfree.nix`: `hinteros.unfreeAllowlist` (package names; the only place that sets `allowUnfreePredicate`) and `hinteros.forbidUnfree`, which fails evaluation while the list is non-empty; the future ISO/cache configurations set it. Plex must never be cached or on the ISO.
  - `overlay.nix`: adds `overlays.default` to nixpkgs.
- `lib/mk-device.nix`: `lib.mkDevice` (TODO: stable nixpkgs base as a second input).
- `overlay.nix`, `pkgs/`: the overlay and its packages. `hinteros-fake-steam` is a stub `steam` (logs argv to `$XDG_RUNTIME_DIR/fake-steam.log`, opens an xterm "Fake game <id>" (under the reaper with the Steam app id) on `steam://rungameid/<id>`). It also accepts `-silent` (starts a stand-in `steam` process), `-gamepadui` and `steam://open/bigpicture` (a fullscreen "Fake Big Picture" window, WM_CLASS `steam`/`Steam`, which the daemon treats as Steam's), `steam://close/bigpicture`, and `--hinteros-fake-popup "<title>"` (a Steam-style dialog such as "Steam Guard", for the attention flow); the fake home is `appmanifest_*.acf` files, `libraryfolders.vdf` and artwork. `hinteros-placeholder-home` is an xterm
  showing text.
- `vm/`: the test system (`default.nix`, shared with the VM tests) and the interactive QEMU
  hardware (`qemu.nix`).
- `hardware/`: per-model profiles. The `hardware.facter` report is always the baseline
  (`mkDefault`); a profile matched by DMI vendor/product overrides only that model's quirks.

## VM and gamescope

gamescope cannot present on the VM's software Vulkan with the DRM backend (llvmpipe lacks DRM
format modifiers and dma-buf export), so the VM and the `boot` test use
`hinteros.session.compositor = "cage"` (software rendering). gamescope's `headless` backend
(`hinteros.session.gamescope.backend = "headless"`) does run on lavapipe, but only simple
clients render: the `gamescope` test runs it (with `-e`) with the xterm placeholder home app and the session daemon, checks
`GAMESCOPECTRL_BASELAYER_APPID` with xprop, uses the session socket (API 0.7) for `games.list`, a fake Steam game, `apps.close`, Big Picture and a fake Steam Guard pop-up (`steam_attention`, `steam.focus`), and checks
by OCR of `gamescopectl screenshot` that the game, then (after SIGUSR1) the placeholder again, is shown. The Flutter launcher stays on cage in VM tests (spike 2).
`nixosConfigurations.vm-gamescope` is the interactive VM with gamescope for a Vulkan-capable setup.
On gamescope the launcher runs on native Wayland (`GDK_BACKEND=wayland`, `--expose-wayland`).

The `typing` test (cage, loopback only) runs Firefox on a page with a text and a password field;
over the session socket (API 0.7) it calls `keys.type` with a URL, `keys.action tab`, `keys.type`
with `P@ss-w0rd!` and `keys.action enter`, and checks that the page received exactly those values
through the daemon's uinput keyboard. It also checks that the daemon started `hinteros-osk`, that
the OSK connected at 0.7 and that `osk.show`/`osk.hide` answer.

## Device config, runtime settings and maintenance (M5/M6 groundwork)

- `device-config.nix`: `hinteros.deviceConfig.{enable,dir,configDir}`. Each toplevel embeds
  `flake.nix`, `flake.lock`, `state.json` at `$out/hinteros/` (`mkDevice { configDir; }`; without
  it, `state.json` generated from the state). `hinteros-config-sync` (oneshot before the
  daemon and greetd) restores `/etc/hinteros` from `/run/current-system/hinteros` by building a
  sibling temp dir and swapping with `mv --exchange`; `facter.json` and other files are kept.
  Skips when `/etc/hinteros` or the snapshot is missing. `configDir` must be a plain path (a flake
  source), not a derivation output, because the module reads it at eval time.
- `runtime.nix`: `hinteros.runtime.{enable,network,bluetooth,audio,power}`, on with the session.
  NetworkManager (no VPN plugins), BlueZ (`Experimental`, `UserspaceHID`, `ClassicBondedOnly`
  stays true), PipeWire/WirePlumber, logind (power key suspends, lid ignored), and polkit rules
  scoped to the session user's active local session: suspend/reboot/power-off and the Wi-Fi
  actions. `settings.modify.system` is granted (accepted: the session user can read Wi-Fi PSKs; see the module comment and threat-model.md).

- `hardening.nix`: on with the session (threat-model.md). Session user never in `wheel`, `trusted-users = ["root"]`, `allowed-users = ["root"]`, no sudo (`security.sudo.enable` only with `hinteros.admin` or dev), polkit admin identities = root + the admin, persistent capped journal, `systemd-boot.editor = false` (set only here). `hinteros.admin.{enable,user,hashedPasswordFile}`: optional admin account (wheel, sudo always asks its password, password file required, never committed; the M9 wizard sets it). `hinteros.ssh.enable` (from state.json `settings.ssh.enable`, off by default) runs sshd with username + password, `PermitRootLogin no`, `AllowUsers` = the admin only (never the session user), and requires `hinteros.admin`; the polkit action `org.hinteros.system.ssh` (`auth_admin`, defined in `daemon.nix`) is what the privileged service checks before flipping it (the session user gets `authentication_required`). Key-only SSH, key import, a LAN-only firewall and rate limiting are backlog. `hinteros.dev.enable` (default off, set by the devbox) adds a separate key-based `deploy` user (wheel, passwordless sudo, nix trusted, keys from `hinteros.dev.deployKeys`) and a build warning; with it off, evaluation fails on any wheel member besides the admin, NOPASSWD rule or extra trusted user. The session user is unprivileged in dev too.
- `maintenance.nix`: `hinteros.maintenance.*`. Boot counting uses NixOS' native
  `boot.loader.systemd-boot.bootCounting`; `hinteros-boot-health` gates `boot-complete.target`
  on the daemon and launcher, so a broken generation falls back by itself. Off by default
  (needs systemd-boot); on for the devbox. GC keeps the last `keepGenerations` (5) system
  generations (and boot entries), `nix.optimise`, and `hinteros-disk-check` logs a warning
  (identifier `hinteros-disk-check`, priority 4) below `diskCheck.minFreeGiB`.

## Runtime settings wiring (session API 0.7)

- `pactl` (`pkgs.pulseaudio`) is set as `[audio] pactl` by absolute path; the user manager provides `XDG_RUNTIME_DIR`, which is how it finds `pipewire-pulse`.
- BlueZ: this BlueZ's `bluetooth.conf` lets every local user call org.bluez (older ones: `at_console`/group `lp`). `runtime.nix` installs `hinteros-bluez.conf` (after BlueZ's): org.bluez is denied by default and allowed for the session user (root is allowed by BlueZ's own policy). The `runtime-settings` test checks both sides with `busctl`.
- gamescope (real devices, no `-W/-H/-r`): the session command and the daemon unit run through `hinteros.session.displayEnvWrapper`, which sets `GAMESCOPE_PATCHED_EDID_FILE=$XDG_RUNTIME_DIR/gamescope-edid` (gamescope writes `<file>.modes`) and `GAMESCOPE_MODE_SAVE_FILE=$XDG_STATE_HOME/hinteros/gamescope-modes` (`~/.local/state/hinteros/gamescope-modes`, persistent, picked by gamescope at its next start). The daemon reads the same variables. The headless VM test keeps its explicit `-W/-H` through `gamescope.extraArgs`.
