# Eval-level test of the ISO's own configuration (the real nixosConfigurations.installer, which
# the VM tests do not boot): sshd is off, the stock installation-device text is gone, the console
# notice is HinterOS-specific, the filesystems for a log stick are supported, and NIC settings are
# in. Nothing is built.
{ self, pkgs }:
let
  c = self.nixosConfigurations.installer.config;
  inherit (pkgs) lib;
  has = needle: hay: lib.hasInfix needle hay;
  results = lib.filter (r: r != null) (
    lib.mapAttrsToList (n: ok: if ok then null else n) {
      sshdOff = !c.services.openssh.enable;
      noEmptyPasswordText = !(has "empty passwords" c.services.getty.helpLine);
      noSshText = !(has "ssh" (lib.toLower c.services.getty.helpLine));
      motdDiagnose = has "hinteros-diagnose" c.users.motd && has "hinteros-save-log" c.users.motd;
      motdNoStaleText = !(has "No installer screen is running yet" c.users.motd);
      motdNoStockText = !(has "empty passwords" c.users.motd);
      exfat = c.boot.supportedFilesystems.exfat or false;
      ntfs = c.boot.supportedFilesystems.ntfs or false;
      wifiPowersaveOff = c.networking.networkmanager.wifi.powersave == false;
      wiredEeeOff =
        c.networking.networkmanager.ensureProfiles.profiles.hinteros-wired.ethtool.eee-enabled == "0";
      firmware = c.hardware.enableRedistributableFirmware;
      # The installer offers exactly YouTube, Jellyfin, Firefox and Steam; YouTube and Firefox are
      # pre-selected; Crunchyroll, Moonlight and Plex are Store-only.
      installerApps =
        let
          ids = import ../../nixos/lib/app-ids.nix c.hinteros.catalog.entries;
        in
        lib.sort (a: b: a < b) ids.all == [
          "firefox"
          "jellyfin"
          "steam"
          "youtube"
        ]
        &&
          lib.sort (a: b: a < b) ids.preselected == [
            "firefox"
            "youtube"
          ]
        &&
          lib.sort (a: b: a < b) ids.onIso == [
            "firefox"
            "jellyfin"
            "youtube"
          ];
      # The UI's stderr (the launcher's hinteros-focus: lines) reaches the journal, so it is in
      # `journalctl` and in hinteros-save-log's journal.txt.
      uiLogsToJournal =
        (c.systemd.services.cage-tty1.serviceConfig.StandardError or "") == "journal"
        && (c.systemd.services.cage-tty1.serviceConfig.StandardOutput or "") == "journal";
    }
  );
in
pkgs.runCommand "hinteros-installer-iso-eval" { } (
  if results == [ ] then "touch $out" else "echo 'failed: ${toString results}' >&2; exit 1"
)
