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
  appIds = import ../lib/app-ids.nix;

  repoUrl = "https://justsomeshed.com/JSwartz/HinterOS/hinteros.git";

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

  # A representative device: the base plus the default apps. Its closure is what the ISO ships;
  # a real install differs from it only in small configuration derivations.
  defaultDevice = self.lib.mkDevice {
    state = {
      schemaVersion = 1;
      base = "unstable";
      stateVersion = config.system.nixos.release;
      settings = {
        hostname = "hinteros";
        ssh.enable = false;
        admin.user = "admin";
      };
      disk.layout = "gpt-esp-ext4";
      apps = appIds.onIso;
      profiles = [ ];
    };
  };

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
                "HINTEROS-ESP"
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

  hinteros-install = pkgs.callPackage ../pkgs/hinteros-install {
    diskoScript = lib.getExe diskoScript;
    offlineLock = pkgs.writeText "offline-flake.lock" (builtins.toJSON offlineLock);
    sourcesFile = pkgs.writeText "hinteros-install-sources" (lib.concatLines sources);
    appsJson = pkgs.writeText "hinteros-install-apps.json" (builtins.toJSON appIds);
    stateVersion = config.system.nixos.release;
    inherit repoUrl isoRev;
    nix = config.nix.package;
  };

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

    ui.command = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      example = [ "/run/current-system/sw/bin/hinteros-installer-ui" ];
      description = ''
        The installer UI (the controller-driven screens from the launcher repo). When set, it runs
        as a root service on boot; it drives `hinteros-install --plan -` (JSON plan on stdin, JSON
        progress lines on stdout). Null: nothing starts automatically and the console shows a
        notice with the manual command.
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
      pkgs.nixos-facter
      pkgs.jq
    ];

    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
    ];

    networking.networkmanager.enable = true;
    networking.wireless.enable = lib.mkForce false;

    # The offline closure.
    system.extraDependencies = [
      config.hinteros.installer.defaultSystem
      pkgs.stdenvNoCC
    ]
    ++ sources;

    environment.etc = {
      "hinteros-installer/plan.example.json".source = examplePlan;
    };

    users.motd = ''

      HinterOS installer (revision ${lib.substring 0 8 isoRev})

      No installer screen is running yet. To install from this console, write a plan and run

        sudo hinteros-install --plan plan.json

      An example plan is in /etc/hinteros-installer/plan.example.json. Connect to Wi-Fi with
      `nmtui` first if you want an online install. The disk named in the plan is erased.
      The log is /var/log/hinteros-install.log.

    '';

    systemd.services.hinteros-installer-ui = lib.mkIf (cfg.ui.command != null) {
      description = "HinterOS installer UI";
      wantedBy = [ "multi-user.target" ];
      after = [ "NetworkManager.service" ];
      serviceConfig = {
        ExecStart = lib.escapeShellArgs cfg.ui.command;
        Restart = "on-failure";
      };
    };
  };
}
