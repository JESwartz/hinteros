# HinterOS release notes

Newest first. `promote` puts the top section (the text under the first `## <version>` heading,
which must match `release/version`) into the release commit's message, which is what a box shows
as the update's notes. Keep each section short and written for the person using the box.

## 0.6.0

The first signed release: the first build of HinterOS meant to be installed on a box and kept
up to date.

- Controller-driven home screen (the HinterOS launcher on gamescope) with Home, Games, Apps and
  Settings; the Guide button always brings you back home.
- Apps from the HinterOS catalog: YouTube, Jellyfin and Firefox in a TV-friendly kiosk, Steam,
  and streaming services from the App Store, installed per profile without rebuilding the system.
- On-screen keyboard (Guide+Y, or A on a text field), including the Firefox address bar, and a
  stick-driven pointer for apps that need one.
- Settings that apply without a rebuild: Wi-Fi and wired network, Bluetooth, sound output,
  display mode and power.
- Installer on a USB stick: works offline for the default apps, writes a hardware report, and
  can save its log to a second stick; `hinteros-diagnose` for network and hardware problems.
- Safety nets: every update and settings change is a new system generation with its own copy of
  the box's settings, rollback from Settings, and automatic fallback to the previous generation
  if a new one fails to start.
- Updates are signed: the box only installs a channel tip signed with a HinterOS release key it
  already trusts, and never updates on its own.

Known limits: only the `unstable` nixpkgs base exists, there is no HinterOS binary cache yet (an
update downloads from cache.nixos.org and builds the rest on the box), and a box installed before
this release must be moved onto its channel once with `hinteros-bootstrap-channel`.
