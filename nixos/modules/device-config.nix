# Device config snapshots (hinteros-docs/design/device-config.md, "Snapshots and rollback").
# Every system toplevel embeds the config dir it was built from at `$out/hinteros/`, and a
# boot-time oneshot (hinteros-config-sync) restores that snapshot into /etc/hinteros when the
# two differ, so /etc/hinteros always describes the generation that is running, also after a
# rollback (from Settings or from boot counting).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hinteros.deviceConfig;

  # The files of a config dir that belong to a generation. facter.json describes hardware,
  # not settings, so it is neither snapshotted nor touched by the sync.
  managed = [
    "flake.nix"
    "flake.lock"
    "state.json"
  ];

  snapshot =
    if cfg.configDir != null then
      pkgs.runCommand "hinteros-config-snapshot" { } ''
        mkdir $out
        ${lib.concatMapStringsSep "\n" (
          f:
          lib.optionalString (builtins.pathExists (cfg.configDir + "/${f}")) ''
            cp ${cfg.configDir + "/${f}"} $out/${f}
          ''
        ) managed}
      ''
    else if config.hinteros.state != null then
      # No config dir (e.g. a checked-in device): snapshot the state it was built from.
      pkgs.writeTextDir "state.json" (builtins.toJSON config.hinteros.state)
    else
      null;

  syncScript = pkgs.writeShellApplication {
    name = "hinteros-config-sync";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.diffutils
    ];
    text = ''
      dir=${lib.escapeShellArg cfg.dir}
      snap=/run/current-system/hinteros

      if [ ! -d "$dir" ]; then
        echo "no $dir on this system; nothing to sync"
        exit 0
      fi
      if [ ! -d "$snap" ]; then
        echo "the running system has no config snapshot ($snap); nothing to sync"
        exit 0
      fi

      changed=()
      for f in ${lib.escapeShellArgs managed}; do
        if [ -e "$snap/$f" ]; then
          if [ ! -e "$dir/$f" ]; then
            changed+=("$f (missing)")
          elif ! cmp -s "$snap/$f" "$dir/$f"; then
            changed+=("$f (differs)")
          fi
        elif [ -e "$dir/$f" ]; then
          changed+=("$f (not in snapshot)")
        fi
      done

      if [ "''${#changed[@]}" -eq 0 ]; then
        echo "$dir already matches the running generation"
        exit 0
      fi

      echo "restoring $dir from the running generation's snapshot: ''${changed[*]}"

      # Build the new dir next to the old one (same filesystem), then swap the two with one
      # renameat2(RENAME_EXCHANGE): readers see either the old or the new dir, never a mix.
      tmp=$(mktemp -d "$(dirname "$dir")/.$(basename "$dir").sync.XXXXXX")
      trap 'rm -rf "$tmp"' EXIT
      cp -a "$dir"/. "$tmp"/
      for f in ${lib.escapeShellArgs managed}; do
        rm -f "''${tmp:?}/$f"
        if [ -e "$snap/$f" ]; then
          install -m 0644 -o root -g root "$snap/$f" "$tmp/$f"
        fi
      done
      sync -f "$tmp"
      mv --exchange -T "$tmp" "$dir"
      echo "restored; the previous contents are discarded"
    '';
  };
in
{
  options.hinteros.deviceConfig = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Embed the device config snapshot in every generation and run `hinteros-config-sync`
        at boot. The sync does nothing when the config dir or the snapshot is missing.
      '';
    };

    dir = lib.mkOption {
      type = lib.types.path;
      default = "/etc/hinteros";
      description = "Where the device's config dir lives on the running system.";
    };

    configDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "./.";
      description = ''
        Config dir this system is built from (`flake.nix`, `flake.lock`, `state.json`, copied
        into the store by the flake build). Set by `hinteros.lib.mkDevice`. When null, the
        snapshot holds just `state.json`, generated from `hinteros.state` if that is set.
      '';
    };

    snapshot = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      readOnly = true;
      default = snapshot;
      description = "The snapshot embedded at `$out/hinteros/` of the system toplevel.";
    };
  };

  config = lib.mkIf cfg.enable {
    system.systemBuilderCommands = lib.mkIf (snapshot != null) ''
      cp -r ${snapshot} $out/hinteros
    '';

    systemd.services.hinteros-config-sync = {
      description = "Restore ${cfg.dir} from the running generation's snapshot";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      # Before anything that reads the config: the privileged service and the session.
      before = [
        "hinteros-system.service"
        "greetd.service"
      ];
      unitConfig.RequiresMountsFor = cfg.dir;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe syncScript;
      };
    };
  };
}
