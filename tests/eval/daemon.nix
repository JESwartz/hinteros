# Eval and build tests for daemon.nix, the module that gives hinteros-system what it needs
# (hinteros-daemon README, "What the system module must provide"): the sandboxed service, the job
# unit template, the polkit actions and rules, the per-generation files, the signer list. The
# share package is built (a few text files) and its contents checked.
{ self, pkgs }:
let
  inherit (pkgs) lib;

  state = {
    schemaVersion = 1;
    profiles = [
      {
        id = "p1";
        name = "T";
        user = "tester";
      }
    ];
  };

  mk =
    extra:
    (self.lib.mkDevice {
      inherit state;
      extraModules = [ { system.stateVersion = "25.11"; } ] ++ extra;
    }).config;

  key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
  c = mk [ ];
  withKey = mk [
    {
      hinteros.update.allowedSigners = [ "owner ${key} owner@hinteros" ];
      hinteros.dev.enable = true;
    }
  ];

  shareOf =
    cfg:
    lib.findFirst (
      p: lib.hasInfix "hinteros-system-share" (p.name or "")
    ) null cfg.environment.systemPackages;

  sys = c.systemd.services.hinteros-system.serviceConfig;
  job = c.systemd.services."hinteros-job@";
  channelLine = "git+${c.hinteros.update.repo}?ref=stable";
  template = builtins.readFile ../../nixos/templates/device-flake.nix.in;

  results = lib.runTests {
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
        [ "/run/hinteros" ]
        [ "CAP_SYS_PTRACE" ]
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
        (lib.all (n: lib.elem n (map lib.getName job.path)) [
          "nix"
          "git"
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
    testCatalogIds = {
      expr = [
        (lib.attrNames self.lib.catalogIds == lib.attrNames c.hinteros.catalog.entries)
        (lib.all (
          e:
          lib.attrNames e == [
            "name"
            "status"
            "statusReason"
          ]
        ) (lib.attrValues self.lib.catalogIds))
        self.lib.catalogIds.crunchyroll.name
        self.lib.catalogIds.crunchyroll.status
      ];
      expected = [
        true
        true
        "Crunchyroll"
        "available"
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
    testBadSignerRejected = {
      expr =
        lib.any (a: !a.assertion)
          (mk [ { hinteros.update.allowedSigners = [ "owner ssh-rsa AAAA" ]; } ]).assertions;
      expected = true;
    };
  };

  share = shareOf c;
  shareKey = shareOf withKey;
in
assert share != null;
pkgs.runCommand "hinteros-daemon-eval"
  {
    nativeBuildInputs = [ pkgs.jq ];
    inherit share shareKey channelLine;
    failures = if results == [ ] then "" else builtins.toJSON results;
  }
  ''
    if [ -n "$failures" ]; then echo "$failures" >&2; exit 1; fi
    cd $share/share
    [ "$(jq -c . hinteros/release.json)" = '{"dev":false,"version":"0.1.0-dev"}' ]
    [ "$(jq -c . hinteros/update/channels.json)" = '{"branches":{"beta":"beta","stable":"stable"},"repo":"https://justsomeshed.com/JSwartz/HinterOS/hinteros.git"}' ]
    # No signers by default: only comments, so nothing verifies.
    ! grep -v '^#' hinteros/update/allowed_signers | grep -q .
    grep -q 'update verifies' hinteros/update/allowed_signers
    # polkit: every action is "no" except ssh (the admin password, with a message the launcher shows).
    for a in settings rebuild update.check update.apply rollback channel jobs.cancel apps; do
      grep -q "org.hinteros.system.$a\"" polkit-1/actions/org.hinteros.system.policy
    done
    [ "$(grep -c '<allow_any>no</allow_any>' polkit-1/actions/org.hinteros.system.policy)" = 8 ]
    [ "$(grep -c '<allow_active>auth_admin</allow_active>' polkit-1/actions/org.hinteros.system.policy)" = 1 ]
    grep -q '<message>Authentication is required to turn remote login (SSH) on or off</message>' polkit-1/actions/org.hinteros.system.policy
    ! grep -q 'org.hinteros.system.ssh.admin' polkit-1/actions/org.hinteros.system.policy
    # With a key: the principal, the pinned namespace, the key, and dev in release.json.
    grep -qx 'owner namespaces="git" ssh-ed25519 .* owner@hinteros' $shareKey/share/hinteros/update/allowed_signers
    [ "$(jq .dev $shareKey/share/hinteros/release.json)" = true ]
    echo "$channelLine" > $out
  ''
