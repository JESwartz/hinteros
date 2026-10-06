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

  # Catalog app id -> NixOS config. Only Steam exists so far; the App Store (M8) replaces this.
  knownApps = {
    steam = {
      programs.steam.enable = true;
      # Steam is unfree: allow exactly the Steam packages. Never put the result in a binary
      # cache or an ISO (Steam and Plex licences forbid redistribution).
      nixpkgs.config.allowUnfreePredicate =
        pkg:
        builtins.elem (lib.getName pkg) [
          "steam"
          "steam-unwrapped"
          "steam-original"
          "steam-run"
        ];
    };
  };

  # Fail on keys outside `known`, naming the path.
  checkKeys =
    path: known: attrs:
    let
      unknown = lib.subtractLists known (builtins.attrNames attrs);
    in
    lib.optional (unknown != [ ]) "unknown field(s) in ${path}: ${lib.concatStringsSep ", " unknown}";

  settings = state.settings or { };
  ssh = settings.ssh or { };
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
      "settings"
      "apps"
      "profiles"
    ] state
    ++ checkKeys "settings" [ "ssh" ] settings
    ++ checkKeys "settings.ssh" [ "enable" "authorizedKeys" ] ssh
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

          services.openssh = lib.mkIf sshEnable {
            enable = true;
            openFirewall = true;
            # Key-only; opt-in. The firewall stays closed while this is off.
            settings = {
              PasswordAuthentication = false;
              KbdInteractiveAuthentication = false;
              PermitRootLogin = "no";
            };
          };
          users.users.${cfg.session.user}.openssh.authorizedKeys.keys = lib.mkIf sshEnable (
            ssh.authorizedKeys or [ ]
          );
        }
      ]
      # One mkIf per known app keeps the list itself independent of the state.
      ++ lib.mapAttrsToList (id: appConfig: lib.mkIf (builtins.elem id apps) appConfig) knownApps
    )
  );
}
