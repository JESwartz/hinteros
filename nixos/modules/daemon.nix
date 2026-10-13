# HinterOS daemons (see hinteros-docs/design/api.md):
#   hinteros-session: systemd user service of the session user, serves the session API on
#                     $XDG_RUNTIME_DIR/hinteros/session.sock (0600), which the launcher talks to.
#   hinteros-system:  privileged system service, serves the internal system API on
#                     /run/hinteros/system.sock (0660, group `hinteros`) to the session daemon.
{
  config,
  options,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hinteros.daemon;
  sessionUser = config.hinteros.session.user;
  toml = pkgs.formats.toml { };
  sessionConfig = toml.generate "hinteros-session.toml" cfg.session.settings;

  # What every generation ships for the privileged service, at
  # /run/current-system/sw/share/hinteros. hinteros-system reads the *running* generation's copy,
  # so an update can never widen its own trust.
  channels = {
    inherit (config.hinteros.update) repo;
    branches = {
      stable = "stable";
      beta = "beta";
    };
  };

  # "<principal> <ssh-ed25519 key> [comment]" to ssh-keygen's allowed_signers format. The
  # namespace is pinned, so these keys can only vouch for git commits.
  signerLines = import ../lib/allowed-signers.nix { inherit lib; };
  allowedSigners = pkgs.writeText "hinteros-allowed-signers" ''
    # Keys whose SSH signatures hinteros-system accepts on update commits (generated from
    # hinteros.update.allowedSigners; git, ssh-keygen allowed_signers format).
    # No entry below = no update verifies: every signature is rejected as unknown_signer.
    ${signerLines config.hinteros.update.allowedSigners}
  '';

  # polkit actions. Defaults are "no" for everything except ssh (the admin password); the rules
  # below grant the rest to the hinteros group. That keeps the grant in one readable place and
  # does not depend on how polkit classifies a user service's process.
  mkAction' = id: description: message: defaults: ''
    <action id="org.hinteros.system.${id}">
      <description>${description}</description>
      <message>${message}</message>
      <defaults>
        <allow_any>${defaults}</allow_any>
        <allow_inactive>${defaults}</allow_inactive>
        <allow_active>${defaults}</allow_active>
      </defaults>
    </action>
  '';
  mkAction = id: description: mkAction' id description description;
  policy = ''
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE policyconfig PUBLIC "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN" "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
    <policyconfig>
      <vendor>HinterOS</vendor>
    ${lib.concatStrings (
      lib.mapAttrsToList (id: d: mkAction id d "no") {
        settings = "Change HinterOS settings";
        rebuild = "Rebuild the system";
        "update.check" = "Check for HinterOS updates";
        "update.apply" = "Install a HinterOS update";
        rollback = "Roll back to the previous system generation";
        channel = "Switch the update channel or the base";
        "jobs.cancel" = "Cancel a running system job";
        apps = "Install or remove apps";
        # Profiles (profiles.md, "Authority"): PINs are checked by the service; polkit stays the
        # per-action gate (and the future parental-controls hook).
        profiles = "Change profiles";
        "profiles.create" = "Create a profile";
        starter = "Change the starter apps";
        services = "Enable or disable box services";
      }
    )}
    ${mkAction' "ssh" "Turn remote login (SSH) on or off"
      "Authentication is required to turn remote login (SSH) on or off"
      "auth_admin"
    }
    ${mkAction' "profiles.recover" "Reset the admin profile's PIN"
      "Authentication is required to reset the admin profile's PIN"
      "auth_admin"
    }
    </policyconfig>
  '';

  # release.json, update/*, and the polkit action definitions, as one package in systemPackages.
  share = pkgs.runCommand "hinteros-system-share" { } ''
    mkdir -p $out/share/hinteros/update $out/share/polkit-1/actions
    cp ${
      pkgs.writeText "release.json" (
        builtins.toJSON {
          inherit (config.hinteros.release) version;
          dev = (config.hinteros.dev or { enable = false; }).enable;
          # The highest state.json schema this generation's state.nix reads (DECISIONS D5): the
          # service migrates schema 1 only when the running generation says 2.
          stateSchema = 2;
        }
      )
    } $out/share/hinteros/release.json
    cp ${pkgs.writeText "channels.json" (builtins.toJSON channels)} $out/share/hinteros/update/channels.json
    cp ${allowedSigners} $out/share/hinteros/update/allowed_signers
    cp ${pkgs.writeText "org.hinteros.system.policy" policy} $out/share/polkit-1/actions/org.hinteros.system.policy
  '';

  # ssh and profiles.recover are not granted here: they stay auth_admin. The greeter may only
  # create profiles (over greeter.sock). Local overrides (parental controls) go in a
  # lower-numbered rules file that returns NO.
  greeterOn = config.hinteros.profiles.greeter.enable or false;
  polkitRules = ''
    polkit.addRule(function (action, subject) {
      if (action.id.indexOf("org.hinteros.system.") === 0 &&
          action.id !== "org.hinteros.system.ssh" &&
          action.id !== "org.hinteros.system.profiles.recover" && subject.isInGroup("${cfg.group}")) {
        return polkit.Result.YES;
      }
    });
  ''
  + lib.optionalString greeterOn ''
    polkit.addRule(function (action, subject) {
      if (action.id === "org.hinteros.system.profiles.create" &&
          subject.user === "${config.hinteros.profiles.greeter.user}") {
        return polkit.Result.YES;
      }
    });
  '';

  # `sudo hinteros-bootstrap-channel <channel> <rev>`: moves a box onto a channel outside the
  # update UI (a box that does not trust the release key yet, or whose keys are out of date).
  bootstrapChannel = pkgs.callPackage ../pkgs/hinteros-bootstrap-channel {
    nix = config.nix.package;
  };

  # What the job unit needs on PATH (hinteros-system job runs nix, git, ssh-keygen, nixos-facter).
  jobPath = [
    config.nix.package
    pkgs.git
    pkgs.openssh
    pkgs.nixos-facter
    pkgs.coreutils
  ];
in
{
  options.hinteros = {
    release.version = lib.mkOption {
      type = lib.types.str;
      default = "0.1.0-dev";
      description = ''
        HinterOS release version, shipped in `share/hinteros/release.json` (shown by
        `system.info`). `nixosModules.default` sets it from the repo's `release/version`
        (release.nix); the default is a placeholder for configs without it. Not meant to be set
        by devices.
      '';
    };

    update = {
      repo = lib.mkOption {
        type = lib.types.str;
        default = "https://justsomeshed.com/JSwartz/HinterOS/hinteros.git";
        description = ''
          The system repo that updates and channel switches fetch, as shipped in
          `share/hinteros/update/channels.json`. The device flake's input line
          (`"git+<repo>?ref=<branch>"`) must use exactly this URL (the installer's template does).
        '';
      };

      allowedSigners = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "owner ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... owner@hinteros" ];
        description = ''
          Keys whose SSH signatures hinteros-system accepts on update commits, one
          `"<principal> <ssh-ed25519 key> [comment]"` per entry; they become the generation's
          `share/hinteros/update/allowed_signers` (the namespace is pinned to `git`).

          EMPTY BY DEFAULT. `nixosModules.default` sets the vendor's keys from the repo's
          `release/allowed_signers` (release.nix, with `mkDefault`: a definition elsewhere replaces
          them). With no key, `update.check`, `update.apply` and `channel.set` fail
          closed: git's verification finds no matching principal, so every tip is rejected with
          `update_verification_failed` (`unknown_signer`) and nothing is ever applied. The running
          generation's list is what counts, so a key added here only takes effect once a
          generation containing it is running.
        '';
      };
    };

    daemon = {
      enable = lib.mkEnableOption "the HinterOS session daemon and system service";

      group = lib.mkOption {
        type = lib.types.str;
        default = "hinteros";
        description = "Group that owns the system socket; the session user is a member.";
      };

      session.package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.hinteros-session;
        defaultText = lib.literalExpression "pkgs.hinteros-session";
        description = "Package providing the `hinteros-session` binary.";
      };

      system.package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.hinteros-system;
        defaultText = lib.literalExpression "pkgs.hinteros-system";
        description = "Package providing the `hinteros-system` binary.";
      };

      sessionConfigFile = lib.mkOption {
        type = lib.types.path;
        readOnly = true;
        default = sessionConfig;
        defaultText = lib.literalMD "generated from `session.settings`";
        description = "The generated session.toml (the profile sessions' daemon, and the greeter's).";
      };

      session.settings = lib.mkOption {
        inherit (toml) type;
        default = { };
        example = lib.literalExpression ''
          {
            steam.autostart = true;
            apps = [ { id = "jellyfin"; name = "Jellyfin"; command = [ "jellyfin-desktop" ]; } ];
          }
        '';
        description = ''
          Contents of the session daemon's `session.toml` (see the hinteros-daemon README), as a
          Nix attribute set. The file is generated into the store and passed with `--config`.
          The module already sets `launcher.app_id`, `gamescope.*`, `osk.*`, `pointer.*`, `steam.path`, `steam.tag_windows`,
          `steam.library_poll_s`, `steam.library_debounce_ms` and `close.timeout_ms` (all with
          `mkDefault`; `steam.dir` is left to the daemon's default unless a test sets it).
        '';
      };

      # The on-screen keyboard: a second entrypoint of the launcher (`hinteros-osk`), started and
      # restarted by the session daemon and shown as a gamescope overlay (spike 5).
      osk = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Run the on-screen keyboard (`[osk] enable`); Guide+Y or `osk.show` summons it.";
        };
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.hinteros-launcher;
          defaultText = lib.literalExpression "pkgs.hinteros-launcher";
          description = "Package providing `bin/hinteros-osk` (the launcher ships it).";
        };
        summon = lib.mkOption {
          type = lib.types.str;
          default = "guide+context";
          example = "none";
          description = ''
            Controller chord that toggles the keyboard: `guide+<button>` (hold Guide, press the
            button; `context` is Y) or `none`. With a chord, Home fires on Guide release; `none`
            puts it back on the press.
          '';
        };
      };

      osk.autoShow = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          `[osk] auto_show`: show the keyboard when a text field gets focus in a keyboard-profile
          app. Off by default (the daemon's default): with `[osk] field_summon = "accept"` A on a focused
          field shows the keyboard. It only has an effect when the Firefox extension is installed
          (`hinteros.firefoxKiosk.oskExtension`); the daemon always listens on its internal
          `osk.sock`.
        '';
      };

      input.xboxLabelSwap = lib.mkOption {
        type = lib.types.enum [
          "auto"
          "on"
          "off"
        ];
        default = "auto";
        description = ''
          `[input] xbox_label_swap`: InputPlumber maps Xbox (xpad) pads positionally, so physical Y
          arrives as `ui_action` and X as `ui_context`; the daemon swaps them so Y is always the
          chord button. `auto` detects xpad pads; `on`/`off` force it.
        '';
      };

      logLevel = lib.mkOption {
        type = lib.types.str;
        default = "info";
        example = "debug";
        description = "`RUST_LOG` filter for both daemons.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    hinteros.daemon.session.settings = {
      launcher.app_id = lib.mkDefault config.hinteros.session.launcherAppId;
      # The cage fallback (VM) has no gamescope to drive.
      gamescope = {
        enable = lib.mkDefault (config.hinteros.session.compositor == "gamescope");
        # gamescope's Xwayland and Wayland socket; a user service does not inherit them. "auto": the
        # session user's lowest live X display (a switch can leave :0 to the previous session).
        display = lib.mkDefault (
          if config.hinteros.session.compositor == "gamescope" then "auto" else ":0"
        );
        wayland_display = lib.mkDefault (
          if config.hinteros.session.compositor == "gamescope" then "gamescope-0" else "wayland-0"
        );
      };
      osk = {
        inherit (cfg.osk) enable summon;
        auto_show = cfg.osk.autoShow;
        command = lib.mkDefault [ "${cfg.osk.package}/bin/hinteros-osk" ];
      };
      # Pointer (right stick in keyboard-profile apps). gamescope never hides it on inactivity
      # (session.nix `cursor.hideDelayMs`); the daemon hides/shows the cursor plane with
      # gamescopectl, by absolute store path (the user unit's PATH does not carry it). Under cage
      # there is no gamescope and no hiding.
      pointer =
        let
          ctl = lib.getExe' config.hinteros.session.gamescope.package "gamescopectl";
          cursor =
            on:
            lib.optionals (config.hinteros.session.compositor == "gamescope") [
              ctl
              "paint_cursor_plane"
              on
            ];
        in
        {
          hide_command = lib.mkDefault (cursor "0");
          show_command = lib.mkDefault (cursor "1");
        };
      input.xbox_label_swap = lib.mkDefault cfg.input.xboxLabelSwap;
      steam = {
        # Steam's own windows get STEAM_GAME=769 so gamescope can show them (needs gamescope).
        tag_windows = lib.mkDefault true;
        library_poll_s = lib.mkDefault 60;
        library_debounce_ms = lib.mkDefault 500;
      };
      close.timeout_ms = lib.mkDefault 5000;
      # Runtime settings (API 0.7): the audio client is pactl (PipeWire's PulseAudio server finds
      # its socket through XDG_RUNTIME_DIR, which the user manager sets). An absolute path: the
      # user unit's PATH is the profile's, which does not carry it.
      audio.pactl = lib.mkDefault (lib.getExe' pkgs.pulseaudio "pactl");
    };

    users.groups.${cfg.group} = { };
    # profiles.nix puts every account in the group; without it (module tests) the session user.
    users.users.${sessionUser}.extraGroups = lib.mkIf (!(options.hinteros ? profiles)) [ cfg.group ];

    assertions = [
      {
        assertion = lib.all (
          l: builtins.match "([^ #]+) (ssh-ed25519 [A-Za-z0-9+/=]+( .*)?)" l != null
        ) config.hinteros.update.allowedSigners;
        message = "hinteros.update.allowedSigners: every entry must be \"<principal> ssh-ed25519 <key> [comment]\".";
      }
    ];

    security.polkit.enable = true;
    environment = {
      # sw/bin/hinteros-session and sw/bin/hinteros-system (hinteros-system compares them across
      # generations for session_restart_required), plus the per-generation files and polkit actions.
      systemPackages = [
        cfg.session.package
        cfg.system.package
        share
        bootstrapChannel
      ];
      pathsToLink = [
        "/share/hinteros"
        "/share/polkit-1/actions"
      ];
      etc."polkit-1/rules.d/50-hinteros.rules".text = polkitRules;
    };

    # Per-profile disk use (profiles.md, "Per-profile storage"; DECISIONS D5): started by
    # hinteros-system over D-Bus when profiles.list finds the data older than an hour. Reads the
    # homes, writes /var/lib/hinteros/usage.json.
    systemd.services.hinteros-usage = {
      description = "HinterOS per-profile disk use";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe cfg.system.package} usage";
        User = "root";
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        ReadWritePaths = [ "/var/lib/hinteros" ];
        PrivateNetwork = true;
        NoNewPrivileges = true;
        Nice = 19;
        IOSchedulingClass = "idle";
      };
    };

    systemd = {
      services.hinteros-system = {
        description = "HinterOS system service";
        wantedBy = [ "multi-user.target" ];
        environment.RUST_LOG = cfg.logLevel;
        serviceConfig = {
          ExecStart = lib.getExe cfg.system.package;
          # Root, because it starts the jobs that rebuild the system. The socket is created in the
          # runtime directory, owned by root:hinteros, mode 0660.
          User = "root";
          Group = cfg.group;
          RuntimeDirectory = "hinteros";
          RuntimeDirectoryMode = "0755";
          # The job directories in /run/hinteros/jobs must survive a restart of this service
          # during a switch; the restarted service re-attaches to running jobs.
          RuntimeDirectoryPreserve = "yes";
          # /var/lib/hinteros (root, 0700): the update cache, staging and the git mirror.
          StateDirectory = "hinteros";
          StateDirectoryMode = "0700";
          Restart = "on-failure";
          RestartSec = 2;
          # It reads /etc/hinteros, /proc, the profile links and /run/current-system, and writes
          # only /run/hinteros. Everything that changes the system happens in hinteros-job@.
          ProtectSystem = "strict";
          ReadWritePaths = [
            "/run/hinteros"
            "/var/lib/hinteros"
          ];
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectControlGroups = true;
          # D-Bus (logind, polkit, systemd), the journal and its own socket; no network.
          RestrictAddressFamilies = [ "AF_UNIX" ];
          RestrictRealtime = true;
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          SystemCallFilter = [ "@system-service" ];
          # Only so the audit entries can read /proc/<pid>/exe of another user's process
          # (HINTEROS_EXE; with an empty set the field is "?").
          CapabilityBoundingSet = [ "CAP_SYS_PTRACE" ];
          # greeter.sock is root:hinteros-greeter 0660: a member may chgrp it without CAP_CHOWN.
          SupplementaryGroups = lib.optional greeterOn config.hinteros.profiles.greeter.user;
          UMask = "0007";
        };
      };

      # One job per unit instance (`hinteros-job@<id>`), started by hinteros-system over D-Bus:
      # a switch restarts hinteros-system when its unit changes, which must not kill the rebuild
      # that causes it. Root with network and no ProtectSystem: it switches the system.
      services."hinteros-job@" = {
        description = "HinterOS system job %i";
        # Neither the switch it performs nor a later one may restart or stop a running instance.
        restartIfChanged = false;
        stopIfChanged = false;
        path = jobPath;
        environment = {
          RUST_LOG = cfg.logLevel;
          SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
          HOME = "/root";
        };
        serviceConfig = {
          Type = "exec";
          ExecStart = "${lib.getExe cfg.system.package} job %i";
          User = "root";
          Nice = 10;
          IOSchedulingClass = "idle";
          KillMode = "control-group";
          StateDirectory = "hinteros";
          StateDirectoryMode = "0700";
        };
      };

      # User unit: applies to every user's manager, so restrict it to the accounts that may be
      # on screen (the hinteros group). The greeter runs its own instance (session.nix).
      # It is wanted by default.target, which the user manager reaches at autologin, i.e. at
      # the same time as the compositor and home app start.
      user.services.hinteros-session = {
        description = "HinterOS session daemon";
        wantedBy = [ "default.target" ];
        unitConfig.ConditionGroup = cfg.group;
        environment = {
          RUST_LOG = cfg.logLevel;
        }
        # Under cage the daemon sees no gamescope (so no child_env) and apps it launches inherit
        # its environment: point them at cage's Xwayland (its first X display) and socket.
        // lib.optionalAttrs (config.hinteros.session.compositor == "cage") {
          DISPLAY = ":0";
          WAYLAND_DISPLAY = "wayland-0";
        }
        # Under gamescope, GTK apps it starts (the OSK, native apps) must use Xwayland too: the
        # daemon passes WAYLAND_DISPLAY, GTK would prefer it, and gamescope never sizes Wayland
        # windows (session.nix). The OSK also needs X11 for GAMESCOPE_EXTERNAL_OVERLAY.
        // lib.optionalAttrs (config.hinteros.session.compositor == "gamescope") (
          {
            GDK_BACKEND = "x11";
          }
          # The large pointer theme for the apps it starts (gamescope scales the pointer).
          // config.hinteros.session.cursor.environment
        );
        serviceConfig = {
          # Under gamescope the daemon sees the same mode files gamescope was started with
          # (session.nix), so display.modes and display.set_mode find them.
          ExecStart =
            lib.optionalString (
              config.hinteros.session.compositor == "gamescope"
            ) "${config.hinteros.session.displayEnvWrapper} "
            + "${lib.getExe cfg.session.package} --config ${sessionConfig}";
          Restart = "on-failure";
          RestartSec = 1;
          NoNewPrivileges = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectControlGroups = true;
          RestrictRealtime = true;
          LockPersonality = true;
        };
      };
    };
  };
}
