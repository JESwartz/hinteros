# NixOS

- `modules/`: the HinterOS NixOS modules, exported by the flake as `nixosModules`.
  - `session.nix`: greetd autologin into gamescope running the home app.
    Options: `hinteros.session.enable`, `.user` (default `hinteros`), `.compositor`
    (`gamescope` or `cage`), `.environment`, `.homeApp`
    (package, default `pkgs.hinteros-launcher`; `pkgs.hinteros-placeholder-home` is kept for debugging), `.gamescope.package`, `.gamescope.extraArgs`, `.gamescope.reviewedVersion`. The compositor gets `XKB_DEFAULT_LAYOUT=us` (the daemon types US key codes). The gamescope version is pinned: the daemon vendors gamescope's private `gamescope_input_method` protocol (3.16.31), so evaluation fails with another version until `reviewedVersion` is updated after re-checking the daemon's protocol XML.
    `.launcherAppId` (4100000000) and `.reaperPackage`: under gamescope (always `-e`, Steam mode) the home app runs as
    `hinteros-session reaper SteamLaunch AppId=<id> -- hinteros-home`, so gamescope gives its windows the launcher app id.
    `hinteros-home` (the compositor's one child, also under cage) runs the home app that
    `/run/current-system/hinteros-console/home` points to, and again whenever it exits with 75: a
    switch restarts the session daemon but not the session, so the launcher exits with 75 when the
    new daemon refuses its API version or comes back after a restart and the system has another
    launcher (launcher `lib/src/system/home_relaunch.dart`); the new one starts in the same
    gamescope (no black screen, the running session survives). Any other exit ends the session as
    before. greetd runs `/run/current-system/hinteros-console/session`, so a new session
    (`session.restart`, a crash) also gets the current system's compositor and home app (greetd
    keeps the config it was started with: nixpkgs never restarts it on a switch).
    The daemon user unit retries until gamescope's Xwayland (`:0`) is up. `.gamescope.backend` (`drm`, `headless`, `wayland`, `sdl`; default: gamescope chooses).
    `.cursor.*` (gamescope only): the pointer never fades on inactivity (`--hide-cursor-delay` `.hideDelayMs`, a day; the session daemon hides it on the D-pad and on the way Home with `gamescopectl paint_cursor_plane`) and is large on a TV (`--cursor-scale-height` `.scaleHeight`, 540: gamescope's 36 px base times floor(output height / 540), 72 px at 1080p; `null` keeps the apps' size). The home app and the daemon's apps get `XCURSOR_THEME` (`.theme`, Adwaita from `.package`), `XCURSOR_PATH` and `XCURSOR_SIZE` (256 with scaling, as gamescope gives its own children; else `.size`).
  - `input.nix`: `hinteros.input.enable` (default: the session is enabled). InputPlumber with polkit,
    the session user in group `inputplumber` and its udev rules. `ManageAllDevices` is set by the session daemon. The overlay patches InputPlumber 0.81.0: `CompositeDevice.SendEvent` (the daemon's RT click) used `blocking_send` inside its tokio runtime, panicked and never answered (`nixos/pkgs/inputplumber/`; `input-layer` checks the click).
  - `daemon.nix`: `hinteros.daemon.enable`, `.group` (default `hinteros`), `.session.package`,
    `.system.package`, `.osk.{enable,package,summon}` (the on-screen keyboard, `hinteros-osk` from the launcher package; `[osk]` in session.toml; default chord Guide+Y), `.input.keyboardHome` (default on: Ctrl+Super+D on a keyboard is Home. No profile account can read a keyboard: the system unit `hinteros-keyboard` (`hinteros-system keyboard-home`, a dynamic user in groups `input` and `hinteros-keyboard`, keyboards read-only, never grabbed, no network or capabilities) reports each press on `/run/hinteros/keyboard.sock` (root:hinteros-keyboard 0660), and hinteros-system sends `keyboard_home` to the session daemon of the active seat0 session; `[input] keyboard_home`), `.logLevel`. A systemd user service `hinteros-session` for the session user
    (socket `$XDG_RUNTIME_DIR/hinteros/session.sock`, started with `--config` of a `session.toml` generated from
    `.session.settings`, a TOML-format attrset; defaults: `launcher.app_id`, `gamescope.*` (disabled on cage, where `wayland_display` is `wayland-0` and the user unit gets `DISPLAY=:0`), `osk.*`, `steam.path`) and a root system service `hinteros-system`
    (`/run/hinteros/system.sock`, 0660, group `hinteros`, which the session user joins; run with `--freeze-inactive`: a profile whose session is not the active one, after `chvt 2` or at another session, is frozen with systemd's cgroup freezer until its session is in front again, so a device fd it opened before the switch, such as `/dev/uinput`, cannot reach the admin console). What the system service
    needs (hinteros-daemon README, "What the system module must provide"): `hinteros-system.service` with `RuntimeDirectoryPreserve=yes`,
    `StateDirectory=hinteros` (0700), `ProtectSystem=strict` + `ReadWritePaths=/run/hinteros`, `MemoryDenyWriteExecute`,
    `SystemCallFilter=@system-service`, `AF_UNIX` only and `CapabilityBoundingSet=CAP_SYS_PTRACE` (audit reads `/proc/<pid>/exe`);
    the template `hinteros-job@.service` (root, network, no `ProtectSystem`, `ExecStart=hinteros-system job %i`, PATH with nix, git, openssh,
    nixos-facter, `restartIfChanged = stopIfChanged = false` so the switch a job performs never restarts it); the polkit actions
    `org.hinteros.system.{settings,rebuild,update.check,update.apply,rollback,channel,jobs.cancel}` (default no) and `.ssh` (`auth_admin`)
    in `share/polkit-1/actions/org.hinteros.system.policy`, and `/etc/polkit-1/rules.d/50-hinteros.rules` granting all but `.ssh` to the `hinteros` group;
    both daemon packages and `hinteros-bootstrap-channel` (`pkgs/hinteros-bootstrap-channel`: `sudo hinteros-bootstrap-channel <stable|beta> <rev>` moves a box onto a channel at a signed rev outside the update UI, verifying it against the running generation's keys, or with a typed `yes` when it has none, then locking, building and switching like `update.apply`) in `systemPackages`; and the per-generation files in `sw/share/hinteros/`: `release.json` (`{version, dev}`;
    `hinteros.release.version`), `update/channels.json` (`hinteros.update.repo`, branches `stable`/`beta`; the device flake's input line
    `git+<repo>?ref=<branch>` is generated from the same option by the installer) and `update/allowed_signers` from
    `hinteros.update.allowedSigners` (a list of `"<principal> ssh-ed25519 <key>"`, written in ssh-keygen format with `namespaces="git"`).
    `allowedSigners` is empty by default; `nixosModules.default` fills it from the repo's `release/allowed_signers` (`release.nix`, below). With none,
    every update and channel check fails closed (git finds no matching principal, the daemon reports `update_verification_failed`/`unknown_signer`).
  - `state.nix`: `hinteros.state` (set by `lib.mkDevice`) is the decoded state.json; it asserts `schemaVersion` 1, rejects unknown fields and app ids, and maps `settings.ssh`, `settings.hostname`, `settings.cleanup` (maintenance.nix), `settings.timeZone` (checked only: a zone of tzdata; time-zone.nix applies it at activation), `settings.admin` (admin account, hash file `/var/lib/hinteros/admin-password-hash`), `stateVersion`, `disk` (`disk.nix`), `apps` (a state enables exactly the listed default apps; ids in `lib/app-ids.nix`) and the first profile's user (TODO M7: one user per profile).
  - `release.nix` (in `nixosModules.default` only, not in `modules/default.nix`): sets `hinteros.release.version`, `hinteros.update.allowedSigners` and `hinteros.cache.publicKeys` from `release/{version,allowed_signers,cache-keys}` with `mkDefault`; comment lines are skipped. `cache.nix`: `hinteros.cache.{enable,url,publicKeys}`, off (no cache yet); when on, an extra substituter at priority 50 after cache.nixos.org.
  - `disk.nix`: `hinteros.disk.enable` (state.json `disk`): the installer layout, ESP + ext4 root by partition label `hinteros-esp`/`hinteros-root`, systemd-boot, zram.
- `installer/`: `default.nix` (installer environment: `hinteros-install`, disko, offline closure and lock following `hinteros.installer.channel` (default `stable`), `hinteros.installer.ui.command` hook) and `iso.nix` (installation-cd base); `pkgs/hinteros-install`, `templates/device-flake.nix.in`. See the repo README, "Installer".
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
by OCR of `gamescopectl screenshot` that the game, then (after SIGUSR1) the placeholder again, is shown, and that Ctrl+Super+D on the VM keyboard is Home too (read by `hinteros-keyboard`, which the session user cannot do; Ctrl+D is not). The Flutter launcher stays on cage in VM tests (spike 2).
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
  Skips when `/etc/hinteros` or the snapshot is missing. It keeps the live `state.json`
  `settings.timeZone` (set without a rebuild); state.json is compared as JSON. `configDir` must be a plain path (a flake
  source), not a derivation output, because the module reads it at eval time.
- `time-zone.nix` (time-zone.md): `time.timeZone = null`; the activation snippet
  `hinteros-time-zone` (after `etc`) points `/etc/localtime` at `/etc/zoneinfo/<zone>` from the
  live `/etc/hinteros/state.json` `settings.timeZone` (UTC when absent or not a zone of tzdata;
  the name rule is `nixos/lib/time-zone.nix`, shared with state.nix), replacing the link with a
  rename and only when it differs. `time_zone.set` changes both at once through the oneshot
  `hinteros-time-zone-apply` (daemon.nix; root, `ReadWritePaths` /etc and /run/hinteros, no
  network), so hinteros-system itself never writes /etc.
- `runtime.nix`: `hinteros.runtime.{enable,network,bluetooth,audio,power}`, on with the session.
  NetworkManager (no VPN plugins), BlueZ (`Experimental`, `UserspaceHID`, `ClassicBondedOnly`
  stays true), PipeWire/WirePlumber, logind (power key suspends, lid ignored), and polkit rules
  scoped to the session user's active local session: suspend/reboot/power-off and the Wi-Fi
  actions. `settings.modify.system` is granted (accepted: the session user can read Wi-Fi PSKs; see the module comment and threat-model.md).

- `hardening.nix`: on with the session (threat-model.md). Session user never in `wheel`, `trusted-users = ["root"]`, `allowed-users = ["root"]`, no sudo (`security.sudo.enable` only with `hinteros.admin` or dev), polkit admin identities = root + the admin, persistent capped journal, `systemd-boot.editor = false` (set only here). `hinteros.admin.{enable,user,hashedPasswordFile}`: optional admin account (wheel, sudo always asks its password, password file required, never committed; the M9 wizard sets it). `hinteros.ssh.enable` (from state.json `settings.ssh.enable`, off by default) runs sshd with username + password, `PermitRootLogin no`, `AllowUsers` = the admin only (never the session user), and requires `hinteros.admin`; the polkit action `org.hinteros.system.ssh` (`auth_admin`, defined in `daemon.nix`) is what the privileged service checks before flipping it (the session user gets `authentication_required`). Key-only SSH, key import, a LAN-only firewall and rate limiting are backlog. `hinteros.dev.enable` (default off, set by the devbox) adds a separate key-based `deploy` user (wheel, passwordless sudo, nix trusted, keys from `hinteros.dev.deployKeys`) and a build warning; with it off, evaluation fails on any wheel member besides the admin, NOPASSWD rule or extra trusted user. The session user is unprivileged in dev too.
- `maintenance.nix`: `hinteros.maintenance.*`. Boot counting uses NixOS' native
  `boot.loader.systemd-boot.bootCounting`; `hinteros-boot-health` gates `boot-complete.target`
  on the daemon and launcher, so a broken generation falls back by itself. On for every installed box
  (mkDevice enables it wherever systemd-boot is on); not in VMs or on the ISO. The automatic
  clean-up (state.json `settings.cleanup`, storage.md) is NixOS' `nix-gc` timer at `gc.dates`
  (`frequency`: `daily`, `weekly`, `monthly`; default weekly, persistent) running
  `hinteros-cleanup --system <keepGenerations> --profiles <keepProfileGenerations>`: it trims the
  system profile to the newest `keepGenerations` (`keepSystem`, default 5; the current, running
  and booted generations always stay), every app profile
  (`/nix/var/nix/profiles/hinteros/{apps/<user>,starter}`) to the newest
  `keepProfileGenerations` (`keepProfiles`, default 5; the current one always stays), then runs
  `nix-collect-garbage`, all under the flock `cleanupLock` (`/run/lock/hinteros-cleanup.lock`),
  so two never overlap. The daemon's manual clean-up jobs (their own trim, boot menu rewrite and
  `nix-store --gc`) are serialised with it by Nix's profile and GC locks; they may also take
  `cleanupLock` or run `cleanupPackage`. The timer rewrites no boot entry: entries are the newest
  `configurationLimit` (= `keepGenerations`) generations of the last rebuild, which its trim
  keeps. `gc.enable` (`enable`) off: no timer. systemd-boot's
  `configurationLimit` follows `keepGenerations` either way. Also `nix.optimise`, and
  `hinteros-disk-check` logs a warning (identifier `hinteros-disk-check`, priority 4) below
  `diskCheck.minFreeGiB`.

## Runtime settings wiring (session API 0.7)

- `pactl` (`pkgs.pulseaudio`) is set as `[audio] pactl` by absolute path; the user manager provides `XDG_RUNTIME_DIR`, which is how it finds `pipewire-pulse`.
- BlueZ: this BlueZ's `bluetooth.conf` lets every local user call org.bluez (older ones: `at_console`/group `lp`). `runtime.nix` installs `hinteros-bluez.conf` (after BlueZ's): org.bluez is denied by default and allowed for the session user (root is allowed by BlueZ's own policy). The `runtime-settings` test checks both sides with `busctl`.
- gamescope (real devices, no `-W/-H/-r`, see "Display size"): the session command and the daemon unit run through `hinteros.session.displayEnvWrapper`, which sets `GAMESCOPE_PATCHED_EDID_FILE=$XDG_RUNTIME_DIR/gamescope-edid` (gamescope writes `<file>.modes`) and `GAMESCOPE_MODE_SAVE_FILE=$XDG_STATE_HOME/hinteros/gamescope-modes` (`~/.local/state/hinteros/gamescope-modes`, persistent, picked by gamescope at its next start). Before gamescope starts, the wrapper copies the box-wide mode (`/run/hinteros/gamescope-modes`, from hinteros-system's runtime.json) over that file, so every profile, the guest and the picker start in the same mode and a switch never changes the TV's mode. The daemon reads the same variables. The headless VM test keeps its explicit `-W/-H` through `gamescope.extraArgs`.

## Profiles, the greeter and PINs (M7)

- `profiles.nix`: one Unix user per profile account (`hinteros`, `hinteros-p<N>`), the guest, and
  greeter mode (on with state.json schema 2): greetd runs the picker as `hinteros-greeter`; the
  `greetd` PAM stack enforces PINs and the kill on switch through `hinteros-system pin
  unlocked|verify|end-others` (pam_exec, as root). A profile without a PIN is entered without
  one, even when it is locked.
- **Handover splash**: both session stacks first run `pin splash` (`optional`; the helper always
  exits 0): it paints greetd's VT (`PAM_TTY`) with console escape sequences in the launcher's
  colours and a centred "Loading <name>…" ("HinterOS" on the way back to the picker), which is
  what the TV shows between the picker's last frame and the session's first (~2 s). The console
  font is Terminus 16x32 (`console.font = "ter-v32b"`, legible on a TV); the quiet boot keeps the
  kernel console at log level 3 (`branding.nix`), so kernel messages do not write over it.
- **Nothing greetd runs writes to the VT**: greetd connects a session's stdout/stderr to it. The
  greeter command, the picker and the profile session all start under `systemd-cat`
  (`journalctl -t hinteros-greeter`, `-t hinteros-compositor`, `-t hinteros-session-start`).
- **Forgotten PIN**: the person who set up the box removes it as root from a terminal (SSH as the
  admin account, or a console):

  ```sh
  sudo hinteros-system reset-pin            # lists the profiles with their ids
  sudo hinteros-system reset-pin Sam        # or: reset-pin p2
  ```

  It removes the PIN and the wrong-PIN wait (under the same lock the checks use), writes an audit
  entry (`journalctl HINTEROS_METHOD=reset-pin`) and updates the picker's view. The profile then
  opens from the picker without a PIN and its launcher asks for a new one ("Set your PIN").
  `hinteros-system` is in `environment.systemPackages` (`daemon.nix`), so it is on the admin's
  and root's PATH. There is no on-screen recovery for a forgotten PIN; the launcher's PIN pads
  only point to this command.
