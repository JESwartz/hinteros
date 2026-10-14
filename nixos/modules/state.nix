# Translates a device's state.json (see hinteros-docs/design/device-config.md) into
# hinteros.* and NixOS options. This is the only place that reads the state. Anything it
# does not know fails evaluation, so mistakes surface at build time, before a switch.
#
# Two schemas are supported side by side (apps.md, "Migration and M7 build plan"):
#   - schema 1 (pre-M7): `apps` are box-wide (`hinteros.apps`, session.toml `[[apps]]`), and
#     `profiles` is `[]` (the installer, every pre-M7 box) or the one session user.
#   - schema 2 (M7): `profiles` are the accounts `{id, user}`, `requirements` the box features,
#     `services` the catalog services; there are no `apps`: each profile has its own Nix profile
#     of apps (app-env.nix). hinteros-system migrates a schema-1 box to schema 2 itself.
{
  config,
  lib,
  ...
}:
let
  cfg = config.hinteros;
  inherit (cfg) state;

  supportedSchemaVersions = [
    1
    2
  ];
  schema = state.schemaVersion or null;
  v2 = schema == 2;

  # Catalog ids (hinteros-catalog), tombstoned ones included: a state may still list them, and
  # they do nothing.
  catalog = cfg.catalog.entries;
  isKind = k: e: (e.kind or "app") == k;
  appIds = builtins.attrNames (lib.filterAttrs (_: isKind "app") catalog);
  liveAppIds = builtins.attrNames (
    lib.filterAttrs (_: e: isKind "app" e && e.status != "removed") catalog
  );
  serviceIds = builtins.attrNames (
    lib.filterAttrs (_: e: isKind "service" e && e.status != "removed") catalog
  );

  # Fail on keys outside `known`, naming the path.
  checkKeys =
    path: known: attrs:
    let
      unknown = lib.subtractLists known (builtins.attrNames attrs);
    in
    lib.optional (unknown != [ ]) "unknown field(s) in ${path}: ${lib.concatStringsSep ", " unknown}";

  # The one disk layout there is: GPT, 1 GiB ESP + ext4 root, found by partition label (disk.nix).
  # The installer creates it (nixos/pkgs/hinteros-install); the field names it so another layout
  # can be added without breaking old states.
  diskLayout = "gpt-esp-ext4";

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
  disk = state.disk or null;
  apps = state.apps or [ ];
  profiles = state.profiles or [ ];
  requirements = state.requirements or [ ];
  services = state.services or [ ];
  unknownApps = lib.filter (a: !(lib.elem a appIds)) apps;
  unknownFeatures = lib.filter (f: !(lib.elem f cfg.knownBoxFeatures)) requirements;
  unknownServices = lib.filter (s: !(lib.elem s serviceIds)) services;

  # Accounts (profiles.md, "Declarative accounts"): `p1` is `hinteros`, `p<N>` is `hinteros-p<N>`.
  idOk = id: builtins.isString id && builtins.match "p[1-9][0-9]{0,2}" id != null;
  userFor = id: if id == "p1" then "hinteros" else "hinteros-${id}";
  profileProblems =
    if v2 then
      let
        ids = map (p: p.id or null) profiles;
      in
      lib.optional (
        !(builtins.isList profiles) || profiles == [ ] || builtins.length profiles > 8
      ) "profiles: 1 to 8 accounts"
      ++ lib.concatMap (
        p:
        checkKeys "profiles[]" [ "id" "user" ] p
        ++ lib.optional (!idOk (p.id or null)) "profiles[]: bad id ${builtins.toJSON (p.id or null)}"
        ++ lib.optional (
          idOk (p.id or null) && (p.user or null) != userFor p.id
        ) "profiles[]: ${p.id} must be user ${userFor p.id}, not ${builtins.toJSON (p.user or null)}"
      ) profiles
      ++ lib.optional (lib.unique ids != ids) "profiles: duplicate ids"
    else
      lib.concatMap (
        p:
        checkKeys "profiles[]" [
          "id"
          "name"
          "user"
        ] p
      ) profiles;

  # Schema 1's `profiles: []` is p1 = `hinteros`; otherwise its first entry is the session user.
  accounts =
    if v2 then
      # Invalid entries are reported above and left out here.
      map (p: { inherit (p) id user; }) (
        lib.filter (p: idOk (p.id or null) && (p.user or null) == userFor p.id) profiles
      )
    else if profiles == [ ] then
      [
        {
          id = "p1";
          user = "hinteros";
        }
      ]
    else
      [
        {
          id = (builtins.head profiles).id or "p1";
          user = (builtins.head profiles).user or "hinteros";
        }
      ];

  problems =
    lib.optional (!(lib.elem schema supportedSchemaVersions))
      "unsupported schemaVersion ${builtins.toJSON schema} (supported: ${
        lib.concatMapStringsSep ", " toString supportedSchemaVersions
      })"
    ++ checkKeys "state" (
      [
        "schemaVersion"
        "base"
        "stateVersion"
        "settings"
        "disk"
        "profiles"
      ]
      ++ (
        if v2 then
          [
            "requirements"
            "services"
          ]
        else
          [ "apps" ]
      )
    ) state
    ++ checkKeys "settings" (
      [
        "ssh"
        "hostname"
        "admin"
        "cleanup"
      ]
      ++ lib.optional v2 "guest"
    ) settings
    ++ checkKeys "settings.ssh" [ "enable" ] ssh
    ++ lib.optionals v2 (checkKeys "settings.guest" [ "enable" ] guest)
    ++ lib.optional (
      v2 && guest ? enable && !builtins.isBool guest.enable
    ) "settings.guest.enable must be a bool"
    ++ (
      if builtins.isAttrs cleanup then
        checkKeys "settings.cleanup" [ "enable" "frequency" "keepSystem" "keepProfiles" ] cleanup
        ++ lib.optional (!cleanupOk.enable) "settings.cleanup.enable must be a bool"
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
    ++ lib.optionals (admin != null) (
      checkKeys "settings.admin" [ "user" ] admin
      ++ lib.optional (!(admin ? user)) "settings.admin needs a user"
    )
    ++ lib.optionals (disk != null) (
      checkKeys "disk" [ "layout" ] disk
      ++
        lib.optional ((disk.layout or null) != diskLayout)
          "unsupported disk.layout ${builtins.toJSON (disk.layout or null)} (supported: ${diskLayout})"
    )
    ++
      lib.optional (unknownApps != [ ])
        "unknown app id(s): ${lib.concatStringsSep ", " unknownApps} (known: ${lib.concatStringsSep ", " appIds})"
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

        # The accounts (profiles.nix makes one Unix user each). Schema 1: one, the session user.
        hinteros.profiles.accounts = accounts;

        # sshd on/off. Opt-in; the admin account is the only login (see hardening.nix).
        hinteros.ssh.enable = sshEnable;
      }

      # Schema 1: the box-wide apps are exactly the selected catalog ids. mkOverride 900 beats the
      # catalog's mkDefault (the `onIso` apps on) and loses to a device's own `enable = true`.
      # Schema 2: none (apps are per profile).
      {
        hinteros.apps = lib.genAttrs liveAppIds (id: {
          enable = lib.mkOverride 900 (!v2 && builtins.elem id apps);
        });
      }

      (lib.mkIf v2 {
        hinteros = {
          appEnv.perProfile = true;
          boxFeatures = lib.filter (f: lib.elem f cfg.knownBoxFeatures) requirements;
          catalog.services = lib.filter (s: lib.elem s serviceIds) services;
          profiles.guest.enable = guest.enable or true;
        };
      })

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

      (lib.mkIf (disk != null) { hinteros.disk.enable = true; })
    ]
  );
}
