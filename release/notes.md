# HinterOS release notes

Newest first. Changes since the last stable release go under `## Unreleased` on top: `promote`
puts that section into the release commit's message, which is what a box shows as the update's
notes, and `promote stable` renames it to the version the promoter picks. Start a new
`## Unreleased` section after merging a stable release into `main`. Keep each section short and
written for the person using the box.

## Unreleased

- Settings → Storage: a ring shows what uses the disk (the system, apps, each profile and its
  Steam games, Guest, free space). Your own profile opens; another profile needs the admin PIN.
- Clean up the system and clean up profiles, each keeping as many versions as the admin
  chooses; they show what they free first and need the admin PIN.
- Automatic clean-up is a setting: on or off, how often, and how many versions to keep.
- Updates and app installs show what they install, how many parts are built, and the time
  elapsed (mm:ss). Hide the job page and the top bar keeps showing the job.
- When an update needs a session restart, the session restarts after 30 seconds. Choose
  Later to stop it. The count runs only while the launcher is on screen.
- Installer: the system install shows its steps (copy or download the packages, build HinterOS,
  install the boot loader), each with its count and the time elapsed. A wheel turns while the
  install runs.
- Installer: the disk is identified by its disk sequence number. If the disk is replaced
  during setup or the download, the install stops before it erases anything.
- Installer: you can pick VacuumTube and Plex. Fixed: the app list showed Crunchyroll and not
  Steam.
- Settings has seven groups: Profiles, Updates, Storage, Network, Display and sound,
  Accessibility and System.
- The Store describes each app in short words.
- Time zone: pick it in the first-boot setup and in Settings. The list is in UTC offset
  order; the map above it follows the zone you move to. The change applies at once (Settings
  needs the admin PIN).
- Display: the resolution is a drop-down, in Settings and in the first-boot setup.
- Steam games that Steam names with another app id (for example a game with its own
  `steam_appid.txt`) now show at once, also with Steam open, and leave Continue when they end.
- Apps that are not installed no longer show on a new box.
- Keyboard: press Ctrl + Windows + D to go to Home.
- Each beta has its own version (0.7.2, 0.7.3, ...). Stable takes the tested beta's version.
  A box on the 0.7.1 beta shows the first new beta as 0.7.3 until it updates.
- Security: games and apps can no longer read the keyboard. A profile that is not on screen
  is paused until it is back.
- Security: after 10 wrong admin PINs the admin PIN is refused, also the right one, until the
  box restarts.
- Security: a channel switch shows the checked version before you confirm. The box refuses a
  version older than one it already saw for that channel.
- Security: SSH, when on, accepts connections only from local networks. The admin password
  must have 8 or more characters.
- Security: apps from the Store run in a sandbox. Each app sees only its own files, and can
  use the controller, the microphone, Downloads or the local network only with your
  permission. You choose the permissions when you install the app and on the app's page.
- Steam and apps without the sandbox show "has full access" before you install them.
- Each app runs on its own display, so apps can't read or type into each other. Settings →
  System → Apps open at once (default 4) sets how many apps can run. When all are in use,
  HinterOS asks which app to close.
- Security: apps have a system call filter and see only the GPU's render nodes. App packages
  can't change the compositor, the launcher or the daemon. Store icons are checked against a
  pinned hash.
- New in the Store: three OpenRA games: Red Alert, Tiberian Dawn and Dune 2000.
- Sound plays on the TV (HDMI or DisplayPort) by default. Settings → Audio also lists the
  outputs of the sound card's other modes, and picking one switches to it.
- Fixed: a Bluetooth controller showed as connected and did nothing when it was the first
  one after a restart.
- Fixed: on a box without Wi-Fi, Right on Network in Settings did not go to Bluetooth.
- The security notice: Update now works at once. Only Later and Back wait 5 seconds.
- Fixed: a profile without apps after moving to profiles; "another job is running" just after a
  job ended; an offline install with Steam picked.

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

