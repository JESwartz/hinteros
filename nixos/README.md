# NixOS

- `modules/`: the HinterOS NixOS modules, exported by the flake as `nixosModules`.
  - `session.nix`: greetd autologin into gamescope running the home app.
    Options: `hinteros.session.enable`, `.user` (default `hinteros`), `.compositor`
    (`gamescope` or `cage`), `.environment`, `.homeApp`
    (package, default `pkgs.hinteros-launcher`; `pkgs.hinteros-placeholder-home` is kept for debugging), `.gamescope.package`, `.gamescope.extraArgs`.
    `.launcherAppId` (4100000000) and `.reaperPackage`: under gamescope (always `-e`, Steam mode) the home app runs as
    `hinteros-session reaper SteamLaunch AppId=<id> -- <home app>`, so gamescope gives its windows the launcher app id.
    The daemon user unit retries until gamescope's Xwayland (`:0`) is up. `.gamescope.backend` (`drm`, `headless`, `wayland`, `sdl`; default: gamescope chooses).
  - `input.nix`: `hinteros.input.enable` (default: the session is enabled). InputPlumber with polkit,
    the session user in group `inputplumber` and its udev rules. `ManageAllDevices` is set by the session daemon.
  - `daemon.nix`: `hinteros.daemon.enable`, `.group` (default `hinteros`), `.session.package`,
    `.system.package`, `.logLevel`. A systemd user service `hinteros-session` for the session user
    (socket `$XDG_RUNTIME_DIR/hinteros/session.sock`, started with `--config` of a `session.toml` generated from
    `.session.settings`, a TOML-format attrset; defaults: `launcher.app_id`, `gamescope.*` (disabled on cage), `steam.path`) and a root system service `hinteros-system`
    (`/run/hinteros/system.sock`, 0660, group `hinteros`, which the session user joins).
  - `state.nix`: `hinteros.state` (set by `lib.mkDevice`) is the decoded state.json; it asserts `schemaVersion` 1, rejects unknown fields and app ids, and maps `settings.ssh`, `apps` and the first profile's user (TODO M7: one user per profile).
  - `fake-steam.nix`: `hinteros.fakeSteam.enable` (tests only) installs the stub `steam` and a fake Steam home for the session user (`libraryfolders.vdf`, 3 games and 3 tools that `games.list` filters out, `librarycache` artwork) and points the daemon at it with `steam.dir`.
  - `apps.nix`: the app registry. `hinteros.apps.<id>` = { `enable`, `name`, `order`, `kind`, `package`, `command`, `kiosk.{url,userAgent,fullscreenOnly}`, `icon`, `unfreeName`, `input`, `backKey`, `backend` } becomes the daemon's `[[apps]]` (id, name, kind, icon, command) and installs the package. Defaults, enabled with the session: `jellyfin` (`pkgs.jellyfin-desktop`, the successor of jellyfin-media-player), `youtube` (Firefox kiosk at youtube.com/tv with a PlayStation 5 User-Agent, only for its profile; `hinteros.apps.youtube.backend = "vacuumtube"` switches to `pkgs.vacuum-tube`), `crunchyroll` (kiosk), `firefox` (plain, no `--kiosk`, fullscreen by the compositor). `plex` (`pkgs.plex-htpc`, unfree) exists but is off; the dev box enables it. Icons are generated at build time with ImageMagick: a coloured square and a letter, no logos. `input` (`gamepad`/`keyboard`) and `backKey` are written to session.toml (`input`, `back_key`) only with `hinteros.daemon.session.emitInputKeys = true`, because the daemon at API 0.3 rejects unknown `[[apps]]` keys (TODO: flip once the daemon input is bumped to API 0.4).
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
`GAMESCOPECTRL_BASELAYER_APPID` with xprop, uses the session socket (API 0.3) for `games.list`, a fake Steam game, `apps.close`, Big Picture and a fake Steam Guard pop-up (`steam_attention`, `steam.focus`), and checks
by OCR of `gamescopectl screenshot` that the game, then (after SIGUSR1) the placeholder again, is shown. The Flutter launcher stays on cage in VM tests (spike 2).
`nixosConfigurations.vm-gamescope` is the interactive VM with gamescope for a Vulkan-capable setup.
On gamescope the launcher runs on native Wayland (`GDK_BACKEND=wayland`, `--expose-wayland`).
