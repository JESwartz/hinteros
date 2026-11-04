# Translates a device's state.json (see hinteros-docs/design/device-config.md) into
# hinteros.* and NixOS options. This is the only place that reads the state. A bad value of a
# field it knows fails evaluation, so mistakes surface at build time, before a switch. A field it
# does not know is ignored: a box that moves to an older channel has to evaluate the newer
# state.json. For the same reason a value a later release may add (a box feature or service id
# its catalog does not have, a clean-up frequency, a keep count above 10, a zone its tzdata does
# not have) only warns and is left out (or the default is used); a value of the wrong type or
# form still fails. A change that is not safe to ignore bumps schemaVersion.
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

  # An object field of the wrong type is reported below and read as absent here.
  objectOr = d: v: if builtins.isAttrs v then v else d;
  settings = objectOr { } (state.settings or { });
  ssh = objectOr { } (settings.ssh or { });
  admin = objectOr null (settings.admin or null);
  guest = objectOr { } (settings.guest or { });
  notObject = v: v != null && !builtins.isAttrs v;
  # The admin account: the installer's rules (hinteros-install, admin.user).
  adminUser = admin.user or null;
  adminUserOk =
    builtins.isString adminUser && builtins.match "[a-z_][a-z0-9_-]{0,31}" adminUser != null;
  adminUserReserved =
    adminUserOk
    && (
      lib.elem adminUser [
        "root"
        "hinteros"
        "hinteros-guest"
        "hinteros-greeter"
        "hinteros-kbd"
        "nobody"
        "deploy"
        "sshd"
        "daemon"
        "nixbld"
      ]
      || builtins.match "(systemd-|nixbld|hinteros-p[0-9]).*" adminUser != null
    );
  # The installer's rule; NixOS takes no dots in networking.hostName either.
  hostname = settings.hostname or null;
  hostnameOk =
    builtins.isString hostname && builtins.match "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?" hostname != null;
  # The automatic clean-up (storage.md). Absent fields: today's policy (maintenance.nix defaults).
  cleanup = settings.cleanup or { };
  cleanupFrequencies = [
    "daily"
    "weekly"
    "monthly"
  ];
  # Above 10 (a later release's limit): 10, with a warning.
  maxKeep = 10;
  keepOk = n: builtins.isInt n && n >= 1;
  cleanupOk = {
    enable = builtins.isBool (cleanup.enable or true);
    frequency = builtins.isString (cleanup.frequency or "weekly");
    keepSystem = keepOk (cleanup.keepSystem or 5);
    keepProfiles = keepOk (cleanup.keepProfiles or 5);
  };
  # A frequency a later release adds: the default, with a warning.
  frequencyKnown = lib.elem (cleanup.frequency or "weekly") cleanupFrequencies;
  # The time zone (time-zone.md): a zone name of tzdata, e.g. "America/Chicago"; absent means
  # UTC. time-zone.nix applies it from the live state.json at activation, not from here (a zone
  # this tzdata does not have: UTC).
  timeZone = settings.timeZone or null;
  tz = import ../lib/time-zone.nix { inherit pkgs; };
  disk = state.disk or null;
  # A bad value is reported below; the disk options still need a string.
  diskUuid = v: if builtins.isString v then v else "invalid";
  profiles = listOr (state.profiles or null);
  # Elements that are not strings are reported below and left out here.
  requirements = lib.filter builtins.isString (listOr (state.requirements or null));
  services = lib.filter builtins.isString (listOr (state.services or null));
  allStrings = v: lib.all builtins.isString (listOr v);
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
    ++ lib.optional (!allStrings (state.requirements or null)) "requirements must be strings"
    ++ lib.optional (!allStrings (state.services or null)) "services must be strings"
    ++ lib.concatMap (n: lib.optional (notObject (state.${n} or null)) "${n} must be an object") [
      "settings"
      "disk"
    ]
    ++
      lib.concatMap
        (n: lib.optional (notObject (settings.${n} or null)) "settings.${n} must be an object")
        [
          "ssh"
          "admin"
          "guest"
        ]
    ++ lib.optional (ssh ? enable && !builtins.isBool ssh.enable) "settings.ssh.enable must be a bool"
    ++ lib.optional (
      guest ? enable && !builtins.isBool guest.enable
    ) "settings.guest.enable must be a bool"
    ++
      lib.optional (hostname != null && !hostnameOk)
        "settings.hostname must be 1 to 63 lowercase letters, digits or hyphens, not starting or ending with a hyphen, not ${builtins.toJSON hostname}"
    ++ (
      if builtins.isAttrs cleanup then
        lib.optional (!cleanupOk.enable) "settings.cleanup.enable must be a bool"
        ++ lib.optional (
          !cleanupOk.frequency
        ) "settings.cleanup.frequency must be a string, not ${builtins.toJSON cleanup.frequency}"
        ++
          lib.optional (!cleanupOk.keepSystem)
            "settings.cleanup.keepSystem must be a whole number from 1, not ${builtins.toJSON cleanup.keepSystem}"
        ++
          lib.optional (!cleanupOk.keepProfiles)
            "settings.cleanup.keepProfiles must be a whole number from 1, not ${builtins.toJSON cleanup.keepProfiles}"
      else
        [ "settings.cleanup must be an object" ]
    )
    ++
      lib.optional (timeZone != null && !tz.wellFormed timeZone)
        "settings.timeZone must be a time zone name of tzdata (e.g. \"Europe/Berlin\" or \"UTC\"), not ${builtins.toJSON timeZone}"
    ++ lib.optional (admin != null && !(admin ? user)) "settings.admin needs a user"
    ++
      lib.optional (admin ? user && !adminUserOk)
        "settings.admin.user must be 1 to 32 lowercase letters, digits, - or _, starting with a letter or _, not ${builtins.toJSON adminUser}"
    ++ lib.optional adminUserReserved "settings.admin.user ${adminUser} is reserved"
    ++
      lib.optional (disk != null && (disk.layout or null) != diskLayout)
        "unsupported disk.layout ${builtins.toJSON (disk.layout or null)} (supported: ${diskLayout})"
    ++ lib.optional (
      disk != null && !builtins.isString (disk.rootUuid or null)
    ) "disk.rootUuid must be a string"
    ++ lib.optional (
      disk != null && !builtins.isString (disk.espUuid or null)
    ) "disk.espUuid must be a string"
    ++ profileProblems;

  # Values a later release may add: left out (or the default), with a warning.
  notices =
    lib.optional (unknownFeatures != [ ])
      "unknown box feature(s) in requirements, left out: ${lib.concatStringsSep ", " unknownFeatures} (known: ${lib.concatStringsSep ", " cfg.knownBoxFeatures})"
    ++
      lib.optional (unknownServices != [ ])
        "unknown service id(s), left out: ${lib.concatStringsSep ", " unknownServices} (known: ${lib.concatStringsSep ", " serviceIds})"
    ++ lib.optionals (builtins.isAttrs cleanup) (
      lib.optional (cleanupOk.frequency && !frequencyKnown)
        "unknown settings.cleanup.frequency ${builtins.toJSON cleanup.frequency}, using weekly (known: ${lib.concatStringsSep ", " cleanupFrequencies})"
      ++
        lib.concatMap
          (
            k:
            lib.optional (cleanupOk.${k} && cleanup.${k} or 0 > maxKeep)
              "settings.cleanup.${k} ${toString cleanup.${k}} is above ${toString maxKeep}, using ${toString maxKeep}"
          )
          [
            "keepSystem"
            "keepProfiles"
          ]
    )
    ++ lib.optional (
      tz.wellFormed timeZone && !tz.ok timeZone
    ) "unknown settings.timeZone ${builtins.toJSON timeZone} (not in this tzdata), using UTC";

  # A bad value is reported above and read as absent here.
  boolOr = d: v: if builtins.isBool v then v else d;
  sshEnable = boolOr false (ssh.enable or false);
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
        warnings = map (m: "hinteros state: ${m}") notices;

        hinteros = {
          # The accounts (profiles.nix makes one Unix user each).
          profiles.accounts = accounts;
          profiles.guest.enable = boolOr true (guest.enable or true);

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
          (lib.mkIf (cleanup ? frequency && cleanupOk.frequency && frequencyKnown) {
            gc.dates = cleanup.frequency;
          })
          (lib.mkIf (cleanup ? keepSystem && cleanupOk.keepSystem) {
            keepGenerations = lib.min maxKeep cleanup.keepSystem;
          })
          (lib.mkIf (cleanup ? keepProfiles && cleanupOk.keepProfiles) {
            keepProfileGenerations = lib.min maxKeep cleanup.keepProfiles;
          })
        ];
      })

      (lib.mkIf (state ? stateVersion) { system.stateVersion = state.stateVersion; })
      (lib.mkIf hostnameOk { networking.hostName = lib.mkDefault hostname; })

      # The admin account (hardening.nix). Its password hash is a root-only file written by the
      # installer (and later the first-boot wizard); it is never part of state.json or the store.
      # (A bad user name is reported above; no account is made from it.)
      (lib.mkIf (adminUserOk && !adminUserReserved) {
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
