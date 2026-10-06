# Couch checklist: M0 spikes (hardware part)

Run on the dev box (mini PC #1) on the TV, with no keyboard attached once the session is up.
For every item record **pass/fail + notes** (and the TV, resolution and pad used).
Covers spike 1 (Flutter under gamescope), spike 3 (Steam and the launcher together),
spike 4 (InputPlumber) and spike 5 (on-screen keyboard). Background: `hinteros-docs/spikes/`.

## 0. Deploy to the dev box

1. Put your SSH public key in `devices/devbox/state.json` (`settings.ssh.authorizedKeys`).
   Never commit keys that are not yours.
2. First install: NixOS from any ISO on the box, then copy its
   `hardware-configuration.nix` ideas into `devices/devbox/hardware.nix`
   (the `fileSystems` entries there are placeholders). Generate the facter report on the box
   with `nixos-facter -o facter.json` and pass it as `facterReport` in `devices/devbox/default.nix` (M1).
3. Deploy from the desktop (the session user `hinteros` is the deploy user on the dev box):
   `nixos-rebuild switch --flake .#devbox --target-host hinteros@<box> --sudo`
   (older nixos-rebuild: `--use-remote-sudo`). Undo a bad deploy with
   `ssh hinteros@<box> sudo nixos-rebuild switch --rollback` or pick the previous generation at boot.
4. Debug env for the launcher: `hinteros.session.environment.HINTEROS_FPS = "1";` in
   `devices/devbox/hardware.nix` (frame-rate overlay) and redeploy, or for one run
   `ssh` in and start the session by hand. `GDK_BACKEND=wayland` is already the default on gamescope.
5. The session daemon starts Steam with `-silent` (`steam.autostart` in `devices/devbox/hardware.nix`; never under a reaper). Log in to Steam once (pad-driven terminal or Remote Play) and install 2 small games (one native, one Proton). Daemon log: `journalctl --user -u hinteros-session` as the session user; its config is the store path in the unit's `ExecStart` (`--config`).

## 1. Spike 1: launcher under gamescope (HINTEROS_FPS=1)

- [ ] 1080p and 4K on the TV: picture fills the screen, no border or offset; at 4K the layout looks like 1080p, just sharper. Record: resolutions tried.
- [ ] Hold Right/Left on the card row for 1 min: no tearing, no stutter; overlay ~60 fps, worst frame under ~12 ms. Record: fps and worst frame.
- [ ] 120 and 30 Hz modes, if the TV offers them: still smooth. Record: modes.
- [ ] 1080p app on a 4K output (`gamescope.extraArgs = [ "-w" "1920" "-h" "1080" "-W" "3840" "-H" "2160" ]`; try `-F fsr`): acceptable. Record: sharpness.
- [ ] Cold boot to the launcher: no window frame flash, black screen at most a couple of seconds. Record: seconds.
- [ ] Compare `GDK_BACKEND=x11` once. Record: differences.

## 2. Spike 4: input layer (InputPlumber)

- [ ] USB Xbox pad, Bluetooth Xbox/PS pad, DualSense over USB: each becomes a composite device after boot and after hotplug (`busctl tree org.shadowblip.InputPlumber`). Record: pads tried.
- [ ] Two pads at once: both routed, Home from either works.
- [ ] Hot-unplug and replug mid-game; `systemctl restart inputplumber` mid-game; sleep and resume. Record: what recovers by itself.
- [ ] DualSense: Steam lists only the virtual pad; gyro works in a game via the `ds5` target.

## 3. Spike 3: Steam with the launcher

Needs `steam -silent` running, and the launcher as the home app.

- [ ] Launcher focused: Steam shows one controller (the virtual one) and no game or Steam UI reacts to presses.
- [ ] Launch a game with `steam steam://rungameid/<id>` (SSH, or the daemon once wired). Record: seconds to first frame.
- [ ] In the game, input arrives exactly once; a Steam Input remap for that game applies once, not twice.
- [ ] Press Home in the game: the launcher appears, the game and Steam see no Guide press. Return to the game and repeat 10 times: focus returns every time. Record: failures.
- [ ] No double input in either direction: the launcher does not move while in a game, the game does not react while the launcher is focused.
- [ ] Home screen: choose Steam (Big Picture): `apps.launch {id: steam}` shows Big Picture as gamescope app 769, with the pad working in it; Home returns to the launcher; closing it from the launcher (`apps.close steam`) ends Big Picture, not Steam. Record: which Steam command worked (`steam://open/bigpicture` or `-gamepadui`).
- [ ] Steam attention: trigger a Steam Guard prompt or an update dialog while the launcher has focus. The launcher shows its "Steam needs your attention" banner (`steam_attention`); accepting it (`steam.focus`) shows the dialog, usable with the pad; closing the dialog returns to the launcher. Record: window titles the daemon reported.
- [ ] Steam pop-ups (a notification, an update dialog, the Steam keyboard) can be surfaced and dismissed with the pad. Record: which ones tried.
- [ ] Quit the game from inside it: back in the launcher, Steam still running.

## 4. Spike 5: on-screen keyboard

- [ ] With the pad only, type a URL (`https://example.com`) into Firefox's address bar via the on-screen keyboard. Record: how the keyboard was summoned, errors.
- [ ] Type a password into a login form field (it must be masked in the page and legible on the keyboard). Record: length typed, any dropped or doubled keys.
- [ ] Dismiss the keyboard and return to the launcher with Home.

## Result

Record the verdicts back in the spike notes (`hinteros-docs/spikes/`), including the decisions
(Flutter vs. fallback, input layer, Guide-chord policy).
