# Translates a device's state.json (see hinteros-docs/design/device-config.md) into
# hinteros.* and NixOS options. This is the only place that reads the state. Anything it
# does not know fails evaluation, so mistakes surface at build time, before a switch.
{
  config,
  lib,
  ...
}:
let
  cfg = config.hinteros;
  inherit (cfg) state;

  supportedSchemaVersion = 1;

  appIds = import ../lib/app-ids.nix;

  # Catalog app id -> NixOS config. The App Store (M8) replaces this.
  knownApps = {
    steam = {
      programs.steam.enable = true;
      # Steam is unfree: allow exactly the Steam packages. Never put the result in a binary
      # cache or an ISO (Steam and Plex licences forbid redistribution).
      hinteros.unfreeAllowlist = [
        "steam"
        "steam-unwrapped"
        "steam-original"
        "steam-run"
      ];
    };
    # Plex HTPC and Moonlight are registry apps (apps.nix); the id only switches them on.
    plex-htpc.hinteros.apps.plex.enable = true;
    moonlight.hinteros.apps.moonlight.enable = true;
  }
  // lib.genAttrs appIds.onIso (_: { });
  # The default apps (appIds.onIso) are enabled by apps.nix whenever the session is; a device
  # with a state selects them: only the listed ones are on (see the mkOverride below).

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
  disk = state.disk or null;
  apps = state.apps or [ ];
  profiles = state.profiles or [ ];
  unknownApps = lib.filter (a: !(knownApps ? ${a})) apps;

  problems =
    lib.optional ((state.schemaVersion or null) != supportedSchemaVersion)
      "unsupported schemaVersion ${
        builtins.toJSON (state.schemaVersion or null)
      } (supported: ${toString supportedSchemaVersion})"
    ++ checkKeys "state" [
      "schemaVersion"
      "base"
      "stateVersion"
      "settings"
      "disk"
      "apps"
      "profiles"
    ] state
    ++ checkKeys "settings" [
      "ssh"
      "hostname"
      "admin"
    ] settings
    ++ checkKeys "settings.ssh" [ "enable" ] ssh
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
    ++ lib.optional (
      lib.sort lib.lessThan appIds.all != builtins.attrNames knownApps
    ) "internal: nixos/lib/app-ids.nix and knownApps disagree"
    ++
      lib.optional (unknownApps != [ ])
        "unknown app id(s): ${lib.concatStringsSep ", " unknownApps} (known: ${lib.concatStringsSep ", " (builtins.attrNames knownApps)})"
    ++ lib.concatMap (
      p:
      checkKeys "profiles[]" [
        "id"
        "name"
        "user"
      ] p
    ) profiles;

  sshEnable = ssh.enable or false;
in
{
  imports = [ ./unfree.nix ];

  options.hinteros.state = lib.mkOption {
    type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
    default = null;
    description = "Decoded state.json of the device. Set by `hinteros.lib.mkDevice`.";
  };

  config = lib.mkIf (state != null) (
    lib.mkMerge (
      [
        {
          assertions = map (message: {
            assertion = false;
            inherit message;
          }) (map (m: "hinteros state: ${m}") problems);

          # TODO(M7): one Linux user per profile; for now only the first profile's user
          # owns the session.
          hinteros.session.user = lib.mkIf (profiles != [ ]) (lib.mkDefault (builtins.head profiles).user);

          # sshd on/off. Opt-in; the admin account is the only login (see hardening.nix).
          hinteros.ssh.enable = sshEnable;
        }

        # The default apps are exactly the selected ones. mkOverride 900 beats apps.nix's
        # mkDefault and loses to a device's own `enable = true`.
        {
          hinteros.apps = lib.genAttrs appIds.onIso (id: {
            enable = lib.mkOverride 900 (builtins.elem id apps);
          });
        }

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
      # One mkIf per known app keeps the list itself independent of the state.
      ++ lib.mapAttrsToList (id: appConfig: lib.mkIf (builtins.elem id apps) appConfig) knownApps
    )
  );
}
