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
