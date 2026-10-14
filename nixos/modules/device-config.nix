# Device config snapshots (hinteros-docs/design/device-config.md, "Snapshots and rollback").
# Every system toplevel embeds the config dir it was built from at `$out/hinteros/`, and a
# boot-time oneshot (hinteros-config-sync) restores that snapshot into /etc/hinteros when the
# two differ, so /etc/hinteros always describes the generation that is running, also after a
# rollback (from Settings or from boot counting). The one exception is state.json's
# `settings.timeZone` (time-zone.md): it changes without a rebuild, so the sync keeps the live one.
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
    else if cfg.embeddedFlake != null && config.hinteros.state != null then
      # A checked-in device (the dev box): a generated device flake naming the system repo by
      # store path, so `path:/etc/hinteros` evaluates like on any box (spike 8 item 6).
      pkgs.runCommand "hinteros-config-snapshot"
        {
          inherit (cfg.embeddedFlake) flake lock;
          state = builtins.toJSON config.hinteros.state;
          passAsFile = [
            "flake"
            "lock"
            "state"
          ];
        }
        ''
          mkdir $out
          cp "$flakePath" $out/flake.nix
          cp "$lockPath" $out/flake.lock
          cp "$statePath" $out/state.json
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
      pkgs.jq
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

      work=$(mktemp -d)
      tmp=""
      trap 'rm -rf "$work" ''${tmp:+"$tmp"}' EXIT

      # What each managed file must be: the snapshot's. Except `settings.timeZone` in state.json,
      # which is live (time-zone.md): hinteros-system changes it without a rebuild, so a zone in
      # the live state.json is kept (activation has already applied it).
      want() {
        if [ "$1" = state.json ] && [ -e "$work/state.json" ]; then
          echo "$work/state.json"
        else
          echo "$snap/$1"
        fi
      }
      if [ -e "$snap/state.json" ] && [ -e "$dir/state.json" ]; then
        live_tz=$(jq -c '.settings.timeZone? | strings' "$dir/state.json" 2>/dev/null || true)
        snap_tz=$(jq -c '.settings.timeZone? | strings' "$snap/state.json" 2>/dev/null || true)
        if [ -n "$live_tz" ] && [ "$live_tz" != "$snap_tz" ]; then
          jq --argjson tz "$live_tz" '.settings = ((.settings // {}) + {timeZone: $tz})' \
            "$snap/state.json" > "$work/state.json"
        fi
      fi
      # The same file, or for state.json the same JSON (hinteros-system writes it in its own
      # format).
      same() {
        cmp -s "$1" "$2" && return 0
        [ "$(basename "$2")" = state.json ] || return 1
        a=$(jq -cS . "$1" 2>/dev/null) && b=$(jq -cS . "$2" 2>/dev/null) && [ "$a" = "$b" ]
      }

      changed=()
      for f in ${lib.escapeShellArgs managed}; do
        if [ -e "$snap/$f" ]; then
          if [ ! -e "$dir/$f" ]; then
            changed+=("$f (missing)")
          elif ! same "$(want "$f")" "$dir/$f"; then
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
      cp -a "$dir"/. "$tmp"/
      for f in ${lib.escapeShellArgs managed}; do
        rm -f "''${tmp:?}/$f"
        if [ -e "$snap/$f" ]; then
          install -m 0644 -o root -g root "$(want "$f")" "$tmp/$f"
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

    embeddedFlake = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            flake = lib.mkOption {
              type = lib.types.str;
              description = "flake.nix text.";
            };
            lock = lib.mkOption {
              type = lib.types.str;
              description = "flake.lock text.";
            };
          };
        }
      );
      default = null;
      description = ''
        For a checked-in device without a config dir (the dev box): the generated `flake.nix` and
        `flake.lock` of a device flake, snapshotted with `state.json` (set by mkDevice's
        `selfFlake`), so hinteros-system can evaluate app envs from `path:/etc/hinteros`.
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
    # The device flake is built with `nixos-rebuild --flake path:...` by the privileged service.
    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
    ];

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

    # An offline install leaves `facter.deferred` next to the hardware report (see the device
    # flake template): the report is only applied by a rebuild once the box is online, because
    # applying it changes the system, which must then be built. Once the cache is reachable the
    # marker is removed; the next rebuild or update picks the report up.
    systemd.services.hinteros-facter-release = {
      description = "Release the deferred hardware report in ${cfg.dir} once online";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      unitConfig.ConditionPathExists = "${cfg.dir}/facter.deferred";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe (
          pkgs.writeShellApplication {
            name = "hinteros-facter-release";
            runtimeInputs = [
              pkgs.curl
              pkgs.coreutils
            ];
            text = ''
              curl -fsS --max-time 10 -o /dev/null https://cache.nixos.org/nix-cache-info
              rm -f ${lib.escapeShellArg cfg.dir}/facter.deferred
              echo "online: the hardware report will be applied by the next rebuild"
            '';
          }
        );
        # Not online yet (a NIC without a link, no internet): try again later.
        Restart = "on-failure";
        RestartSec = "10min";
      };
    };
  };
}
