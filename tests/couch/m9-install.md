# M9 couch checklist: installer (backend and ISO)

The installer screens do not exist yet; this checks the backend and the ISO on the first
hardware test, driven from the console. Exit criterion (full M9): install a blank mini PC from USB
with only a controller. Here: install a blank Intel mini PC from USB, keyboard allowed for the
installer console only, then run the box with the controller alone.

Needs: a USB stick (8 GB+), the mini PC (UEFI, Secure Boot off, internal disk you can erase), a
second machine to build the ISO. An Ethernet cable for the online part; a Wi-Fi network for the Wi-Fi part.

## Build and boot

- [ ] `nix build .#iso` from a clean commit of the system repo succeeds. Record: ISO size (`ls -lh result/iso/`), build time.
- [ ] `sudo dd if=result/iso/hinteros-installer.iso of=/dev/sdX bs=4M conv=fsync status=progress` (check the device with `lsblk`).
- [ ] The mini PC boots the stick in UEFI mode (boot menu key, pick the UEFI entry). Record: time to the console, any boot menu or Secure Boot complaint, whether the display and the keyboard work.
- [ ] The console shows the HinterOS installer notice (not an installer UI: none is wired yet) and `hinteros-install` is on the PATH.
- [ ] `lsblk -o PATH,DISK-SEQ,MODEL,SIZE` shows the internal disk; note its by-id path (`ls -l /dev/disk/by-id/`) and its `DISK-SEQ` (`diskSeq` in the plan).

## Refusals (nothing may be touched)

- [ ] `sudo hinteros-install --plan plan.json --validate-only` with a good plan ends with a `done` line and changes nothing.
- [ ] A plan without `admin.password` is refused (`admin-password-missing`, exit status 2).
- [ ] A plan naming the USB stick as `disk` is refused (`disk-in-use`).
- [ ] With the network cable out, a plan with `steam` is refused (`app-needs-network`); the same plan with `youtube` and `firefox` only is accepted.

## Offline install (cable out, no Wi-Fi)

- [ ] `plan.json`: the internal disk and its `diskSeq`, `hostname`, an admin user and password, `ssh.enable` true, `apps` `["youtube","firefox"]`.
- [ ] `sudo hinteros-install --plan plan.json` runs to `done` (100%). Record: total time, the progress lines look sensible (stage and percent only go forward), warnings (`facter-failed`?).
- [ ] `/var/log/hinteros-install.log` has no network errors (no attempts to fetch from cache.nixos.org or the Forgejo).
- [ ] Remove the stick, reboot: the box boots from the internal disk (systemd-boot, no menu needed), reaches the launcher with a controller attached. Record: boot time.
- [ ] The launcher lists YouTube and Firefox only (Jellyfin and Steam are offered but unticked; Crunchyroll, Moonlight and Plex are Store-only).
- [ ] From another machine: `ssh <admin>@<host>` with the plan's password works; the same for `hinteros` and `root` fails. `sudo` asks for the admin password.
- [ ] `ls /etc/hinteros` shows `flake.nix flake.lock state.json facter.json`; `state.json` has the apps, ssh and admin user but no password; `/var/lib/hinteros/admin-password-hash` is `0600 root`.
- [ ] `diff -r /etc/hinteros /run/current-system/hinteros` shows only `facter.json` as extra.
- [ ] `lsblk -f`: a 1 GiB vfat ESP (`hinteros-esp`) and an ext4 root (`hinteros-root`) filling the rest.
- [ ] `nix flake metadata path:/etc/hinteros` works offline (the lock resolves from the store).

## Online install (cable in), second pass

- [ ] Reinstall with `apps` `["youtube","firefox","steam"]` (Moonlight and Plex are Store apps now). The installer detects the network (`Online install` line) and downloads only the extra apps. Record: download size and time.
- [ ] Steam appears in the launcher; Steam starts (first start downloads its bootstrap).
- [ ] `nix flake update hinteros` on the box (online) moves `hinteros` to the `stable` or `beta` branch, then the Settings rebuild path (or `sudo nixos-rebuild switch --flake path:/etc/hinteros#hinteros`) works. Record: whether the branch exists yet.
- [ ] Wi-Fi: a plan with `wifi` `{ssid, psk}` and no cable connects (`Online install`), and the installed box is on the same Wi-Fi at first boot.

## Failure handling

- [ ] Pull the USB stick or power the box off in the middle of an install, then run the install again from the stick: it recovers (the disk is repartitioned from scratch).
- [ ] An install on a disk with an existing OS wipes it completely; no old boot entry survives in the firmware boot menu that boots into the old system.

## Record

Hardware, firmware version, ISO revision, installer log (`/var/log/hinteros-install.log`), any step that needed a keyboard that the final installer UI must cover.
