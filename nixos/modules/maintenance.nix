# Keeping a box healthy without anyone looking at it: boot counting with automatic fallback,
# garbage collection that always leaves rollback targets, store optimisation and a low-disk
# warning (M6 items, done early because they are system-side only).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hinteros.maintenance;
  sessionCfg = config.hinteros.session;
  launcherName = baseNameOf (lib.getExe sessionCfg.homeApp);
  # With the greeter the launcher runs as the greeter or as whichever profile is on screen.
  greeterOn = config.hinteros.profiles.greeter.enable or false;

  diskCheck = pkgs.writeShellApplication {
    name = "hinteros-disk-check";
    runtimeInputs = [
      pkgs.coreutils
    ];
    text = ''
      # statfs of the store's filesystem: available bytes for unprivileged use.
      read -r blocks bsize < <(stat -f -c '%a %S' /nix/store)
      avail=$(( blocks * bsize ))
      min=$(( ${toString cfg.diskCheck.minFreeGiB} * 1024 * 1024 * 1024 ))
      if [ "$avail" -lt "$min" ]; then
        # Priority 4 (warning). The launcher will surface this later (grep the identifier).
        echo "<4>low disk space: $(( avail / 1024 / 1024 )) MiB free on /nix/store, warning threshold ${toString cfg.diskCheck.minFreeGiB} GiB"
      else
        echo "<6>disk space ok: $(( avail / 1024 / 1024 )) MiB free on /nix/store"
      fi
    '';
  };

  # "Launcher and daemon are up". Gates boot-complete.target, so systemd-bless-boot only marks
  # the entry good once the console is really there; otherwise the boot counter runs out and
  # systemd-boot falls back to the previous generation.
  #
  # systemd-bless-boot only runs when the boot loader left LoaderBootCountPath (a volatile EFI
  # variable) for the generator. Some firmware drops systemd-boot's volatile variables (the
  # Lenovo M900: only LoaderSystemToken survives), so nothing ever marked a boot good: every
  # entry ran out of tries and the next boot fell back a generation. Without that variable the
  # check marks the booted entry good itself, as bless-boot would: the entry whose `init=` is
  # the booted system loses its `+LEFT[-DONE]` counter.
  bootHealth = pkgs.writeShellApplication {
    name = "hinteros-boot-health";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.procps
      pkgs.systemd
    ];
    text = ''
      bless_booted_entry() {
        for var in /sys/firmware/efi/efivars/LoaderBootCountPath-*; do
          [ -e "$var" ] && return 0 # systemd-bless-boot does it
        done
        booted=$(readlink -f /run/booted-system)
        for entry in /boot/loader/entries/*+*.conf; do
          [ -e "$entry" ] || continue
          grep -q "^options .*init=$booted/init" "$entry" || continue
          name=$(basename "$entry" .conf)
          good="/boot/loader/entries/''${name%%+*}.conf"
          if mv "$entry" "$good"; then
            echo "boot loader variables missing: marked $(basename "$good") good"
          else
            echo "cannot mark $(basename "$entry") good" >&2
          fi
        done
      }
      for _ in $(seq 1 ${toString cfg.bootCounting.healthTimeoutSeconds}); do
        if systemctl is-active --quiet hinteros-system.service${lib.optionalString sessionCfg.enable " && systemctl is-active --quiet greetd.service && pgrep ${if greeterOn then "" else "-u ${sessionCfg.user} "}-f ${lib.escapeShellArg launcherName} >/dev/null"}; then
          echo "daemon${lib.optionalString sessionCfg.enable " and launcher"} are up"
          bless_booted_entry
          exit 0
        fi
        sleep 1
      done
      echo "daemon${lib.optionalString sessionCfg.enable " or launcher"} did not come up in time; not marking this boot good" >&2
      exit 1
    '';
  };
in
{
  options.hinteros.maintenance = {
    bootCounting = {
      enable = lib.mkEnableOption ''
        systemd-boot automatic boot assessment (NixOS' `boot.loader.systemd-boot.bootCounting`)
        gated on the launcher and daemon being up, so a broken update falls back to the previous
        generation by itself. Needs systemd-boot; mkDevice turns it on by default
        wherever systemd-boot is enabled (every installed box), not in VMs or on the ISO'';
      tries = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3;
        description = "Boot attempts a new generation gets before systemd-boot skips it.";
      };
      healthTimeoutSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 120;
        description = "How long after boot the launcher and daemon get to come up.";
      };
    };

    keepGenerations = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = ''
        System generations kept by garbage collection (and boot entries kept by systemd-boot),
        so rollback always has targets. The generation that is running is never collected.
      '';
    };

    gc = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Trim old generations and collect garbage automatically.";
      };
      dates = lib.mkOption {
        type = lib.types.str;
        default = "weekly";
        description = "systemd calendar expression for the garbage collection.";
      };
    };

    optimise.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Hard-link identical files in the Nix store (`nix.optimise`).";
    };

    diskCheck = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Log a warning when free space on the store's filesystem drops below the threshold.";
      };
      minFreeGiB = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 5;
        description = "Warn below this many GiB free (a rebuild needs room; the update check wants about this much).";
      };
      interval = lib.mkOption {
        type = lib.types.str;
        default = "1h";
        description = "How often to check (systemd `OnUnitActiveSec`).";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.bootCounting.enable {
      boot.loader.systemd-boot.bootCounting = {
        enable = true;
        inherit (cfg.bootCounting) tries;
      };

      systemd.services.hinteros-boot-health = {
        description = "Check that the HinterOS daemon and launcher are up";
        before = [ "boot-complete.target" ];
        # Every boot: also when nothing pulls in boot-complete.target (no LoaderBootCountPath,
        # see bootHealth), this check is what marks the boot good.
        wantedBy = [ "multi-user.target" ];
        unitConfig.RequiresMountsFor = [ "/boot" ];
        after = [
          "hinteros-system.service"
        ]
        ++ lib.optional sessionCfg.enable "greetd.service";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = lib.getExe bootHealth;
          TimeoutStartSec = cfg.bootCounting.healthTimeoutSeconds + 30;
        };
      };
      systemd.targets.boot-complete.requires = [ "hinteros-boot-health.service" ];
    })

    {
      boot.loader.systemd-boot.configurationLimit = lib.mkDefault cfg.keepGenerations;
    }

    (lib.mkIf cfg.gc.enable {
      nix.gc = {
        automatic = true;
        inherit (cfg.gc) dates;
        persistent = true;
        # Plain `nix-collect-garbage`; the generation trim happens in preStart below.
        options = "";
      };
      # `--delete-older-than` can't promise rollback targets; count instead.
      systemd.services.nix-gc.preStart = ''
        ${config.nix.package}/bin/nix-env --profile /nix/var/nix/profiles/system --delete-generations +${toString cfg.keepGenerations}
      '';
    })

    (lib.mkIf cfg.optimise.enable {
      nix.optimise = {
        automatic = true;
        dates = [ "weekly" ];
      };
    })

    (lib.mkIf cfg.diskCheck.enable {
      systemd.services.hinteros-disk-check = {
        description = "Warn when the disk is nearly full";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe diskCheck;
          SyslogIdentifier = "hinteros-disk-check";
          DynamicUser = true;
        };
      };
      systemd.timers.hinteros-disk-check = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2min";
          OnUnitActiveSec = cfg.diskCheck.interval;
        };
      };
    })
  ];
}
