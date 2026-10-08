# NixOS

- `modules/`: the HinterOS NixOS modules, exported by the flake as `nixosModules`.
  - `session.nix`: greetd autologin into gamescope running the home app.
    Options: `hinteros.session.enable`, `.user` (default `hinteros`), `.compositor`
    (`gamescope` or `cage`), `.environment`, `.homeApp`
    (package, default `pkgs.hinteros-launcher`; `pkgs.hinteros-placeholder-home` is kept for debugging), `.gamescope.package`, `.gamescope.extraArgs`, `.gamescope.reviewedVersion`. The compositor gets `XKB_DEFAULT_LAYOUT=us` (the daemon types US key codes). The gamescope version is pinned: the daemon vendors gamescope's private `gamescope_input_method` protocol (3.16.31), so evaluation fails with another version until `reviewedVersion` is updated after re-checking the daemon's protocol XML.
    `.launcherAppId` (4100000000) and `.reaperPackage`: under gamescope (always `-e`, Steam mode) the home app runs as
    `hinteros-session reaper SteamLaunch AppId=<id> -- <home app>`, so gamescope gives its windows the launcher app id.
    The daemon user unit retries until gamescope's Xwayland (`:0`) is up. `.gamescope.backend` (`drm`, `headless`, `wayland`, `sdl`; default: gamescope chooses).
    `.cursor.*` (gamescope only): the pointer never fades on inactivity (`--hide-cursor-delay` `.hideDelayMs`, a day; the session daemon hides it on the D-pad and on the way Home with `gamescopectl paint_cursor_plane`) and is large on a TV (`--cursor-scale-height` `.scaleHeight`, 540: gamescope's 36 px base times floor(output height / 540), 72 px at 1080p; `null` keeps the apps' size). The home app and the daemon's apps get `XCURSOR_THEME` (`.theme`, Adwaita from `.package`), `XCURSOR_PATH` and `XCURSOR_SIZE` (256 with scaling, as gamescope gives its own children; else `.size`).
  - `input.nix`: `hinteros.input.enable` (default: the session is enabled). InputPlumber with polkit,
    the session user in group `inputplumber` and its udev rules. `ManageAllDevices` is set by the session daemon. The overlay patches InputPlumber 0.81.0: `CompositeDevice.SendEvent` (the daemon's RT click) used `blocking_send` inside its tokio runtime, panicked and never answered (`nixos/pkgs/inputplumber/`; `input-layer` checks the click).
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
  - `catalog.nix`: the App Store catalog (flake input `hinteros-catalog`, design/catalog.md) as the source of apps. A function of the catalog data (`entries`, `cacheableUnfree`, `index`), imported through flake.nix's keyed `catalogModule`; it sets `hinteros.apps.<id>` for every entry (the entry's `app` settings as `mkDefault` leaves, `name`, `listed`, the icon fields `desktopId`/`iconUrl`/`siteUrl`/`firefoxProfile`; `enable` defaults to the `onIso` apps with the session), applies the entry's restricted `nixos` module while the app is enabled, derives `hinteros.unfreeAllowlist` from the enabled entries' `license.unfreePackages`, turns on `hardware.graphics.enable32Bit` for `requires = [ "graphics32" ]`, and installs the index and vendor terms (`share/hinteros/catalog.json`, `share/hinteros/terms/`). Tombstoned (`removed`) ids are known to state.json and do nothing. `hinteros.catalog.{entries,cacheableUnfree,index}` re-export the data.
  - `apps.nix`: the app registry options. `hinteros.apps.<id>` = { `enable`, `name`, `order`, `kind`, `listed`, `package`, `command`, `kiosk.{url,userAgent,fullscreenOnly}`, `icon`, `desktopId`, `iconUrl`, `siteUrl`, `firefoxProfile`, `input`, `backKey` } becomes the daemon's `[[apps]]` (id, name, kind, command, input, back_key and `desktop_id`/`icon_url`/`site_url`/`firefox_profile`; the daemon finds the real icons at runtime, nothing generated) and installs the package. Apps that only add system config (Steam) are not listed: the daemon's built-in `steam` tile is theirs. `input` (`gamepad`/`keyboard`) and `backKey` come from the catalog entries; override single settings with `hinteros.apps.<id>.*` (e.g. `backKey = "backspace"`).
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
On gamescope the launcher runs on Xwayland (`GDK_BACKEND=x11`); see "Display size" below.

The `typing` test (cage, loopback only) runs Firefox on a page with a text and a password field;
over the session socket (API 0.7) it calls `keys.type` with a URL, `keys.action tab`, `keys.type`
with `P@ss-w0rd!` and `keys.action enter`, and checks that the page received exactly those values
through the daemon's uinput keyboard. It also checks that the daemon started `hinteros-osk`, that
the OSK connected at 0.7 and that `osk.show`/`osk.hide` answer.

## Display size (gamescope)

Real hardware (Skylake iGPU, 1920x1080 HDMI) showed the launcher as a blurry ~1080x1080 square in
the middle of a correct 1920x1080 output. From the gamescope 3.16.31 source:

- **Native Wayland windows are never sized.** gamescope's xdg-shell handling sends configures
  without a size and ignores `set_fullscreen` (`wlserver.cpp`: `xdg_toplevel_new` is empty, nothing
  calls `wlr_xdg_toplevel_set_size`/`_set_fullscreen`). The client's buffer is then aspect-fitted to
  the output with a linear filter (`steamcompmgr.cpp`, `calc_scale_factor`, scaler `auto`). The
  GTK launcher's fullscreen request was ignored, so it stayed at its tiny natural size and was
  upscaled. **Fix:** under gamescope GTK apps run on Xwayland (`GDK_BACKEND=x11` for the session and
  the daemon, which starts the OSK and native apps), the path Steam uses. Cage keeps Wayland (it
  honors fullscreen). Costs (spike 1): slightly less steady frame times, no automatic 2x at 4K (the
  launcher scales its 1080p layout to the window itself).
- **X11 windows**: gamescope resizes a mapped window to the Xwayland root unless it pins its size
  with min = max hints; a focused window with an app id only if it is fullscreen
  (`_NET_WM_STATE_FULLSCREEN`). `--force-windows-fullscreen` makes every focused app window
  root-sized.
- **Root/nested size**: without `-w/-h` the nested size is the output mode found at start
  (`main.cpp`), 1280x720 if no display was connected yet (`drm_unset_mode`). With one Xwayland
  that size never changes: a later `display.set_mode` or a TV switched on after boot leaves apps
  letterboxed or upscaled, and the `wl_output` the daemon reads as the "current mode" keeps the
  start size, so `display.set_mode` never saw its switch ("gamescope did not switch"). **Fix:**
  `--xwayland-count 2`: gamescope then sizes Xwayland `:0` (home app, every app the daemon starts)
  and its `wl_output` to the output at start and on every mode change, and keeps the nested aspect
  equal to the output's (`steamcompmgr.cpp`, `wlserver_set_xwayland_server_mode(0, ...)`). `:1`
  (`STEAM_GAME_DISPLAY_0`) keeps the nested size; nothing of ours uses it. No `-W/-H/-w/-h` are
  passed, so gamescope keeps choosing the mode (save file) and `display.set_mode` stays live.

gamescope's and the home app's stdout/stderr are in the journal: `journalctl -t hinteros-compositor`
(`wlserver: Updating mode for xwayland server #0: WxH@R` after each mode change). The
`gamescope-size` test covers this (headless, so no live mode change; `gamescopectl screenshot`
repaints at the nested size).

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
  on the daemon and launcher, so a broken generation falls back by itself. On for every installed box
  (mkDevice enables it wherever systemd-boot is on); not in VMs or on the ISO. GC keeps the last `keepGenerations` (5) system
  generations (and boot entries), `nix.optimise`, and `hinteros-disk-check` logs a warning
  (identifier `hinteros-disk-check`, priority 4) below `diskCheck.minFreeGiB`.

## Runtime settings wiring (session API 0.7)

- `pactl` (`pkgs.pulseaudio`) is set as `[audio] pactl` by absolute path; the user manager provides `XDG_RUNTIME_DIR`, which is how it finds `pipewire-pulse`.
- BlueZ: this BlueZ's `bluetooth.conf` lets every local user call org.bluez (older ones: `at_console`/group `lp`). `runtime.nix` installs `hinteros-bluez.conf` (after BlueZ's): org.bluez is denied by default and allowed for the session user (root is allowed by BlueZ's own policy). The `runtime-settings` test checks both sides with `busctl`.
- gamescope (real devices, no `-W/-H/-r`, see "Display size"): the session command and the daemon unit run through `hinteros.session.displayEnvWrapper`, which sets `GAMESCOPE_PATCHED_EDID_FILE=$XDG_RUNTIME_DIR/gamescope-edid` (gamescope writes `<file>.modes`) and `GAMESCOPE_MODE_SAVE_FILE=$XDG_STATE_HOME/hinteros/gamescope-modes` (`~/.local/state/hinteros/gamescope-modes`, persistent, picked by gamescope at its next start). The daemon reads the same variables. The headless VM test keeps its explicit `-W/-H` through `gamescope.extraArgs`.
