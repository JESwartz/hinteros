# M4 couch checklist: TV apps

Exit criterion: log in to and watch Jellyfin, Plex, YouTube and Crunchyroll using only a
controller. Deploy the dev box (`nixos-rebuild switch --flake .#devbox --target-host deploy@<box> --sudo`), no
keyboard attached. Needs network, a Jellyfin server and accounts for Plex, YouTube (optional) and
Crunchyroll.

The daemon is on session API 0.4: controller-to-key translation (`input = "keyboard"` in `nixos/modules/apps.nix`) and the on-screen keyboard (OSK, `hinteros.daemon.osk`) are on by default.

## Home screen

- [ ] The launcher lists Jellyfin, Plex (dev box only), YouTube and Firefox, plus Crunchyroll once installed from the Store, each with its generated letter icon.
- [ ] `/dev/uinput` is usable by the session user (`id` shows `uinput`; the daemon logs no uinput error).
- [ ] Guide+Y (hold Guide, press Y) summons the OSK over any app without taking focus; it shows over Firefox and Jellyfin, d-pad/A/B drive it, Guide or Home hides it. Record: its size and position at 4K and 1080p, and any flicker.
- [ ] Home now fires on Guide *release* (so a Guide+Y chord does not go Home): a plain tap of Guide still goes Home promptly; holding Guide and pressing Y does not. Record: any lag felt.
- [ ] Typing through the OSK reaches the focused field: a URL and a password with symbols (`@ ! ? : = -`), plus one non-US character (goes through gamescope's input method).
- [ ] gamescope version: `hinteros.session.gamescope.reviewedVersion` matches the running one (evaluation fails otherwise).

## Jellyfin (`jellyfin-desktop`)

- [ ] Starts under gamescope and fills the screen. Record: Qt platform (Wayland or xcb; see `QT_QPA_PLATFORM` if it misbehaves).
- [ ] Enter the server address and log in with the on-screen keyboard (OSK) only. Record: dropped or doubled keys.
- [ ] Play a movie (H.264/HEVC): picture, sound over HDMI, seek and pause with the pad. Record: hardware decoding (`intel_gpu_top` or mpv stats).
- [ ] Back/Guide behaviour: Home returns to the launcher, relaunching resumes the running app.

## Plex HTPC (dev box)

- [ ] Starts; the sign-in (plex.tv/link code or login) works with the pad and OSK.
- [ ] Play something; fullscreen, controller navigation works. Record: any need for a keyboard or mouse.
- [ ] `nix path-info` of the system shows plex-htpc is only in the local store (never copy it to a cache).

## YouTube (Firefox kiosk, TV UI)

- [ ] Opens `youtube.com/tv` (the leanback TV UI, not the desktop site). Record: if Google served the desktop UI, the User-Agent in `apps.nix` needs changing.
- [ ] Sign in with the TV code flow (youtube.com/activate on a phone) or the OSK.
- [ ] D-pad navigates, A selects, B goes back (Escape; if YouTube TV ignores it, set `hinteros.apps.youtube.backKey = "backspace"` and re-test); play a video, seek, pause, quit back to the launcher.
- [ ] Fallback: `hinteros.apps.youtube.backend = "vacuumtube"` starts VacuumTube instead and works the same way.

## Crunchyroll (Firefox kiosk)

- [ ] Opens crunchyroll.com in kiosk mode without a first-run or default-browser prompt.
- [ ] Log in using the OSK (password masked in the page); no "save password" prompt appears.
- [ ] DRM playback: an episode plays (Widevine downloads into the profile on first use; may take a minute). Record: seconds to first frame, resolution reached.
- [ ] Hardware decoding on (`about:support` in the plain Firefox app shows VA-API/RDD, or CPU load stays low).
- [ ] Navigate and exit with the pad only.

## Firefox

- [ ] Opens fullscreen; type a URL with the OSK; browse; the profile is separate from the kiosk apps.

## Smoke checks for every release

YouTube TV and Widevine in Firefox on Linux break from time to time. Re-run the YouTube and
Crunchyroll DRM items before each release.

## Result

Record the verdicts (Jellyfin Qt platform, UA accepted, DRM resolution) in `hinteros-docs`.
