# HinterOS release notes

Newest first. Changes since the last stable release go under `## Unreleased` on top: `promote`
puts that section into the release commit's message, which is what a box shows as the update's
notes, and `promote stable` renames it to the version the promoter picks. Start a new
`## Unreleased` section after merging a stable release into `main`. Keep each section short and
written for the person using the box.

## Unreleased

## 1.0.1

HinterOS 1.0, the first release for everyone: a controller-driven console and smart TV system
for a PC under the TV. Download the installer and read how to install at https://hinteros.org.

- Home screen for the controller: Home, Games, Apps and Settings, with short, plain on-screen
  text. The Guide button goes home. On-screen keyboard and a stick-driven pointer for apps that
  need one.
- Profiles: everyone gets their own profile with its own apps, Steam account, settings and an
  optional PIN. A Guest profile starts fresh every time. A profile that is not on screen is
  paused.
- Apps: Steam, YouTube, Jellyfin, Plex, Firefox, VacuumTube and more from the Store. Store apps
  run in a sandbox and use the controller, the microphone, Downloads or the local network only
  with your permission. Each app runs on its own display.
- Servers: the box can run a Jellyfin server, a Plex Media Server, Tailscale and Cloudflare
  Tunnel. Put your media in /srv/media; HinterOS sets up Jellyfin and signs the Jellyfin app in.
- Settings: Profiles, Updates, Storage, Network, Display and sound, Accessibility and System.
  Wi-Fi, Bluetooth controllers, sound output, resolution, time zone and the screen saver apply
  at once. Settings → Storage shows what uses the disk and cleans up old versions.
- Updates: signed releases on the `stable` and `beta` channels. The box checks for updates and
  tells you; it never updates on its own. Every update is a new version of the system that you
  can roll back, and the box goes back to the previous version by itself if a new one does not
  start. Security updates show a notice until you install them.
- Installer on a USB stick: Internet, Admin account, Options, Apps, Disk and Summary, all with
  the controller. It works offline for the default apps. Keep data repairs an installed box and
  keeps its profiles, homes and settings. Erase all needs a 5-second button hold.
- Hardware video decoding on Intel GPUs, sound on the TV by default, and support for Xbox and
  other Bluetooth controllers.
- Security: the admin PIN protects updates and system settings, apps cannot read the keyboard
  or each other, SSH (off by default) accepts only local networks, and the firewall is on.

Known limits: only the `unstable` nixpkgs base. The box shows on one display at a time.

Releases before 1.0 were internal pre-releases. Their notes follow for reference.

## 0.7.0

The first signed release: the first build of HinterOS meant to be installed on a box and kept
up to date. (0.6.0 was prepared but never released; everything in it is here.)

- Profiles: everyone in the household gets their own profile with its own apps, Steam account,
  settings and an optional PIN; a Guest profile that starts fresh every time (End guest session
  removes everything the guest did at once); a profile picker at start and "Switch profile"
  that keeps the current profile running. A forgotten PIN is reset by the box's administrator
  from the console (`sudo hinteros-system reset-pin`).
- The admin profile's PIN is needed to install an update, roll back, and change the update
  channel or the software base.
- First-time setup on the TV: controllers, network, display resolution and your profile.
- Games added to Steam as non-Steam games show up in the Games library and under Continue.
- Smoother screen changes: a loading screen with a spinner when a profile starts, and no
  blank screen or TV signal drop between the start screen, the profile picker and a profile.
- Controller-driven home screen (the HinterOS launcher on gamescope) with Home, Games, Apps and
  Settings. Press the Guide button to go home; hold it to open Steam's menu in Steam or a Steam
  game. Short, plain on-screen text.
- Apps from the HinterOS catalog: YouTube, Jellyfin and Firefox in a TV-friendly kiosk, Steam,
  and streaming services from the App Store, installed per profile without rebuilding the system.
- On-screen keyboard (Guide+Y, or A on a text field), including the Firefox address bar, and a
  stick-driven pointer for apps that need one.
- Settings that apply without a rebuild: Wi-Fi and wired network, Bluetooth, sound output,
  display mode and power.
- Installer on a USB stick: works offline for the default apps, offers a newer HinterOS from
  its channel when it is online, erases the disk only after a 5-second button hold, writes a
  hardware report, and can save its log to a second stick; `hinteros-diagnose` for network and
  hardware problems.
- Safety nets: every update and settings change is a new system generation with its own copy of
  the box's settings, rollback from Settings (which keeps what your apps need), and automatic
  fallback to the previous generation if a new one fails to start.
- Updates are signed: the box only installs a channel tip signed with a HinterOS release key it
  already trusts, and never updates on its own.

Known limits: only the `unstable` nixpkgs base exists, there is no HinterOS binary cache yet (an
update downloads from cache.nixos.org and builds the rest on the box), and a box installed before
this release must be moved onto its channel once with `hinteros-bootstrap-channel`.

