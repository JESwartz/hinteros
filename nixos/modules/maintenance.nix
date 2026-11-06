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
  # (app-env.nix; this module also works without it)
  appProfilesDir = config.hinteros.appEnv.profilesDir or "/nix/var/nix/profiles/hinteros";
  sessionCfg = config.hinteros.session;
  launcherName = baseNameOf (lib.getExe sessionCfg.homeApp);
  # With the greeter the launcher runs as the greeter or as whichever profile is on screen.
  greeterOn = config.hinteros.profiles.greeter.enable or false;

  # The automatic clean-up: trim the system's generations and every app profile's,
  # then collect garbage, under one flock. The daemon's manual clean-up jobs (their own trim and
  # `nix-store --gc`) are serialised with it by Nix's profile and GC locks; they may take the flock
  # too. No boot entry is rewritten: entries are the newest `configurationLimit` (keepSystem, at
  # least 2) generations of the last rebuild, which a trim to the newest keepSystem keeps (with
  # keepSystem = 1 the older entry is left without its system; with boot counting the trim waits
  # for a good boot, so that is not the fallback of a boot that still needs one).
  #
  #   hinteros-cleanup [--system N] [--profiles N]
  #
  # A trim keeps the N newest generations and never removes the current generation of a profile;
  # the system's also keeps the generations of the running and the booted system (after a switch
  # without reboot, or a boot of an older entry, these are not the newest).
  cleanup = pkgs.writeShellApplication {
    name = "hinteros-cleanup";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.util-linux
      config.nix.package
    ];
    text = ''
      system="" profiles=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --system) system=$2; shift 2 ;;
          --profiles) profiles=$2; shift 2 ;;
          *) echo "usage: hinteros-cleanup [--system N] [--profiles N]" >&2; exit 2 ;;
        esac
      done
      for n in "$system" "$profiles"; do
        case "$n" in "") ;; 0* | *[!0-9]*) echo "not a generation count: $n" >&2; exit 2 ;; esac
      done

      # trim PROFILE KEEP [STORE PATH TO KEEP...]
      trim() {
        local profile=$1 keep=$2 dir base cur g n t i
        shift 2
        dir=$(dirname "$profile") base=$(basename "$profile")
        cur=$(readlink "$profile")
        local gens=() del=()
        for l in "$dir/$base"-*-link; do
          [ -L "$l" ] || continue
          n=''${l#"$dir/$base"-} n=''${n%-link}
          # (`hinteros-*-link` also matches `hinteros-p2-*-link`: not a number, skipped)
          case "$n" in "" | *[!0-9]*) continue ;; esac
          gens+=("$n")
        done
        mapfile -t gens < <(printf '%s\n' "''${gens[@]}" | sort -n)
        for i in "''${!gens[@]}"; do
          g=''${gens[$i]}
          [ -n "$g" ] || continue
          [ "$i" -lt $(( ''${#gens[@]} - keep )) ] || continue
          [ "$cur" != "$base-$g-link" ] || continue
          t=$(readlink -f "$dir/$base-$g-link")
          for k in "$@"; do [ "$t" != "$k" ] || continue 2; done
          del+=("$g")
        done
        if [ ''${#del[@]} -gt 0 ]; then
          echo "$profile: removing generation(s) ''${del[*]}, keeping the newest $keep"
          nix-env --profile "$profile" --delete-generations "''${del[@]}"
        fi
      }

      exec 9>${cfg.cleanupLock}
      flock 9
      if [ -n "$system" ]; then
        keepPaths=()
        for r in /run/current-system /run/booted-system; do
          [ -e "$r" ] && keepPaths+=("$(readlink -f "$r")")
        done
        trim /nix/var/nix/profiles/system "$system" "''${keepPaths[@]}"
      fi
      if [ -n "$profiles" ]; then
        for p in ${appProfilesDir}/apps/* ${appProfilesDir}/starter; do
          case "$p" in *-link) continue ;; esac
          [ -L "$p" ] || continue
          trim "$p" "$profiles" || echo "cannot trim $p" >&2
        done
      fi
      nix-collect-garbage
    '';
  };

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

  # "Launcher and daemon are up" (and stay up for stableSeconds). Gates boot-complete.target, so
  # systemd-bless-boot only marks the entry good once the console is really there; otherwise the
  # boot counter runs out and systemd-boot falls back to the previous generation.
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
      # A launcher process, not the on-screen keyboard (the same binary with --osk).
      launcher_pid() {
        local p cmd
        for p in $(pgrep ${
          if greeterOn then "" else "-u ${sessionCfg.user} "
        }-f ${lib.escapeShellArg launcherName}); do
          cmd=$(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null) || continue
          case " $cmd" in *" --osk "*) continue ;; esac
          echo "$p"
          return 0
        done
        return 1
      }
      # Prints what changes when a piece restarts (daemon restart count, greetd start, launcher PID).
      up() {
        systemctl is-active --quiet hinteros-system.service || return 1
        local mark
        mark=$(systemctl show -P NRestarts hinteros-system.service)
        ${lib.optionalString sessionCfg.enable "systemctl is-active --quiet greetd.service || return 1"}
        ${lib.optionalString sessionCfg.enable ''mark="$mark $(systemctl show -P ActiveEnterTimestampMonotonic greetd.service) $(launcher_pid)" || return 1''}
        echo "$mark"
      }
      # Up without a restart for stableSeconds: a binary that crashes soon after each start
      # (and is restarted) is not "up".
      last="" since=0
      for i in $(seq 1 ${
        toString (cfg.bootCounting.healthTimeoutSeconds + cfg.bootCounting.stableSeconds)
      }); do
        if now=$(up); then
          [ "$now" = "$last" ] || { last=$now since=$i; }
          if [ $((i - since)) -ge ${toString cfg.bootCounting.stableSeconds} ]; then
            echo "daemon${lib.optionalString sessionCfg.enable " and launcher"} are up"
            bless_booted_entry
            exit 0
          fi
        else
          last=""
        fi
        sleep 1
      done
      echo "daemon${lib.optionalString sessionCfg.enable " or launcher"} did not stay up; not marking this boot good" >&2
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
      stableSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 20;
        description = ''
          How long the launcher and daemon must then stay up with no restart before the boot is
          good, so a build that crashes soon after each start falls back too.
        '';
      };
    };

    keepGenerations = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = ''
        System generations kept by the automatic clean-up (and boot entries kept by
        systemd-boot, at least 2), so rollback always has targets. The running and the booted generation are
        never removed. state.json: `settings.cleanup.keepSystem`.
      '';
    };

    keepProfileGenerations = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = ''
        Generations the automatic clean-up keeps of each app profile
        (`/nix/var/nix/profiles/hinteros/{apps/<user>,starter}`), besides the current one.
        state.json: `settings.cleanup.keepProfiles`.
      '';
    };

    cleanupLock = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "/run/lock/hinteros-cleanup.lock";
      description = ''
        flock(1) lock `hinteros-cleanup` holds while it trims generations and collects garbage.
        The daemon's manual clean-up jobs may take it too (Nix's profile and GC locks already
        serialise them with the automatic clean-up).
      '';
    };

    cleanupPackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = cleanup;
      description = "`hinteros-cleanup [--system N] [--profiles N]`: trim, then collect garbage, under `cleanupLock`.";
    };

    gc = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Trim old generations and collect garbage automatically. state.json: `settings.cleanup.enable`.";
      };
      dates = lib.mkOption {
        type = lib.types.str;
        default = "weekly";
        description = "systemd calendar expression for the automatic clean-up. state.json: `settings.cleanup.frequency` (daily, weekly, monthly).";
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

      systemd = {
        services.hinteros-boot-health = {
          description = "Check that the HinterOS daemon and launcher are up";
          before = [ "boot-complete.target" ];
          # Every boot: also when systemd-bless-boot does not run (no LoaderBootCountPath, see
          # bootHealth), this check is what marks the boot good.
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
            TimeoutStartSec = cfg.bootCounting.healthTimeoutSeconds + cfg.bootCounting.stableSeconds + 30;
          };
        };
        targets.boot-complete = {
          requires = [ "hinteros-boot-health.service" ];
          # Every boot, not only when systemd-bless-boot pulls it in: that is only on the first
          # boot of an entry (later ones have no counter, so no LoaderBootCountPath), and never on
          # firmware that drops the variable. nix-gc needs the target (below). multi-user.target
          # already waits for hinteros-boot-health, so the boot takes no longer.
          wantedBy = [ "multi-user.target" ];
        };
        # Never clean up during a boot that is not good yet: the trim could remove the generation
        # boot counting falls back to (with keepSystem = 1, the only other one). A failed check
        # fails the target, so there is no clean-up on that boot.
        services.nix-gc = lib.mkIf cfg.gc.enable {
          requisite = [ "boot-complete.target" ];
          after = [ "boot-complete.target" ];
        };
      };
    })

    {
      # At least two entries, so boot counting has a generation to fall back to also with
      # keepSystem = 1 (the clean-up then removes it, once a boot of the new one was good).
      boot.loader.systemd-boot.configurationLimit = lib.mkDefault (lib.max 2 cfg.keepGenerations);
    }

    # The boot loader writes entries for the newest `configurationLimit` generations only. A
    # switch to an older generation (`nix-env --switch-generation`, the daemon's rollback) would
    # get no entry, and loader.conf would fall back to the newest: the next boot would undo the
    # rollback without a word. Fail the install instead, so the switch fails before activation
    # and the caller puts the old generation back.
    (lib.mkIf config.boot.loader.systemd-boot.enable {
      boot.loader.systemd-boot.extraInstallCommands =
        let
          sdBoot = config.boot.loader.systemd-boot;
          entries = "${
            if sdBoot.xbootldrMountPoint != null then
              sdBoot.xbootldrMountPoint
            else
              config.boot.loader.efi.efiSysMountPoint
          }/loader/entries";
        in
        ''
          if ! ${lib.getExe pkgs.gnugrep} -qsE "(^| )init=$1/init( |$)" ${entries}/nixos-*.conf; then
            echo "error: no boot entry for $1. Only the newest ${toString sdBoot.configurationLimit} system generations get one." >&2
            exit 1
          fi
        '';
    })

    (lib.mkIf cfg.gc.enable {
      nix.gc = {
        automatic = true;
        inherit (cfg.gc) dates;
        persistent = true;
        options = "";
      };
      # `--delete-older-than` can't promise rollback targets; count instead. The trims and the
      # collection are one script under the clean-up lock (not nix.gc's plain collection).
      systemd.services.nix-gc.script = lib.mkForce ''
        exec ${lib.getExe cleanup} --system ${toString cfg.keepGenerations} --profiles ${toString cfg.keepProfileGenerations}
      '';
      # In the background of whatever is on screen (as the daemon's jobs).
      systemd.services.nix-gc.serviceConfig = {
        Nice = 19;
        IOSchedulingClass = "idle";
      };
    })

    (lib.mkIf cfg.optimise.enable {
      nix.optimise = {
        automatic = true;
        dates = [ "weekly" ];
      };
      systemd.services.nix-optimise.serviceConfig = {
        Nice = 19;
        IOSchedulingClass = "idle";
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
