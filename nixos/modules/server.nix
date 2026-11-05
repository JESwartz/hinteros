# The Server section (M10, design/server.md): what the system gives the enabled catalog services
# (`hinteros.catalog.services`, state.json `services`) beyond their restricted `service` modules,
# which may not touch the network. Driven by the entries' metadata:
#   - the firewall from their `ports`: `lan` → the local networks (`hinteros.ssh.allowFrom`, the
#     same list as SSH) and, with Tailscale on, `tailscale0`; `any` → all sources. SSH is open on
#     `tailscale0` too while both are on;
#   - `/srv/media` (root:hinteros-media 2775, default ACL group rx): the media folder. The
#     admin account copies in, Jellyfin and Plex read;
#   - Jellyfin: `hinteros-jellyfin-setup.service` runs the first-run wizard in a private network
#     namespace before `jellyfin.service` may start (below); hardware transcoding on Intel GPUs;
#   - Plex: the render device and the media group (its unfree package is allowed by catalog.nix
#     only while it is on);
#   - Tailscale: the `tailscale` CLI for hinteros-system and its jobs (login is a job);
#   - Cloudflare Tunnel: `hinteros-cloudflared.service` while a token is stored, kept off the box's
#     own ports except the servers' by an nftables rule on its cgroup;
#   - hinteros-system may talk HTTP to loopback (status of Jellyfin, Plex and cloudflared).
#
# What hinteros-system relies on (the daemon's side, system API 0.5): `/var/lib/hinteros/services/
# <id>/` (0700, the service's account) per enabled service; for Jellyfin `setup-done`, `admin-password`
# and `api-key` (0640 root:hinteros-system, no trailing newline) in `/var/lib/hinteros-root/
# jellyfin-server` (root's: the service is not root), the server at http://127.0.0.1:8096; Plex at
# http://127.0.0.1:32400 with `/var/lib/plex/Plex Media Server/Preferences.xml`; the tunnel token
# at `/var/lib/hinteros/services/cloudflare-tunnel/token`, the unit `hinteros-cloudflared.service`,
# its metrics at http://127.0.0.1:20241 (`/ready`); `tailscale` on PATH with the socket
# `/run/tailscale/tailscaled.sock`; `/srv/media` of group `hinteros-media`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hinteros;
  # Without the catalog module (a config that imports modules/ alone) there are no services.
  services = cfg.catalog.services or [ ];
  entries = cfg.catalog.entries or { };
  on = id: lib.elem id services;
  jellyfinOn = on "jellyfin-server";
  plexOn = on "plex-media-server";
  tailscaleOn = on "tailscale";
  cloudflareOn = on "cloudflare-tunnel";

  localNets = import ../lib/local-networks.nix { inherit lib; };
  ports = lib.concatMap (id: entries.${id}.ports or [ ]) services;
  portsWhere = pred: lib.unique (map (p: p.port) (lib.filter pred ports));
  lanPorts = proto: portsWhere (p: p.from == "lan" && p.proto == proto);
  anyPorts = proto: portsWhere (p: p.from == "any" && p.proto == proto);
  allPorts = proto: portsWhere (p: p.proto == proto);
  lanRule = proto: {
    from = cfg.ssh.allowFrom;
    inherit proto;
    ports = lanPorts proto;
    comment = "hinteros-server";
  };
  hasLan = lanPorts "tcp" != [ ] || lanPorts "udp" != [ ];

  stateRoot = "/var/lib/hinteros/services";
  # The Jellyfin setup's files (setup-done, admin-password, api-key): root's, in root's HinterOS
  # directory, readable by hinteros-system's group (account and group of the same name). The
  # service (not root) owns stateRoot: no root unit writes there (its jobs do it carefully).
  jfState = "/var/lib/hinteros-root/jellyfin-server";
  serviceUser = "hinteros-system";
  jfGroup = if cfg.daemon.enable then serviceUser else "root";
  cfToken = "${stateRoot}/cloudflare-tunnel/token";

  jf = config.services.jellyfin;
  jfDirs = lib.unique [
    jf.dataDir
    jf.configDir
    jf.logDir
    jf.cacheDir
  ];
  # The nixpkgs unit's command line, so the wizard sees the server the real unit starts.
  jfCommand = "${lib.getExe jf.package} --datadir '${jf.dataDir}' --configdir '${jf.configDir}' --cachedir '${jf.cacheDir}' --logdir '${jf.logDir}'";

  # Jellyfin's first run (design/server.md, "Jellyfin first run"). An unconfigured Jellyfin lets
  # anyone who reaches it create the admin, so it never runs where anyone could: this unit has
  # PrivateNetwork (loopback only, its own) and starts Jellyfin in it as the jellyfin user, does
  # the wizard over loopback, makes the API key for hinteros-system, stops it and writes the
  # results. jellyfin.service requires this unit: when the setup fails, Jellyfin does not start.
  #
  # Interrupted runs: `setup-started` is written before Jellyfin first starts and removed after
  # `setup-done`. A run that finds it (or no `setup-done`) starts from scratch: it deletes what
  # Jellyfin wrote (its data, config, log and cache directories) and generates a new password.
  # With `setup-done` and a completed wizard there is nothing to do. With `setup-done` but no
  # completed wizard (Jellyfin's data was deleted, our directory kept) it sets up again. A
  # completed wizard that HinterOS did not set up (no marker of ours: a Jellyfin set up by hand
  # before M10) is never deleted: the setup fails, so Jellyfin stays off until its data is
  # removed (Turn off with "Delete server data").
  jfSetup = pkgs.writeShellApplication {
    name = "hinteros-jellyfin-setup";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.findutils
      pkgs.gnugrep
      pkgs.jq
      pkgs.util-linux
    ];
    text = ''
      state=${lib.escapeShellArg jfState}
      config=${lib.escapeShellArg jf.configDir}
      api=http://127.0.0.1:8096
      umask 077

      wizard_done() {
        grep -qs '<IsStartupWizardCompleted>true</IsStartupWizardCompleted>' "$config/system.xml"
      }

      if [ -e "$state/setup-done" ]; then
        if wizard_done; then
          exit 0
        fi
        echo "Jellyfin data is gone: set up again"
        touch "$state/setup-started"
        rm -f "$state/setup-done"
      fi
      if wizard_done && [ ! -e "$state/setup-started" ]; then
        echo "$config holds a Jellyfin that HinterOS did not set up. Delete the Jellyfin data to set up again." >&2
        exit 1
      fi

      # From scratch.
      touch "$state/setup-started"
      rm -f "$state/admin-password" "$state/api-key"
      for d in ${lib.escapeShellArgs jfDirs}; do
        if [ -d "$d" ]; then
          find "$d" -mindepth 1 -delete
        fi
        install -d -m 0700 -o ${jf.user} -g ${jf.group} "$d"
      done

      password=$(head -c 18 /dev/urandom | base64 | tr '+/' '-_')
      work=$(mktemp -d)
      client='MediaBrowser Client="HinterOS", Device="HinterOS", DeviceId="hinteros-setup", Version="1"'
      printf 'Authorization: %s\n' "$client" > "$work/auth"

      cd ${lib.escapeShellArg jf.dataDir}
      setpriv --reuid=${jf.user} --regid=${jf.group} --init-groups --reset-env -- ${jfCommand} &
      pid=$!
      echo "Jellyfin started (pid $pid), waiting for it"
      stop() {
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
      }
      trap stop EXIT
      # Running and not a zombie (not waited for yet).
      alive() {
        [ -r "/proc/$pid/stat" ] && ! grep -q "^$pid ([^)]*) Z" "/proc/$pid/stat"
      }

      # Secrets go through files and the environment, never the command line (/proc).
      call() {
        local method=$1 path=$2
        shift 2
        curl -fsS -m 120 -X "$method" -H "@$work/auth" -H 'Content-Type: application/json' "$@" "$api$path"
      }

      ready=
      for _ in $(seq 900); do
        if ! alive; then
          echo "Jellyfin stopped during setup" >&2
          exit 1
        fi
        # While it starts, Jellyfin runs a stand-in server on the same port that says "Degraded"
        # (and answers /System/Info/Public too); only the real server says "Healthy".
        if [ "$(curl -fsS -m 5 "$api/health" 2>/dev/null)" = Healthy ]; then
          ready=1
          break
        fi
        sleep 1
      done
      if [ -z "$ready" ]; then
        echo "Jellyfin did not start in 15 minutes" >&2
        exit 1
      fi

      echo "Jellyfin is up: running the wizard"
      # GET /Startup/User makes the first user (Jellyfin 10.11+ StartupController).
      call GET /Startup/User >/dev/null
      NAME=$(cat /proc/sys/kernel/hostname) jq -n \
        '{ServerName: env.NAME, UICulture: "en-US", MetadataCountryCode: "US", PreferredMetadataLanguage: "en"}' |
        call POST /Startup/Configuration --data-binary @-
      PW=$password jq -n '{Name: "admin", Password: env.PW}' | call POST /Startup/User --data-binary @-
      # Jellyfin treats the tailnet (100.64.0.0/10) as remote; the firewall decides who gets in.
      echo '{"EnableRemoteAccess": true}' | call POST /Startup/RemoteAccess --data-binary @-
      call POST /Startup/Complete

      PW=$password jq -n '{Username: "admin", Pw: env.PW}' |
        call POST /Users/AuthenticateByName --data-binary @- > "$work/session"
      token=$(jq -er .AccessToken "$work/session")
      printf 'Authorization: %s, Token="%s"\n' "$client" "$token" > "$work/auth"
      call POST '/Auth/Keys?app=hinteros'
      call GET /Auth/Keys > "$work/keys"
      key=$(jq -er '[.Items[] | select(.AppName == "hinteros")][0].AccessToken' "$work/keys")
      printf 'Authorization: MediaBrowser Token="%s"\n' "$key" > "$work/auth"
      call GET /System/Info >/dev/null
      echo "Wizard done, API key made: stopping Jellyfin"

      stop
      trap - EXIT
      ${lib.optionalString jf.hardwareAcceleration.enable ''
        # Jellyfin wrote its default encoding.xml; the real unit writes ours once, when none is there.
        rm -f "$config/encoding.xml"
      ''}
      sync -f ${lib.escapeShellArg jf.dataDir}

      printf '%s' "$password" > "$state/admin-password.new"
      printf '%s' "$key" > "$state/api-key.new"
      chmod 0640 "$state/admin-password.new" "$state/api-key.new"
      sync "$state/admin-password.new" "$state/api-key.new"
      mv "$state/admin-password.new" "$state/admin-password"
      mv "$state/api-key.new" "$state/api-key"
      touch "$state/setup-done"
      sync -f "$state"
      rm -f "$state/setup-started"
      rm -rf "$work"
      echo "Jellyfin is set up"
    '';
  };

  # The Jellyfin app's sign-in page (spike S1): jellyfin-web with `hinteros/signin.html` and
  # `signin.js` added, bound read-only over the web directory the server is started with
  # (`--webdir` in the package's wrapper), so Jellyfin serves it at /web/hinteros/signin.html
  # without a rebuild of the server. The session daemon starts the app there with the profile's
  # token in the fragment; the page stores jellyfin-web's login and opens /web/index.html.
  jfWebDir =
    let
      flag = lib.findFirst (lib.hasPrefix "--webdir=") null (jf.package.makeWrapperArgs or [ ]);
    in
    if flag == null then
      "${pkgs.jellyfin-web}/share/jellyfin-web"
    else
      lib.removePrefix "--webdir=" flag;
  jfWeb = pkgs.runCommand "jellyfin-web-hinteros" { } ''
    # A copy, not links: inside the unit the links would point at the bound directory itself.
    cp -r --no-preserve=mode ${jfWebDir} $out
    mkdir $out/hinteros
    cp ${./jellyfin-signin.html} $out/hinteros/signin.html
    cp ${./jellyfin-signin.js} $out/hinteros/signin.js
  '';

  # The tunnel may reach the box's own addresses (a private-network route to the box points at
  # its LAN address, and loopback) only on the servers' ports: whatever else listens on the box
  # (sshd, the session, a game's server) stays off the route. Replies to connections others
  # opened (the metrics port) pass. Other destinations are the owner's routes. nft resolves the
  # cgroup path when it loads the table, so the unit loads it itself, once its cgroup exists
  # (ExecStartPre, again on every restart); when that fails the tunnel does not start.
  cfRules =
    let
      tcp = allPorts "tcp";
      udp = allPorts "udp";
      set = ps: lib.concatMapStringsSep ", " toString ps;
    in
    pkgs.writeText "hinteros-cloudflared.nft" ''
      table inet hinteros_cloudflared
      delete table inet hinteros_cloudflared
      table inet hinteros_cloudflared {
        chain output {
          type filter hook output priority filter; policy accept;
          socket cgroupv2 level 2 "system.slice/hinteros-cloudflared.service" jump cloudflared
        }
        chain cloudflared {
          ct direction reply accept
          ${lib.optionalString (tcp != [ ]) "fib daddr type local tcp dport { ${set tcp} } accept"}
          ${lib.optionalString (udp != [ ]) "fib daddr type local udp dport { ${set udp} } accept"}
          ${lib.optionalString config.services.resolved.enable "ip daddr 127.0.0.53 meta l4proto { tcp, udp } th dport 53 accept"}
          fib daddr type local meta l4proto tcp reject with tcp reset
          fib daddr type local drop
        }
      }
    '';
in
{
  config = lib.mkMerge [
    # The media folder, on every HinterOS box (people copy media in before turning a server on).
    # setgid keeps new files in the group; the default ACL gives the group read on what is copied
    # in with its own group kept (cp -a, rsync -a).
    (lib.mkIf cfg.session.enable {
      users.groups.hinteros-media = { };
      users.users = lib.mkIf cfg.admin.enable {
        ${cfg.admin.user}.extraGroups = [ "hinteros-media" ];
      };
      systemd.tmpfiles.rules = [
        "d /srv/media 2775 root hinteros-media -"
        "A /srv/media - - - - d:g:hinteros-media:rx"
      ];
    })

    # The services' directories in hinteros-system's state (its StateDirectory, which systemd
    # gives to its account): the service's own, as the service is not root.
    (lib.mkIf (services != [ ] && cfg.daemon.enable) {
      systemd.tmpfiles.rules = [
        "d ${stateRoot} 0700 ${serviceUser} ${cfg.daemon.group} -"
      ]
      ++ map (id: "d ${stateRoot}/${id} 0700 ${serviceUser} ${cfg.daemon.group} -") services;
    })

    # The Jellyfin setup's own directory in root's HinterOS state (its sandbox needs it before it
    # starts): setgid, so its files take the group the service reads them with.
    (lib.mkIf jellyfinOn {
      systemd.tmpfiles.rules = [ "d ${jfState} 2750 root ${jfGroup} -" ];
    })

    # Firewall: `any` ports to all sources, `lan` ports to the local networks only.
    {
      networking.firewall = lib.mkMerge [
        {
          allowedTCPPorts = anyPorts "tcp";
          allowedUDPPorts = anyPorts "udp";
        }
        (lib.mkIf (hasLan && config.networking.nftables.enable) {
          extraInputRules = localNets.nftRules (lanRule "tcp") + localNets.nftRules (lanRule "udp");
        })
        (lib.mkIf (hasLan && !config.networking.nftables.enable) {
          extraCommands =
            localNets.iptablesRules (lanRule "tcp" // { ipv6 = config.networking.enableIPv6; })
            + localNets.iptablesRules (lanRule "udp" // { ipv6 = config.networking.enableIPv6; });
        })
        # The tailnet counts as local: the `lan` ports, and SSH while it is on.
        (lib.mkIf tailscaleOn {
          interfaces.${config.services.tailscale.interfaceName} = {
            allowedTCPPorts =
              lanPorts "tcp" ++ lib.optionals config.services.openssh.enable config.services.openssh.ports;
            allowedUDPPorts = lanPorts "udp";
          };
        })
      ];
      assertions = lib.optional hasLan {
        assertion = lib.all localNets.isCidr cfg.ssh.allowFrom;
        message = "hinteros server: hinteros.ssh.allowFrom: every entry must be an IPv4 or IPv6 CIDR (e.g. 192.168.0.0/16, fe80::/10).";
      };
    }

    # hinteros-system reads the servers' status over loopback HTTP, nothing else over IP.
    (lib.mkIf (cfg.daemon.enable && (jellyfinOn || plexOn || cloudflareOn)) {
      systemd.services.hinteros-system.serviceConfig = {
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
        IPAddressDeny = "any";
        IPAddressAllow = "localhost";
      };
    })

    (lib.mkIf jellyfinOn {
      users.users.${jf.user}.extraGroups = [
        "hinteros-media"
        "render"
        "video"
      ];

      # Intel Quick Sync is not in nixpkgs' ffmpeg for Skylake-class GPUs (libvpl's runtime there
      # is the end-of-life Media SDK), so VA-API through Intel's media driver. Written once: the
      # dashboard may change it. Decoding: what the Skylake iGPU does in hardware (H.264, HEVC
      # 8-bit, VC-1, VP8; nixpkgs' `mpeg2` writes a codec name Jellyfin does not know).
      services.jellyfin = lib.mkIf cfg.hardware.intelVideo.enable {
        hardwareAcceleration = {
          enable = true;
          type = "vaapi";
          device = "/dev/dri/renderD128";
        };
        forceEncodingConfig = false;
        transcoding.hardwareDecodingCodecs = {
          h264 = true;
          hevc = true;
          vc1 = true;
          vp8 = true;
        };
      };

      systemd.services.jellyfin.serviceConfig.BindReadOnlyPaths = [ "${jfWeb}:${jfWebDir}" ];

      systemd.services.hinteros-jellyfin-setup = {
        description = "HinterOS: set up Jellyfin in a private network";
        before = [ "jellyfin.service" ];
        requiredBy = [ "jellyfin.service" ];
        after = [ "local-fs.target" ];
        # Nothing to do again on a switch; a restart would also restart Jellyfin.
        restartIfChanged = false;
        unitConfig.RequiresMountsFor = jfDirs;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          # Its own sandbox needs the directories; a deleted one comes back here.
          ExecStartPre = "+${pkgs.writeShellScript "hinteros-jellyfin-dirs" ''
            # Root's directory (the service's group may only pass), then the setup's own, whose
            # files take the group (setgid) for the service to read.
            ${pkgs.coreutils}/bin/install -d -m 0710 -g ${jfGroup} /var/lib/hinteros-root
            ${pkgs.coreutils}/bin/install -d -m 2750 -g ${jfGroup} ${jfState}
            ${lib.concatMapStringsSep "\n" (
              d: "${pkgs.coreutils}/bin/install -d -m 0700 -o ${jf.user} -g ${jf.group} ${lib.escapeShellArg d}"
            ) jfDirs}
          ''}";
          ExecStart = lib.getExe jfSetup;
          TimeoutStartSec = "20min";
          # Jellyfin ignores SIGTERM while it starts; a stopped setup starts again from scratch.
          TimeoutStopSec = "15s";
          User = "root";
          PrivateNetwork = true;
          ProtectSystem = "strict";
          ReadWritePaths = jfDirs ++ [ jfState ];
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectKernelLogs = true;
          ProtectControlGroups = true;
          ProtectClock = true;
          ProtectHostname = true;
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
            "AF_NETLINK"
          ];
          # Delete and recreate Jellyfin's directories, start and stop it as its user.
          CapabilityBoundingSet = [
            "CAP_KILL"
            "CAP_CHOWN"
            "CAP_DAC_OVERRIDE"
            "CAP_FOWNER"
            "CAP_SETUID"
            "CAP_SETGID"
          ];
          SystemCallArchitectures = "native";
          SystemCallFilter = [ "@system-service" ];
          UMask = "0077";
        };
      };
    })

    (lib.mkIf plexOn {
      users.users.${config.services.plex.user}.extraGroups = [
        "hinteros-media"
        "render"
        "video"
      ];
    })

    # hinteros-system reads Plex's Preferences.xml for its status (claimed, name). It is not root:
    # the file must be readable by Plex's group (the service is in it) or by all.
    (lib.mkIf (plexOn && cfg.daemon.enable) {
      systemd.services.hinteros-system.serviceConfig.SupplementaryGroups = [
        config.services.plex.group
      ];
    })

    # `tailscale login`/`logout`/`status` are hinteros-system's (status) and its jobs' (login).
    (lib.mkIf (cfg.daemon.enable && tailscaleOn) {
      systemd.services.hinteros-system.path = [ config.services.tailscale.package ];
      systemd.services."hinteros-job@".path = [ config.services.tailscale.package ];
    })

    (lib.mkIf cloudflareOn {
      systemd.services.hinteros-cloudflared = {
        description = "HinterOS: Cloudflare Tunnel";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [
          "network-online.target"
          "nftables.service"
          "firewall.service"
        ];
        # hinteros-system writes the token (cloudflare.set_token) and starts the unit.
        unitConfig.ConditionPathExists = cfToken;
        serviceConfig = {
          ExecStartPre = "+${lib.getExe pkgs.nftables} -f ${cfRules}";
          ExecStart = "${lib.getExe pkgs.cloudflared} tunnel --no-autoupdate --metrics 127.0.0.1:20241 run --token-file %d/token";
          LoadCredential = "token:${cfToken}";
          DynamicUser = true;
          Restart = "on-failure";
          RestartSec = 10;
          CapabilityBoundingSet = [ "" ];
          AmbientCapabilities = [ "" ];
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectProc = "invisible";
          ProcSubset = "pid";
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectKernelLogs = true;
          ProtectControlGroups = true;
          ProtectClock = true;
          ProtectHostname = true;
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          RemoveIPC = true;
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
            "AF_NETLINK"
          ];
          SystemCallArchitectures = "native";
          SystemCallFilter = [
            "@system-service"
            "~@privileged @resources"
          ];
          UMask = "0077";
        };
      };
    })
  ];
}
