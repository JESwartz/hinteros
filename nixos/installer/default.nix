# The installer environment: hinteros-install plus everything an install needs that is not on the
# target yet. A NixOS module, shared by the ISO (iso.nix, `nixosConfigurations.installer`) and the
# VM tests, which run it as a plain node. Takes the system flake's `self` to pin the offline
# lock to this very revision.
#
# Offline installs. The ISO carries (1) the closure of a default HinterOS system (the base plus
# the four apps with `onIso`), (2) the sources of this repo and of every flake input it locks,
# and (3) a flake.lock for the generated /etc/hinteros flake whose `hinteros` input points at the
# revision the ISO was built from, with the same narHash. Nix resolves a locked input whose
# narHash is already in the store without fetching, so `nixos-install --flake` evaluates and
# substitutes everything from the ISO's store. A later `nix flake update hinteros` on the
# installed box moves it to the channel.
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hinteros.installer;
  appIds = import ../lib/app-ids.nix config.hinteros.catalog.entries;

  # The same URL channels.json ships (hinteros.update.repo), so the device flake's input line is
  # exactly what hinteros-system's channel.set looks for.
  repoUrl = config.hinteros.update.repo;

  # A clean checkout has `rev`; a dirty one (development) gets a placeholder, which Nix accepts as
  # long as the narHash is in the store. Never ship an ISO built from a dirty tree.
  isoRev = self.rev or "0000000000000000000000000000000000000000";

  offlineLock = import ../lib/device-lock.nix { inherit lib; } {
    selfLock = builtins.fromJSON (builtins.readFile (self + "/flake.lock"));
    locked = {
      type = "git";
      url = repoUrl;
      ref = "refs/heads/stable";
      rev = isoRev;
      inherit (self) narHash lastModified;
    }
    // lib.optionalAttrs (self ? revCount) { inherit (self) revCount; };
    original = {
      type = "git";
      url = repoUrl;
      ref = "stable";
    };
  };

  # This repo's source and the source of every flake input below it (all in the store already:
  # the build evaluated them).
  sources = map (x: x.flake.outPath) (
    builtins.genericClosure {
      startSet = [
        {
          key = self.outPath;
          flake = self;
        }
      ];
      operator =
        x:
        map (f: {
          key = f.outPath;
          flake = f;
        }) (lib.attrValues (x.flake.inputs or { }));
    }
  );

  # A device as an install makes it. `configDir` stands in for the /etc/hinteros the installer writes
  # (the generation snapshot is built from it).
  deviceConfigDir = pkgs.runCommand "hinteros-device-config" { } ''
    mkdir $out
    for f in flake.nix flake.lock state.json; do echo placeholder > $out/$f; done
  '';
  mkVariant =
    {
      hostname ? "hinteros",
      user ? "admin",
      ssh ? false,
      apps,
    }:
    self.lib.mkDevice {
      state = {
        schemaVersion = 1;
        base = "unstable";
        stateVersion = config.system.nixos.release;
        settings = {
          inherit hostname;
          ssh.enable = ssh;
          admin.user = user;
        };
        disk.layout = "gpt-esp-ext4";
        inherit apps;
        profiles = [ ];
      };
      configDir = deviceConfigDir;
    };

  # A representative device: the base plus the default apps. Its closure is what the ISO ships;
  # a real install differs from it only in small configuration derivations.
  defaultDevice = mkVariant { apps = appIds.onIso; };

  # Devices an offline install can produce: the system stage (no apps), each app alone and all
  # of them (the apps stage tries them one by one when the whole set fails), with and without ssh.
  # The build-time inputs of what they build are put on the ISO (nixos/lib/offline-inputs.nix).
  offlineInputs = import ../lib/offline-inputs.nix { inherit lib pkgs; };
  toplevelOf = d: d.config.system.build.toplevel;
  isoVariants = map (v: toplevelOf (mkVariant v)) (
    [
      { apps = [ ]; }
      {
        apps = [ ];
        ssh = true;
      }
      {
        apps = appIds.onIso;
        ssh = true;
      }
    ]
    ++ map (a: { apps = [ a ]; }) appIds.onIso
  );
  isoInputs = offlineInputs.analysis {
    default = toplevelOf defaultDevice;
    variants = isoVariants;
  };
  # A different set of devices (other host names and users, app pairs) that the flake check
  # tests against the finished ISO.
  checkInputs = offlineInputs.analysis {
    default = toplevelOf defaultDevice;
    variants = map (v: toplevelOf (mkVariant v)) [
      {
        hostname = "livingroom";
        user = "james";
        apps = [ ];
      }
      {
        hostname = "tv-2";
        user = "alex";
        ssh = true;
        apps = [
          "youtube"
          "firefox"
        ];
      }
      {
        hostname = "box";
        apps = lib.take 2 (lib.reverseList appIds.onIso);
      }
    ];
  };

  # The store paths a derivation is built from, as one file that references them (so they travel
  # with the closure that includes it). Installing a device builds a few small derivations that
  # differ from the default system's (config files, /etc, the system path, the initrd, the
  # toplevel); their builders need these inputs, which the system itself does not reference.
  buildInputsOf =
    d:
    pkgs.writeText "${d.name}-build-inputs" (
      builtins.toJSON (
        d.drvAttrs or (removeAttrs d [
          "all"
          "out"
          "drvPath"
          "outPath"
          "outputs"
          "drvAttrs"
          "override"
          "overrideAttrs"
        ])
      )
    );
  sysBuild = defaultDevice.config.system.build;
  buildInputs = map buildInputsOf [
    sysBuild.toplevel
    sysBuild.etc
    defaultDevice.config.system.path
    sysBuild.initialRamdisk
  ];

  # Leaf inputs of those builders (the files /etc and the unit directories are assembled from, and
  # the tools their builders run) that nothing at runtime references.
  defaultConfig = defaultDevice.config;
  inStore = p: lib.hasPrefix builtins.storeDir (toString p);
  builderInputs =
    lib.filter inStore (
      lib.mapAttrsToList (_: e: e.source) (lib.filterAttrs (_: e: e.enable) defaultConfig.environment.etc)
      ++ lib.mapAttrsToList (_: u: u.unit) defaultConfig.systemd.units
    )
    ++ [
      pkgs.lndir
      pkgs.jq.dev
      pkgs.nukeReferences
      pkgs.libxslt.bin
      pkgs.kmod.dev
      pkgs.findXMLCatalogs
      pkgs.mypy # the systemd-boot builder is type-checked when it is built
      pkgs.perl
      pkgs.libcap-text-verifier
    ]
    ++ map buildInputsOf (
      lib.filter (d: d ? drvAttrs) (
        lib.mapAttrsToList (_: e: e.source) (lib.filterAttrs (_: e: e.enable) defaultConfig.environment.etc)
        ++ lib.mapAttrsToList (_: u: u.unit) defaultConfig.systemd.units
        ++ defaultConfig.services.udev.packages
      )
    )
    ++ map buildInputsOf [
      # What generating a TOML file (the daemon and greetd configs) runs.
      ((pkgs.formats.toml { }).generate "x" { })
    ];

  # The disk layout. The device is a placeholder that hinteros-install points at the chosen disk
  # (a symlink), so the whole partitioning script is built with the ISO and needs no evaluation
  # or build at install time.
  diskoLib = import "${pkgs.disko}/share/disko" { inherit lib; };
  diskoConfig = {
    disko.devices.disk.main = {
      type = "disk";
      device = "/dev/hinteros-target";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            label = "hinteros-esp";
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
              extraArgs = [
                "-n"
                "HINTEROSESP"
              ];
            };
          };
          root = {
            label = "hinteros-root";
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
              mountOptions = [ "noatime" ];
            };
          };
        };
      };
    };
  };
  diskoScript = diskoLib._cliDestroyFormatMount diskoConfig pkgs;

  # The launcher is built with `autoPubspecLock`, i.e. import-from-derivation: evaluating a device
  # builds this tiny derivation (pubspec.lock to JSON). It is not in the system's closure, so an
  # offline evaluation needs its output in the store. Same derivation as nixpkgs'
  # buildDartApplication makes (same name, inputs and script), so same output path.
  launcherPubspecLock = pkgs.runCommand "hinteros-launcher-pubspec-lock-json" {
    nativeBuildInputs = [ pkgs.yq ];
  } ''yq . '${pkgs.hinteros-launcher.src + "/pubspec.lock"}' > "$out"'';

  hinteros-install = pkgs.callPackage ../pkgs/hinteros-install {
    diskoScript = lib.getExe diskoScript;
    offlineLock = pkgs.writeText "offline-flake.lock" (builtins.toJSON offlineLock);
    # Everything evaluation needs from the store: the flake sources and the IFD output above.
    sourcesFile = pkgs.writeText "hinteros-install-sources" (
      lib.concatLines (sources ++ [ "${launcherPubspecLock}" ])
    );
    appsJson = pkgs.writeText "hinteros-install-apps.json" (builtins.toJSON appIds);
    # The Store index of this ISO's catalog: which apps have vendor terms, and their versions.
    catalogIndex = "${config.hinteros.catalog.index}/share/hinteros/catalog.json";
    stateVersion = config.system.nixos.release;
    inherit repoUrl isoRev;
    nix = config.nix.package;
  };

  # Copies the install log and what is needed to diagnose a failed install or a network/hardware
  # problem (journal, dmesg, the hinteros-diagnose report, nmcli, lspci, lsusb, a facter report) to
  # a second USB stick: a whole disk (its first partition with a filesystem is used) or a partition.
  saveLog = pkgs.writeShellApplication {
    name = "hinteros-save-log";
    runtimeInputs = [
      pkgs.util-linux
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.jq
      pkgs.networkmanager
      pkgs.iproute2
      pkgs.pciutils
      pkgs.usbutils
      pkgs.systemd
      pkgs.kmod
      pkgs.nixos-facter
      config.hinteros.diagnostics.package
    ];
    text = ''
      usage() {
        echo "usage: hinteros-save-log /dev/sdX    (a whole second USB stick, or one partition: /dev/sdX1)" >&2
        echo "The stick must not be the installer and not the disk being installed to." >&2
        lsblk -o NAME,SIZE,FSTYPE,LABEL,MODEL,TRAN >&2
      }
      die() { echo "hinteros-save-log: $1" >&2; exit "''${2:-1}"; }

      if [ $# -ne 1 ]; then usage; exit 2; fi
      arg=$1
      [ -e "$arg" ] || { usage; die "no such device: $arg" 2; }
      [ -b "$arg" ] || { usage; die "$arg is not a block device (use /dev/sdX or /dev/sdX1)" 2; }
      arg=$(readlink -f "$arg")

      # The whole disk a device belongs to.
      disk_of() {
        local p
        p=$(lsblk -ndo PKNAME "$1" 2>/dev/null | head -n1)
        if [ -n "$p" ]; then echo "/dev/$p"; else echo "$1"; fi
      }

      argdisk=$(disk_of "$arg")
      # Refuse the installer stick (where the live system is mounted from, or an ISO filesystem)
      # and the disk being installed to.
      refuse_disks=""
      for m in /iso /run/initramfs/live /nix/.ro-store /nix/store; do
        src=$(findmnt -no SOURCE "$m" 2>/dev/null | head -n1 | sed 's/\[.*//' || true)
        if [ -n "$src" ] && [ -b "$src" ]; then refuse_disks="$refuse_disks $(disk_of "$src")"; fi
      done
      if [ -e /dev/hinteros-target ]; then refuse_disks="$refuse_disks $(readlink -f /dev/hinteros-target)"; fi
      for src in $(findmnt -rno SOURCE | grep '^/dev/' || true); do
        mp=$(findmnt -rno TARGET "$src" | head -n1 || true)
        case "$mp" in /mnt|/mnt/*) refuse_disks="$refuse_disks $(disk_of "$src")" ;; esac
      done
      for r in $refuse_disks; do
        if [ "$r" = "$argdisk" ]; then die "$argdisk is the installer stick or the disk being installed to. Use a SECOND USB stick." 2; fi
      done

      # Pick the partition: the device itself when it is a partition (or holds a filesystem), else
      # the first partition of the disk that has a filesystem.
      dev=$arg
      type=$(lsblk -ndo TYPE "$arg" | head -n1)
      fs=$(blkid -p -o value -s TYPE "$arg" 2>/dev/null || true)
      usable_fs() { case "$1" in vfat | exfat | ntfs | ext4 | ext3 | ext2) return 0 ;; *) return 1 ;; esac; }
      if [ "$type" = disk ] && ! usable_fs "$fs"; then
        # A whole stick: the largest writable partition with a filesystem we can write to.
        # Image filesystems (a stick that once held an ISO) and read-only partitions are skipped.
        dev=""
        best=0
        seen=""
        [ -z "$fs" ] || seen="$arg: $fs (whole disk); "
        while read -r part size; do
          pfs=$(blkid -p -o value -s TYPE "$part" 2>/dev/null || true)
          plabel=$(lsblk -ndo LABEL "$part" | head -n1)
          ro=$(blockdev --getro "$part" 2>/dev/null || echo 0)
          note=""
          if [ -z "$pfs" ]; then note="no filesystem"
          elif ! usable_fs "$pfs"; then note="not supported"
          elif [ "$ro" = 1 ]; then note="read-only"
          elif [ "$plabel" = HINTEROS ]; then note="the installer"
          fi
          seen="$seen$part: ''${pfs:-none}''${note:+ ($note)}; "
          if [ -z "$note" ] && [ "$size" -gt "$best" ]; then dev=$part; best=$size; fi
        done < <(lsblk -b -J -o PATH,TYPE,SIZE "$arg" | jq -r '.blockdevices[] | select(.type == "part") | "\(.path) \(.size)"')
        [ -n "$dev" ] || die "no usable partition on $arg (needs a writable FAT32, exFAT, NTFS or ext4 partition). Saw: ''${seen:-no partitions}. Format the stick as FAT32 or exFAT on another computer and try again." 1
        echo "Using $dev, the largest writable partition of $arg (saw: $seen)"
      fi
      fs=$(blkid -p -o value -s TYPE "$dev" 2>/dev/null || true)
      case "$fs" in iso9660 | squashfs) die "$dev is an installer or read-only image ($fs). Use a SECOND USB stick." 2 ;; esac
      if [ "$(lsblk -ndo LABEL "$dev" | head -n1)" = HINTEROS ]; then
        die "$dev is labelled HINTEROS: it is the installer stick. Use a SECOND USB stick." 2
      fi
      mounted=$(findmnt -rno TARGET "$dev" 2>/dev/null | head -n1 || true)
      [ -z "$mounted" ] || die "$dev is already mounted at $mounted. Unmount it first." 2

      case "$fs" in
        vfat) mtype=vfat ;;
        exfat) mtype=exfat ;;
        ntfs) mtype=ntfs3 ;;
        ext4 | ext3 | ext2) mtype=$fs ;;
        "") die "no filesystem found on $dev. Format the stick as FAT32 or exFAT on another computer." 1 ;;
        *) die "unsupported filesystem '$fs' on $dev (supported: vfat, exfat, ntfs, ext4). Format the stick as FAT32 or exFAT on another computer." 1 ;;
      esac

      # Collect everything in RAM first, so the space needed is known before the stick is touched.
      st=$(mktemp -d)
      mp=$(mktemp -d)
      cleanup() {
        if mountpoint -q "$mp"; then umount "$mp" 2>/dev/null || { sleep 1; umount "$mp"; } || true; fi
        rmdir "$mp" 2>/dev/null || true
        rm -rf "$st"
      }
      trap cleanup EXIT

      echo "Collecting diagnostics..."
      cp /var/log/hinteros-install.log "$st/" 2>/dev/null || echo "no install log yet" >"$st/no-install-log"
      hinteros-diagnose --full >"$st/hinteros-diagnose.txt" 2>&1 || true
      {
        echo "## nmcli device status"; nmcli device status
        echo "## nmcli general"; nmcli general
        echo "## nmcli connection show"; nmcli connection show
        echo "## ip -s link"; ip -s link
        echo "## lsblk"; lsblk -o NAME,SIZE,FSTYPE,LABEL,MODEL,TRAN
        echo "## lsmod"; lsmod
      } >"$st/network-storage.txt" 2>&1 || true
      lspci -nnk >"$st/lspci.txt" 2>&1 || true
      lsusb >"$st/lsusb.txt" 2>&1 || true
      nmcli device status >"$st/nmcli-device.txt" 2>&1 || true
      journalctl -b --no-pager >"$st/journal.txt" 2>&1 || true
      dmesg >"$st/dmesg.txt" 2>&1 || true
      timeout 120 nixos-facter -o "$st/facter.json" >"$st/facter.log" 2>&1 || echo "facter failed or timed out, see facter.log" >&2

      echo "Mounting $dev ($fs)..."
      if ! err=$(mount -t "$mtype" -o rw,nosuid,nodev,noexec "$dev" "$mp" 2>&1); then
        hint=""
        [ "$fs" = ntfs ] && hint=" A stick that Windows did not eject cleanly (or has fast startup on) cannot be mounted: run chkdsk on it, or use another stick."
        die "could not mount $dev as $mtype: $err.$hint" 1
      fi
      if findmnt -no OPTIONS "$mp" | tr ',' '\n' | grep -qx ro; then
        die "$dev ($fs) was mounted read-only: the stick is write-protected, or its filesystem is marked dirty or damaged. Run a check/repair on it on another computer (Windows: chkdsk), or format it as FAT32 or exFAT." 1
      fi
      probe="$mp/.hinteros-write-test"
      if ! : >"$probe" 2>/dev/null; then
        die "cannot write to $dev (read-only or write-protected stick, or the filesystem is full)." 1
      fi
      rm -f "$probe"

      need=$(du -sk "$st" | cut -f1)
      avail=$(df -Pk "$mp" | awk 'NR==2{print $4}')
      if [ "$need" -gt "$avail" ]; then
        die "not enough space on $dev: need $((need / 1024 + 1)) MiB, only $((avail / 1024)) MiB free. Delete files on the stick or use a bigger one." 1
      fi

      d="$mp/hinteros-diagnostics-$(date +%Y%m%d-%H%M%S)"
      if ! { mkdir -p "$d" && cp -r "$st"/. "$d"/ && sync; }; then
        die "writing to $dev failed (no space left, or a failing stick)." 1
      fi
      echo "Saved to $(basename "$d") on $dev ($(du -sk "$d" | cut -f1) KiB); unmounting."
      cleanup
      trap - EXIT
      echo "Done: it is safe to remove the stick."
    '';
  };

  # An Xcursor theme whose every cursor is a single transparent pixel.
  blankCursors = pkgs.runCommand "hinteros-blank-cursors" { nativeBuildInputs = [ pkgs.perl ]; } ''
    d=$out/share/icons/hinteros-blank
    mkdir -p $d/cursors
    perl -e 'print "Xcur", pack("V*", 16, 0x10000, 1, 0xfffd0002, 1, 28, 36, 0xfffd0002, 1, 1, 1, 1, 0, 0, 0, 0)' > $d/cursors/left_ptr
    printf '[Icon Theme]\nName=hinteros-blank\n' > $d/index.theme
    for n in default arrow pointer hand hand1 hand2 text xterm ibeam crosshair cross wait watch progress \
      help question_arrow move grab grabbing fleur not-allowed no-drop forbidden context-menu \
      all-scroll col-resize row-resize ew-resize ns-resize nesw-resize nwse-resize e-resize w-resize \
      n-resize s-resize ne-resize nw-resize se-resize sw-resize sb_h_double_arrow sb_v_double_arrow \
      top_left_arrow left_ptr_watch pointing_hand; do
      ln -s left_ptr $d/cursors/$n
    done
  '';

  examplePlan = pkgs.writeText "plan.example.json" (
    builtins.toJSON {
      disk = "/dev/nvme0n1";
      hostname = "hinteros";
      admin = {
        user = "james";
        password = "change-me-now";
      };
      ssh.enable = false;
      channel = "stable";
      base = "unstable";
      apps = appIds.preselected;
      acceptedTerms = { };
    }
  );
in
{
  options.hinteros.installer = {
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = hinteros-install;
      description = "The `hinteros-install` backend of this installer.";
    };

    defaultSystem = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = defaultDevice.config.system.build.toplevel;
      description = "The default system whose closure the installer carries for offline installs.";
    };

    offlineLock = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      default = offlineLock;
      description = "The flake.lock (as an attrset) written to /etc/hinteros: `hinteros` pinned to this installer's revision.";
    };

    offlineInputs = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      readOnly = true;
      default = {
        iso = isoInputs;
        check = checkInputs;
      };
      description = "Analyses of the build-time inputs of offline installs: `iso` is what the ISO carries, `check` is a different set of devices that tests/eval/offline-inputs.nix checks against the finished ISO.";
    };

    ui.command = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      example = [
        "/run/current-system/sw/bin/hinteros-launcher"
        "--installer"
      ];
      description = ''
        The installer UI (the controller-driven screens from the launcher repo). When set, cage
        runs it fullscreen on tty1 as root (`services.cage`; root because it reads the gamepads,
        runs nmcli and `systemctl reboot` and starts `hinteros-install`, which needs root). It
        drives `hinteros-install --plan -` (JSON plan on stdin, JSON progress lines on stdout).
        If the UI exits, tty1 falls back to the console with the notice. Null: nothing starts
        automatically and the console shows the notice with the manual command.
      '';
    };
  };

  config = {
    # Nothing unfree on the installer (Steam, Plex and friends are downloaded during an online
    # install and never shipped).
    hinteros.forbidUnfree = true;

    environment.systemPackages = [
      hinteros-install
      pkgs.disko
      pkgs.jq
      saveLog
    ];

    # Mounting a second stick to save logs: FAT32 (vfat) is always there; exFAT and NTFS (the
    # kernel ntfs3 driver, plus ntfs-3g tools) are what Windows-formatted sticks use.
    boot.supportedFilesystems = {
      exfat = true;
      ntfs = true;
    };

    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
    ];

    # Wired networking needs no UI action: NetworkManager brings up DHCP on any Ethernet link by
    # itself (network-hardware.nix: a profile that matches every Ethernet device and has no interface name), the wired
    # status the UI shows comes from `nmcli device status`. No second DHCP client (dhcpcd) may
    # take interfaces away from NetworkManager, which would show them as "connected (externally)".
    networking = {
      networkmanager = {
        enable = true;
      };
      wireless.enable = lib.mkForce false;
      dhcpcd.enable = lib.mkForce false;
      useDHCP = lib.mkForce false;
    };

    # Firmware for network cards, Wi-Fi, GPUs and the like (linux-firmware is redistributable, not
    # an app, so `forbidUnfree` does not concern it).
    # Early microcode (prepended to the initrd) for both CPU vendors: without it some CPUs run with
    # known errata (e.g. "TSC_DEADLINE disabled due to Errata: please update microcode").
    hardware = {
      enableRedistributableFirmware = lib.mkForce true;
      cpu.intel.updateMicrocode = lib.mkForce true;
      cpu.amd.updateMicrocode = lib.mkForce true;
    };
    assertions = [
      {
        assertion = config.hardware.enableRedistributableFirmware;
        message = "hinteros installer: the firmware must be on the installer (NICs and Wi-Fi cards need it).";
      }
    ];

    # A root console on tty2 (Ctrl+Alt+F2) for diagnostics, whatever tty1 shows.
    systemd.services."getty@tty2" = {
      overrideStrategy = "asDropin";
      serviceConfig.ExecStart = [
        ""
        "@${pkgs.util-linux}/sbin/agetty agetty --login-program ${config.services.getty.loginProgram} --autologin root --noclear --keep-baud tty2 115200,38400,9600 $TERM"
      ];
    };

    # The offline closure.
    system.extraDependencies = [
      config.hinteros.installer.defaultSystem
      pkgs.stdenvNoCC
      launcherPubspecLock
    ]
    ++ buildInputs
    ++ builderInputs
    ++ offlineInputs.closure isoInputs
    ++ sources;

    environment.etc = {
      "hinteros-installer/plan.example.json".source = examplePlan;
    };

    # What the console says (tty2, and tty1 once the installer screens have exited). The stock
    # installation-device text (empty passwords, ssh) does not apply: sshd is off.
    users.motd = ''

      HinterOS installer (revision ${lib.substring 0 8 isoRev})

      The installer screens are on tty1 (Ctrl+Alt+F1); this console is tty2 (Ctrl+Alt+F2),
      logged in as root. Remote login is off.

      Network or hardware problem (for example the wired network says "unavailable")?

        hinteros-diagnose              network and hardware report; it fits one or two screens,
                                       photograph it
        hinteros-save-log /dev/sdX     save the report, the install log, the journal and a
                                       hardware report to a SECOND USB stick (not the installer);
                                       find it with `lsblk`; whole stick or partition, FAT32,
                                       exFAT, NTFS or ext4

      Wi-Fi: run `nmtui`. Other tools: lspci -nnk, lsusb, ethtool, iw, lshw, nixos-facter.

      Without the installer screens (they have exited or are not running) install from this
      console: write a plan (an example is in /etc/hinteros-installer/plan.example.json) and run

        hinteros-install --plan plan.json

      The disk named in the plan is erased. The log is /var/log/hinteros-install.log.

    '';

    services = {
      getty.helpLine = lib.mkForce ''
        HinterOS installer. `hinteros-diagnose` prints a network and hardware report.
      '';
      openssh.enable = lib.mkForce false;
      cage = lib.mkIf (cfg.ui.command != null) {
        enable = true;
        user = "root";
        program = lib.escapeShellArgs cfg.ui.command;
        # -s: Ctrl+Alt+F2 etc. switch VTs (cage has a logind session on seat0), so a root console on
        # tty2 is reachable while the UI runs.
        extraArguments = [ "-s" ];
        environment = {
          # The launcher runs on native Wayland (as on the box); software GL is allowed for machines
          # whose GPU cage cannot use. The fonts are bundled in the launcher.
          GDK_BACKEND = "wayland";
          XKB_DEFAULT_LAYOUT = "us";
          WLR_RENDERER_ALLOW_SOFTWARE = "1";
          # No visible mouse pointer: a cursor theme whose cursors are one transparent pixel (the
          # launcher hides its own pointer; this is the backstop for cage and the toolkit).
          XCURSOR_THEME = "hinteros-blank";
          XCURSOR_PATH = "${blankCursors}/share/icons";
          XCURSOR_SIZE = "1";
        };
      };
    };

    systemd.services.cage-tty1 = lib.mkIf (cfg.ui.command != null) {
      wantedBy = [ "multi-user.target" ];
      # hinteros-install is looked up by name, like lsblk, nmcli and systemctl.
      path = [
        hinteros-install
        pkgs.util-linux
        pkgs.networkmanager
        pkgs.systemd
      ];
      # The console notice (the getty on tty1) is the fallback when the UI exits.
      onSuccess = [ "getty@tty1.service" ];
      onFailure = [ "getty@tty1.service" ];
    };
  };
}
