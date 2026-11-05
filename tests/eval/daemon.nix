# Eval and build tests for daemon.nix, the module that gives hinteros-system what it needs
# (hinteros-daemon README, "What the system module must provide"): the sandboxed service, the job
# unit template, the polkit actions and rules, the per-generation files, the signer list. The
# share package is built (a few text files) and its contents checked.
{ self, pkgs }:
let
  inherit (pkgs) lib;

  state = {
    schemaVersion = 2;
    base = "unstable";
    stateVersion = "25.11";
    profiles = [ { id = "p1"; } ];
    requirements = [ ];
    services = [ ];
  };

  mk =
    extra:
    (self.lib.mkDevice {
      inherit state;
      extraModules = extra;
    }).config;

  key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
  c = mk [ ];
  withKey = mk [
    {
      hinteros.update.allowedSigners = [ "owner ${key} owner@hinteros" ];
      hinteros.dev.enable = true;
    }
  ];

  # A config that replaces the vendor's signers (release.nix sets them with mkDefault).
  noKey = mk [ { hinteros.update.allowedSigners = [ ]; } ];

  releaseVersion = lib.fileContents ../../release/version;
  releaseKey = "release ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAtzB3OuVIbG4WhjiNynpKPiTEJKdD5vicRouH8CQsrk hinteros-release";

  shareOf =
    cfg:
    lib.findFirst (
      p: lib.hasInfix "hinteros-system-share" (p.name or "")
    ) null cfg.environment.systemPackages;

  sys = c.systemd.services.hinteros-system.serviceConfig;
  rules = c.environment.etc."polkit-1/rules.d/50-hinteros.rules".text;
  job = c.systemd.services."hinteros-job@";
  channelLine = "git+${c.hinteros.update.repo}?ref=stable";
  template = builtins.readFile ../../nixos/templates/device-flake.nix.in;

  results = lib.runTests {
    # Profiles (DECISIONS D5): the session daemon runs for every account, the usage scan, and
    # the polkit grant that leaves ssh and the admin PIN reset to the admin password.
    testProfileUnits = {
      expr = [
        c.systemd.user.services.hinteros-session.unitConfig.ConditionGroup
        (c.systemd.user.services.hinteros-session.unitConfig ? ConditionUser)
        (lib.hasSuffix " usage" c.systemd.services.hinteros-usage.serviceConfig.ExecStart)
        c.systemd.services.hinteros-usage.serviceConfig.ProtectHome
        # Reads homes the profiles control: read/search only, no other capability.
        c.systemd.services.hinteros-usage.serviceConfig.CapabilityBoundingSet
        (lib.hasInfix ''action.id !== "org.hinteros.system.profiles.recover"'' rules)
        (lib.hasInfix "hinteros-greeter" rules)
        sys.SupplementaryGroups
      ];
      expected = [
        "hinteros"
        false
        true
        "read-only"
        [ "CAP_DAC_READ_SEARCH" ]
        true
        true
        # The Jellyfin setup's files, and greeter.sock's and keyboard.sock's groups (chgrp
        # without CAP_CHOWN).
        [
          "hinteros-system"
          "hinteros-greeter"
          "hinteros-keyboard"
        ]
      ];
    };
    # Ctrl+Super+D: the only reader of keyboards is its own sandboxed unit (no profile account
    # may read them); hinteros-system freezes profiles that are not in front.
    testKeyboardUnit =
      let
        s = c.systemd.services.hinteros-keyboard.serviceConfig;
        off = mk [ { hinteros.daemon.input.keyboardHome = false; } ];
      in
      {
        expr = [
          (lib.hasSuffix "/bin/hinteros-system keyboard-home" s.ExecStart)
          s.DynamicUser
          s.SupplementaryGroups
          s.DevicePolicy
          s.DeviceAllow
          s.CapabilityBoundingSet
          s.PrivateNetwork
          s.RestrictAddressFamilies
          s.ProtectSystem
          c.systemd.services.hinteros-keyboard.wantedBy
          (c.users.groups ? hinteros-keyboard)
          (lib.hasInfix "/bin/hinteros-system --freeze-inactive" sys.ExecStart)
          (lib.elem "input" c.users.users.hinteros-p1.extraGroups)
          (off.systemd.services ? hinteros-keyboard)
          (off.users.groups ? hinteros-keyboard)
          off.systemd.services.hinteros-system.serviceConfig.SupplementaryGroups
          off.hinteros.daemon.session.settings.input.keyboard_home
        ];
        expected = [
          true
          true
          [
            "input"
            "hinteros-keyboard"
          ]
          "closed"
          [ "char-input r" ]
          [ "" ]
          true
          [ "AF_UNIX" ]
          "strict"
          [ "multi-user.target" ]
          true
          true
          false
          false
          false
          [
            "hinteros-system"
            "hinteros-greeter"
          ]
          false
        ];
      };
    # The time zone helper (time-zone.md): the service itself never writes /etc; this oneshot,
    # started on demand, may write /etc/hinteros and /run/hinteros only (not all of /etc:
    # systemd-timedated, which NixOS ships bus-activated, replaces /etc/localtime), with no
    # network; its only capabilities reach the request and the lock in the service's run
    # directory.
    testTimeZoneApplyUnit =
      let
        u = c.systemd.services.hinteros-time-zone-apply;
        s = u.serviceConfig;
      in
      {
        expr = [
          s.Type
          s.User
          (lib.hasSuffix "/bin/hinteros-system time-zone-apply" s.ExecStart)
          s.ProtectSystem
          s.ReadWritePaths
          s.PrivateNetwork
          s.NoNewPrivileges
          s.ProtectHome
          s.CapabilityBoundingSet
          s.RestrictAddressFamilies
          u.wantedBy
          (lib.elem "/etc" sys.ReadWritePaths)
          (c.systemd.units ? "systemd-timedated.service")
          # Its bus activation file comes with systemd in the system path; it writes /etc/localtime
          # itself (not /etc/static, as with time.timeZone set).
          (lib.elem c.systemd.package c.environment.systemPackages)
          (c.systemd.services.systemd-timedated.environment ? SYSTEMD_ETC_LOCALTIME)
        ];
        expected = [
          "oneshot"
          "root"
          true
          "strict"
          [
            "/etc/hinteros"
            "/run/hinteros"
          ]
          true
          true
          true
          [
            "CAP_DAC_OVERRIDE"
            "CAP_CHOWN"
          ]
          [ "AF_UNIX" ]
          [ ]
          false
          true
          true
          false
        ];
      };
    # hinteros-system is not root (daemon README, "Privileges"): its own system account, no
    # capabilities, and on the system bus only its jobs, helper units and the freezer. The units
    # that read what it cannot run as it with read-only access; root's own state is apart.
    testServiceAccount =
      let
        svc = c.environment.etc."polkit-1/rules.d/40-hinteros-system.rules".text;
        usage = c.systemd.services.hinteros-usage.serviceConfig;
        boot = c.systemd.services.hinteros-boot-entries;
      in
      {
        expr = [
          sys.User
          sys.Group
          sys.AmbientCapabilities
          c.users.users.hinteros-system.isSystemUser
          (c.users.groups ? hinteros-system)
          usage.User
          usage.AmbientCapabilities
          boot.serviceConfig.User
          boot.serviceConfig.AmbientCapabilities
          (lib.hasSuffix "/bin/hinteros-system boot-entries" boot.serviceConfig.ExecStart)
          boot.wantedBy
          c.systemd.paths.hinteros-boot-entries.pathConfig.PathChanged
          (lib.elem "d /var/lib/hinteros-root 0710 root hinteros-system -" c.systemd.tmpfiles.rules)
          c.systemd.services.hinteros-lan-filter.serviceConfig.CapabilityBoundingSet
          (lib.hasInfix ''subject.user !== "hinteros-system"'' svc)
          (lib.hasInfix "org.freedesktop.systemd1.manage-units" svc)
          (lib.hasInfix ''^hinteros-job@[0-9a-f]{16}\.service$'' svc)
          (lib.hasInfix ''unit === "hinteros-usage.service"'' svc)
          (lib.hasInfix ''unit === "hinteros-time-zone-apply.service"'' svc)
          (lib.hasInfix ''verb === "restart" && job("restart") && unit === "hinteros-lan-filter.service"'' svc)
          # The method, not only the verb: StartTransientUnit and StopUnit ask with other messages.
          (lib.hasInfix ''verb === "start" && job("start")'' svc)
          (lib.hasInfix "freeze or thaw the processes of" svc)
          (lib.hasInfix "return polkit.Result.NO;" svc)
        ];
        expected = [
          "hinteros-system"
          "hinteros"
          [ "" ]
          true
          true
          "hinteros-system"
          [ "CAP_DAC_READ_SEARCH" ]
          "hinteros-system"
          [ "CAP_DAC_READ_SEARCH" ]
          true
          [ "hinteros-system.service" ]
          "/boot/loader/entries"
          true
          [
            "CAP_NET_ADMIN"
            "CAP_DAC_READ_SEARCH"
          ]
          true
          true
          true
          true
          true
          true
          true
          true
          true
        ];
      };
    testSystemService = {
      expr = [
        sys.RuntimeDirectoryPreserve
        sys.ProtectSystem
        sys.ReadWritePaths
        sys.CapabilityBoundingSet
        sys.RestrictAddressFamilies
        sys.MemoryDenyWriteExecute
        sys.SystemCallFilter
        sys.StateDirectoryMode
        c.systemd.services.hinteros-system.restartIfChanged
      ];
      expected = [
        "yes"
        "strict"
        [
          "/run/hinteros"
          "/var/lib/hinteros"
        ]
        [ "" ]
        [ "AF_UNIX" ]
        true
        [ "@system-service" ]
        "0700"
        true
      ];
    };
    testJobTemplate = {
      expr = [
        job.restartIfChanged
        job.stopIfChanged
        job.serviceConfig.User
        (job.serviceConfig ? ProtectSystem)
        (lib.hasSuffix " job %i" job.serviceConfig.ExecStart)
        job.serviceConfig.KillMode
        job.serviceConfig.Type
        (job.serviceConfig ? StateDirectory)
        (lib.all (n: lib.elem n (map lib.getName job.path)) [
          "nix"
          "git-minimal"
          "openssh"
          "nixos-facter"
          "coreutils"
        ])
      ];
      expected = [
        false
        false
        "root"
        false
        true
        "control-group"
        "exec"
        false
        true
      ];
    };
    testRules = {
      expr = [
        (lib.hasInfix ''action.id !== "org.hinteros.system.ssh"''
          c.environment.etc."polkit-1/rules.d/50-hinteros.rules".text
        )
        (lib.hasInfix ''subject.isInGroup("hinteros")''
          c.environment.etc."polkit-1/rules.d/50-hinteros.rules".text
        )
      ];
      expected = [
        true
        true
      ];
    };
    # The session daemon's polkit agent needs the socket-activated helper (the session unit keeps
    # NoNewPrivileges, which defeats the setuid helper); nixpkgs' polkit module wires the socket.
    testAgentHelperSocket = {
      expr = [
        (c.systemd.sockets ? polkit-agent-helper)
        (c.systemd.sockets.polkit-agent-helper.wantedBy or [ ])
        c.systemd.user.services.hinteros-session.serviceConfig.NoNewPrivileges
      ];
      expected = [
        true
        [ "sockets.target" ]
        true
      ];
    };
    # The Store index and the terms are read from /run/current-system/sw/share/hinteros.
    testCatalogOnPath = {
      expr = [
        (lib.elem c.hinteros.catalog.index c.environment.systemPackages)
        (lib.elem "/share/hinteros" c.environment.pathsToLink)
      ];
      expected = [
        true
        true
      ];
    };
    # lib.catalogIds: what the daemon's `nix eval ...#lib.catalogIds` reads from a target revision.
    # `kind` lets it tell new apps from new services.
    testCatalogIds = {
      expr = [
        (lib.attrNames self.lib.catalogIds == lib.attrNames c.hinteros.catalog.entries)
        (lib.all (
          e:
          lib.attrNames e == [
            "kind"
            "name"
            "status"
            "statusReason"
          ]
        ) (lib.attrValues self.lib.catalogIds))
        self.lib.catalogIds.crunchyroll.name
        self.lib.catalogIds.crunchyroll.status
        self.lib.catalogIds.crunchyroll.kind
        self.lib.catalogIds.jellyfin-server.kind
      ];
      expected = [
        true
        true
        "Crunchyroll"
        "available"
        "app"
        "service"
      ];
    };
    testDaemonsInSystemPath = {
      expr = map lib.getName (
        lib.filter (p: lib.hasPrefix "hinteros-s" (lib.getName p)) c.environment.systemPackages
      );
      expected = [
        "hinteros-session"
        "hinteros-system"
        "hinteros-system-share"
      ];
    };
    # The device flake's input line must be the one channels.json describes.
    testTemplateMatchesChannels = {
      expr = lib.hasInfix ''inputs.hinteros.url = "git+%REPO%?ref=%CHANNEL%";'' template;
      expected = true;
    };
    # InputPlumber 0.81 never answers SendEvent (the RT click) without the overlay's patch; the
    # service runs the patched package (input-layer checks the click itself).
    testInputPlumberPatched = {
      expr = [
        (map baseNameOf (c.services.inputplumber.package.patches or [ ]))
        c.services.inputplumber.package.version
        (lib.elem c.services.inputplumber.package c.services.udev.packages)
      ];
      expected = [
        [
          "send-event-no-blocking-send.patch"
          "pointer-response-curve.patch"
          "xpad-uhid-poll-rate.patch"
          "dbus-clear-on-pass.patch"
          "send-event-keep-active-inputs.patch"
        ]
        "0.81.0"
        true
      ];
    };
    # The session daemon gets the large pointer theme for the apps it starts (gamescope).
    testDaemonCursorEnvironment = {
      expr =
        let
          env = c.systemd.user.services.hinteros-session.environment;
        in
        [
          env.XCURSOR_THEME
          env.XCURSOR_SIZE
          (lib.hasSuffix "-adwaita-icon-theme-${pkgs.adwaita-icon-theme.version}/share/icons:/run/current-system/sw/share/icons" env.XCURSOR_PATH)
          ((c.hinteros.daemon.session.settings.pointer or { }) ? idle_ms)
        ];
      expected = [
        "Adwaita"
        "256"
        true
        false
      ];
    };
    # release.nix (nixosModules.default): the vendor's version, signers and (still no) cache keys
    # from release/; a device definition replaces the signers rather than adding to them; the
    # individual daemon module alone trusts nobody.
    testReleaseTrust = {
      expr = [
        c.hinteros.release.version
        (lib.elem releaseKey c.hinteros.update.allowedSigners)
        c.hinteros.cache.publicKeys
        c.hinteros.cache.enable
        withKey.hinteros.update.allowedSigners
        noKey.hinteros.update.allowedSigners
        (lib.evalModules {
          modules = [
            ../../nixos/modules/daemon.nix
            {
              _module.check = false;
              _module.args.pkgs = pkgs;
            }
          ];
        }).config.hinteros.update.allowedSigners
      ];
      expected = [
        releaseVersion
        true
        [ ]
        false
        [ "owner ${key} owner@hinteros" ]
        [ ]
        [ ]
      ];
    };
    testBadSignerRejected = {
      expr =
        lib.any (a: !a.assertion)
          (mk [ { hinteros.update.allowedSigners = [ "owner ssh-rsa AAAA" ]; } ]).assertions;
      expected = true;
    };
  };

  share = shareOf c;
  shareKey = shareOf withKey;
  shareNoKey = shareOf noKey;
  bootstrapChannel = lib.findFirst (
    p: lib.getName p == "hinteros-bootstrap-channel"
  ) null c.environment.systemPackages;
in
assert share != null;
assert bootstrapChannel != null;
pkgs.runCommand "hinteros-daemon-eval"
  {
    nativeBuildInputs = [ pkgs.jq ];
    inherit
      share
      shareKey
      shareNoKey
      bootstrapChannel
      channelLine
      releaseVersion
      ;
    failures = if results == [ ] then "" else builtins.toJSON results;
  }
  ''
    if [ -n "$failures" ]; then echo "$failures" >&2; exit 1; fi
    cd $share/share
    [ "$(jq -c . hinteros/release.json)" = "{\"dev\":false,\"version\":\"$releaseVersion\"}" ]
    [ "$(jq -c . hinteros/update/channels.json)" = '{"branches":{"beta":"beta","stable":"stable"},"repo":"https://git.hinteros.org/hinteros.git"}' ]
    # The vendor's release and backup keys (release/allowed_signers, through release.nix), namespace pinned,
    # and nothing else.
    [ "$(grep -v '^#' hinteros/update/allowed_signers | grep -c .)" = 2 ]
    grep -qx 'backup namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAk10EKzqLAzjITxmiUbyzae4iweuOqVpnTqqf4y7TiF hinteros-backup' hinteros/update/allowed_signers
    grep -qx 'release namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAtzB3OuVIbG4WhjiNynpKPiTEJKdD5vicRouH8CQsrk hinteros-release' hinteros/update/allowed_signers
    # Signers replaced by an empty list: only comments, so nothing verifies.
    ! grep -v '^#' $shareNoKey/share/hinteros/update/allowed_signers | grep -q .
    grep -q 'update verifies' $shareNoKey/share/hinteros/update/allowed_signers
    # polkit: every action is "no" except ssh (the admin password, with a message the launcher shows).
    for a in settings rebuild update.check update.apply rollback channel jobs.cancel apps profiles profiles.create starter services ssh profiles.recover; do
      grep -q "org.hinteros.system.$a\"" polkit-1/actions/org.hinteros.system.policy
    done
    [ "$(grep -c '<allow_any>no</allow_any>' polkit-1/actions/org.hinteros.system.policy)" = 12 ]
    # ssh and profiles.recover (the admin profile's PIN reset) need the admin account's password.
    [ "$(grep -c '<allow_active>auth_admin</allow_active>' polkit-1/actions/org.hinteros.system.policy)" = 2 ]
    grep -q '<message>Authentication is required to turn remote login (SSH) on or off</message>' polkit-1/actions/org.hinteros.system.policy
    ! grep -q 'org.hinteros.system.ssh.admin' polkit-1/actions/org.hinteros.system.policy
    # The service account owns every action (it asks about other users' processes; not root).
    [ "$(grep -c '<annotate key="org.freedesktop.policykit.owner">unix-user:hinteros-system</annotate>' polkit-1/actions/org.hinteros.system.policy)" = 14 ]
    # With a key: the principal, the pinned namespace, the key, and dev in release.json.
    grep -qx 'owner namespaces="git" ssh-ed25519 .* owner@hinteros' $shareKey/share/hinteros/update/allowed_signers
    [ "$(jq .dev $shareKey/share/hinteros/release.json)" = true ]
    # The channel bootstrap script is on PATH (and passed shellcheck to get built).
    [ -x $bootstrapChannel/bin/hinteros-bootstrap-channel ]
    # ... without its test hooks (tests/vm/bootstrap-channel.nix): a box ignores HINTEROS_CONFIG_DIR etc.
    grep -qx test_hooks=0 $bootstrapChannel/bin/hinteros-bootstrap-channel
    echo "$channelLine" > $out
  ''
