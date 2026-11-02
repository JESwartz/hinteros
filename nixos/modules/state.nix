# Translates a device's state.json (see hinteros-docs/design/device-config.md) into
# hinteros.* and NixOS options. This is the only place that reads the state. A bad value of a
# field it knows fails evaluation, so mistakes surface at build time, before a switch. A field it
# does not know is ignored: a box that moves to an older channel has to evaluate the newer
# state.json. A change that is not safe to ignore bumps schemaVersion.
#
# `profiles` are the accounts `{id}`, `requirements` the box features, `services` the catalog
# services; each profile has its own Nix profile of apps (app-env.nix).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hinteros;
  inherit (cfg) state;

  schema = state.schemaVersion or null;
  listOr = v: if builtins.isList v then v else [ ];

  serviceIds = builtins.attrNames (
    lib.filterAttrs (_: e: (e.kind or "app") == "service" && e.status != "removed") cfg.catalog.entries
  );

  # The one disk layout there is: GPT, 1 GiB ESP + btrfs subvolumes, found by UUID (disk.nix). The
  # installer creates it (nixos/pkgs/hinteros-install); the field names it so another layout can
  # be added without breaking old states.
  diskLayout = "gpt-esp-btrfs";

  settings = state.settings or { };
  ssh = settings.ssh or { };
  admin = settings.admin or null;
  guest = settings.guest or { };
  # The automatic clean-up (storage.md). Absent fields: today's policy (maintenance.nix defaults).
  cleanup = settings.cleanup or { };
  cleanupFrequencies = [
    "daily"
    "weekly"
    "monthly"
  ];
  keepOk = n: builtins.isInt n && n >= 1 && n <= 10;
  cleanupOk = {
    enable = builtins.isBool (cleanup.enable or true);
    frequency = lib.elem (cleanup.frequency or "weekly") cleanupFrequencies;
    keepSystem = keepOk (cleanup.keepSystem or 5);
    keepProfiles = keepOk (cleanup.keepProfiles or 5);
  };
  # The time zone (time-zone.md): a zone name of tzdata, e.g. "America/Chicago"; absent means
  # UTC. time-zone.nix applies it from the live state.json at activation, not from here.
  timeZone = settings.timeZone or null;
  timeZoneOk = (import ../lib/time-zone.nix { inherit pkgs; }).ok timeZone;
  disk = state.disk or null;
  # A bad value is reported below; the disk options still need a string.
  diskUuid = v: if builtins.isString v then v else "invalid";
  profiles = listOr (state.profiles or null);
  requirements = listOr (state.requirements or null);
  services = listOr (state.services or null);
  unknownFeatures = lib.filter (f: !(lib.elem f cfg.knownBoxFeatures)) requirements;
  unknownServices = lib.filter (s: !(lib.elem s serviceIds)) services;

  # Accounts (profiles.md, "Declarative accounts"): `p<N>` is the Unix user `hinteros-p<N>`.
  idOk = id: builtins.isString id && builtins.match "p[1-9][0-9]{0,2}" id != null;
  ids = map (p: p.id or null) profiles;
  profileProblems =
    lib.optional (profiles == [ ] || builtins.length profiles > 8) "profiles: 1 to 8 accounts"
    ++ lib.concatMap (
      p: lib.optional (!idOk (p.id or null)) "profiles[]: bad id ${builtins.toJSON (p.id or null)}"
    ) profiles
    ++ lib.optional (lib.unique ids != ids) "profiles: duplicate ids";

  # Invalid entries are reported above and left out here.
  accounts = map (p: { inherit (p) id; }) (lib.filter (p: idOk (p.id or null)) profiles);

  problems =
    lib.optional (schema != 2) "unsupported schemaVersion ${builtins.toJSON schema} (supported: 2)"
    ++ lib.optional (!builtins.isString (state.base or null)) "base must be a string"
    ++ lib.optional (!builtins.isString (state.stateVersion or null)) "stateVersion must be a string"
    ++ lib.optional (!builtins.isList (state.requirements or null)) "requirements must be a list"
    ++ lib.optional (!builtins.isList (state.services or null)) "services must be a list"
    ++ lib.optional (
      guest ? enable && !builtins.isBool guest.enable
    ) "settings.guest.enable must be a bool"
    ++ (
      if builtins.isAttrs cleanup then
        lib.optional (!cleanupOk.enable) "settings.cleanup.enable must be a bool"
        ++
          lib.optional (!cleanupOk.frequency)
            "settings.cleanup.frequency must be one of ${lib.concatStringsSep ", " cleanupFrequencies}, not ${builtins.toJSON cleanup.frequency}"
        ++
          lib.optional (!cleanupOk.keepSystem)
            "settings.cleanup.keepSystem must be a whole number from 1 to 10, not ${builtins.toJSON cleanup.keepSystem}"
        ++
          lib.optional (!cleanupOk.keepProfiles)
            "settings.cleanup.keepProfiles must be a whole number from 1 to 10, not ${builtins.toJSON cleanup.keepProfiles}"
      else
        [ "settings.cleanup must be an object" ]
    )
    ++
      lib.optional (timeZone != null && !timeZoneOk)
        "settings.timeZone must be a time zone name of tzdata (e.g. \"Europe/Berlin\" or \"UTC\"), not ${builtins.toJSON timeZone}"
    ++ lib.optional (admin != null && !(admin ? user)) "settings.admin needs a user"
    ++
      lib.optional (disk != null && (disk.layout or null) != diskLayout)
        "unsupported disk.layout ${builtins.toJSON (disk.layout or null)} (supported: ${diskLayout})"
    ++ lib.optional (
      disk != null && !builtins.isString (disk.rootUuid or null)
    ) "disk.rootUuid must be a string"
    ++ lib.optional (
      disk != null && !builtins.isString (disk.espUuid or null)
    ) "disk.espUuid must be a string"
    ++
      lib.optional (unknownFeatures != [ ])
        "unknown box feature(s) in requirements: ${lib.concatStringsSep ", " unknownFeatures} (known: ${lib.concatStringsSep ", " cfg.knownBoxFeatures})"
    ++
      lib.optional (unknownServices != [ ])
        "unknown service id(s): ${lib.concatStringsSep ", " unknownServices} (known: ${lib.concatStringsSep ", " serviceIds})"
    ++ profileProblems;

  sshEnable = ssh.enable or false;
in
{
  imports = [
    ./unfree.nix
    ./box-features.nix
  ];

  options.hinteros.state = lib.mkOption {
    type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
    default = null;
    description = "Decoded state.json of the device. Set by `hinteros.lib.mkDevice`.";
  };

  config = lib.mkIf (state != null) (
    lib.mkMerge [
      {
        assertions = map (message: {
          assertion = false;
          inherit message;
        }) (map (m: "hinteros state: ${m}") problems);

        hinteros = {
          # The accounts (profiles.nix makes one Unix user each).
          profiles.accounts = accounts;
          profiles.guest.enable = guest.enable or true;

          # sshd on/off. Opt-in; the admin account is the only login (see hardening.nix).
          ssh.enable = sshEnable;

          boxFeatures = lib.filter (f: lib.elem f cfg.knownBoxFeatures) requirements;
          catalog.services = lib.filter (s: lib.elem s serviceIds) services;
        };
      }

      # The automatic clean-up (maintenance.nix). A field only when it is valid (the problem
      # above names a bad one); absent fields keep the module defaults, the same policy.
      (lib.mkIf (builtins.isAttrs cleanup) {
        hinteros.maintenance = lib.mkMerge [
          (lib.mkIf (cleanup ? enable && cleanupOk.enable) { gc.enable = cleanup.enable; })
          (lib.mkIf (cleanup ? frequency && cleanupOk.frequency) { gc.dates = cleanup.frequency; })
          (lib.mkIf (cleanup ? keepSystem && cleanupOk.keepSystem) {
            keepGenerations = cleanup.keepSystem;
          })
          (lib.mkIf (cleanup ? keepProfiles && cleanupOk.keepProfiles) {
            keepProfileGenerations = cleanup.keepProfiles;
          })
        ];
      })

      (lib.mkIf (state ? stateVersion) { system.stateVersion = state.stateVersion; })
      (lib.mkIf (settings ? hostname) { networking.hostName = lib.mkDefault settings.hostname; })

      # The admin account (hardening.nix). Its password hash is a root-only file written by the
      # installer (and later the first-boot wizard); it is never part of state.json or the store.
      (lib.mkIf (admin != null) {
        hinteros.admin = {
          enable = true;
          inherit (admin) user;
          hashedPasswordFile = lib.mkDefault "/var/lib/hinteros/admin-password-hash";
        };
      })

      (lib.mkIf (disk != null) {
        hinteros.disk = {
          enable = true;
          rootUuid = diskUuid (disk.rootUuid or null);
          espUuid = diskUuid (disk.espUuid or null);
        };
      })
    ]
  );
}
