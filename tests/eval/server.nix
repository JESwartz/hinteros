# Eval tests for server.nix (design/server.md): a box with all four M10 services evaluates (Plex's
# unfree package allowed only then), the firewall follows the entries' `ports` (`lan` to the local
# networks and tailscale0, `any` to all, SSH on tailscale0 while both are on), the Jellyfin setup
# unit is required by jellyfin.service and has its own network, hardware transcoding follows the
# Intel GPU, cloudflared runs only with a token and loads its egress rule, hinteros-system may
# reach loopback only and finds `tailscale`. A box without services has none of it.
{ self, pkgs }:
let
  inherit (pkgs) lib;

  adminHash = builtins.toFile "admin-hash" "$6$saltsalt$x";

  stateWith = services: {
    schemaVersion = 2;
    settings.ssh.enable = true;
    settings.guest.enable = true;
    profiles = [
      {
        id = "p1";
        user = "hinteros";
      }
    ];
    requirements = [ ];
    inherit services;
  };

  mk =
    services: extra:
    (self.lib.mkDevice {
      state = stateWith services;
      extraModules = [
        {
          system.stateVersion = "25.11";
          # Only so the toplevel evaluates.
          fileSystems."/" = {
            device = "/dev/vda";
            fsType = "ext4";
          };
          boot.loader.grub.enable = false;
          hinteros.admin = {
            enable = true;
            hashedPasswordFile = adminHash;
          };
        }
      ]
      ++ extra;
    }).config;

  all =
    mk
      [
        "jellyfin-server"
        "plex-media-server"
        "tailscale"
        "cloudflare-tunnel"
      ]
      [ { hinteros.hardware.intelVideo.enable = true; } ];
  none = mk [ ] [ ];
  jellyfinOnly = mk [ "jellyfin-server" ] [ { hinteros.hardware.intelVideo.enable = false; } ];

  fw = c: c.networking.firewall;
  units = c: c.systemd.services;
  tmpfiles = c: c.systemd.tmpfiles.rules;
  # `+<nft> -f <rules>`, with its context (the rules file is built for the check).
  cfPre = (units all).hinteros-cloudflared.serviceConfig.ExecStartPre;

  results = lib.runTests {
    testToplevelEvaluates = {
      expr = builtins.seq all.system.build.toplevel.drvPath true;
      expected = true;
    };
    testUnfree = {
      expr = {
        all = lib.elem "plexmediaserver" all.hinteros.unfreeAllowlist;
        none = lib.elem "plexmediaserver" none.hinteros.unfreeAllowlist;
      };
      expected = {
        all = true;
        none = false;
      };
    };
    testFirewallAny = {
      expr = {
        tcp = lib.sort lib.lessThan (fw all).allowedTCPPorts;
        udp = lib.sort lib.lessThan (fw all).allowedUDPPorts;
      };
      expected = {
        tcp = [ 32400 ];
        udp = [ 41641 ];
      };
    };
    testFirewallLan = {
      expr = lib.filter (l: lib.hasInfix "hinteros-server" l) (
        lib.splitString "\n" (fw all).extraInputRules
      );
      expected = [
        ''ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } tcp dport { 8096 } accept comment "hinteros-server"''
        ''ip6 saddr { fc00::/7, fe80::/10 } tcp dport { 8096 } accept comment "hinteros-server"''
        ''ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } udp dport { 7359, 32410, 32412, 32413, 32414 } accept comment "hinteros-server"''
        ''ip6 saddr { fc00::/7, fe80::/10 } udp dport { 7359, 32410, 32412, 32413, 32414 } accept comment "hinteros-server"''
      ];
    };
    testFirewallTailscale = {
      expr = {
        allowedTCPPorts = lib.sort lib.lessThan (fw all).interfaces.tailscale0.allowedTCPPorts;
        inherit ((fw all).interfaces.tailscale0) allowedUDPPorts;
      };
      expected = {
        allowedTCPPorts = [
          22
          8096
        ];
        allowedUDPPorts = [
          7359
          32410
          32412
          32413
          32414
        ];
      };
    };
    testNoServices = {
      expr = {
        rules = lib.hasInfix "hinteros-server" (fw none).extraInputRules;
        tcp = (fw none).allowedTCPPorts;
        tailscale0 = (fw none).interfaces ? tailscale0;
        setup = (units none) ? hinteros-jellyfin-setup;
        cloudflared = (units none) ? hinteros-cloudflared;
        families = (units none).hinteros-system.serviceConfig.RestrictAddressFamilies;
        dirs = lib.filter (lib.hasPrefix "d /var/lib/hinteros/services") (tmpfiles none);
        media = lib.elem "d /srv/media 2775 root hinteros-media -" (tmpfiles none);
        acl = lib.elem "A /srv/media - - - - d:g:hinteros-media:rx" (tmpfiles none);
        admin = lib.elem "hinteros-media" none.users.users.hinteros-admin.extraGroups;
      };
      expected = {
        rules = false;
        tcp = [ ];
        tailscale0 = false;
        setup = false;
        cloudflared = false;
        families = [ "AF_UNIX" ];
        dirs = [ ];
        media = true;
        acl = true;
        admin = true;
      };
    };
    testStateDirs = {
      expr = lib.sort lib.lessThan (
        lib.filter (lib.hasPrefix "d /var/lib/hinteros/services") (tmpfiles all)
      );
      expected = [
        "d /var/lib/hinteros/services 0700 root root -"
        "d /var/lib/hinteros/services/cloudflare-tunnel 0700 root root -"
        "d /var/lib/hinteros/services/jellyfin-server 0700 root root -"
        "d /var/lib/hinteros/services/plex-media-server 0700 root root -"
        "d /var/lib/hinteros/services/tailscale 0700 root root -"
      ];
    };
    testJellyfinSetup =
      let
        s = (units all).hinteros-jellyfin-setup;
      in
      {
        expr = {
          inherit (s) requiredBy before restartIfChanged;
          inherit (s.serviceConfig)
            Type
            RemainAfterExit
            PrivateNetwork
            ProtectSystem
            ;
          groups = lib.sort lib.lessThan all.users.users.jellyfin.extraGroups;
        };
        expected = {
          requiredBy = [ "jellyfin.service" ];
          before = [ "jellyfin.service" ];
          restartIfChanged = false;
          Type = "oneshot";
          RemainAfterExit = true;
          PrivateNetwork = true;
          ProtectSystem = "strict";
          groups = [
            "hinteros-media"
            "render"
            "video"
          ];
        };
      };
    testTranscoding = {
      expr = {
        on = {
          inherit (all.services.jellyfin.hardwareAcceleration) enable type device;
          inherit (all.services.jellyfin) forceEncodingConfig;
          codecs = lib.attrNames (
            lib.filterAttrs (_: v: v) all.services.jellyfin.transcoding.hardwareDecodingCodecs
          );
        };
        off = jellyfinOnly.services.jellyfin.hardwareAcceleration.enable;
      };
      expected = {
        on = {
          enable = true;
          type = "vaapi";
          device = "/dev/dri/renderD128";
          forceEncodingConfig = false;
          codecs = [
            "h264"
            "hevc"
            "vc1"
            "vp8"
          ];
        };
        off = false;
      };
    };
    testPlex = {
      expr = lib.sort lib.lessThan all.users.users.plex.extraGroups;
      expected = [
        "hinteros-media"
        "render"
        "video"
      ];
    };
    testCloudflared =
      let
        u = (units all).hinteros-cloudflared;
      in
      {
        expr = {
          inherit (u.unitConfig) ConditionPathExists;
          inherit (u.serviceConfig) LoadCredential DynamicUser Restart;
          exec = lib.hasSuffix "/bin/cloudflared tunnel --no-autoupdate --metrics 127.0.0.1:20241 run --token-file %d/token" u.serviceConfig.ExecStart;
          pre = lib.hasPrefix "+/nix/store/" u.serviceConfig.ExecStartPre;
        };
        expected = {
          ConditionPathExists = "/var/lib/hinteros/services/cloudflare-tunnel/token";
          LoadCredential = "token:/var/lib/hinteros/services/cloudflare-tunnel/token";
          DynamicUser = true;
          Restart = "on-failure";
          exec = true;
          pre = true;
        };
      };
    testSystemUnit =
      let
        sc = (units all).hinteros-system.serviceConfig;
      in
      {
        expr = {
          families = lib.sort lib.lessThan sc.RestrictAddressFamilies;
          inherit (sc) IPAddressDeny IPAddressAllow;
          systemPath = lib.any (p: lib.hasInfix "tailscale" "${p}") (units all).hinteros-system.path;
          jobPath = lib.any (p: lib.hasInfix "tailscale" "${p}") (units all)."hinteros-job@".path;
          jellyfinOnlyPath =
            lib.any (p: lib.hasInfix "tailscale" "${p}")
              (units jellyfinOnly)."hinteros-job@".path;
        };
        expected = {
          families = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
          IPAddressDeny = "any";
          IPAddressAllow = "localhost";
          systemPath = true;
          jobPath = true;
          jellyfinOnlyPath = false;
        };
      };
  };
in
pkgs.runCommand "hinteros-server-eval"
  {
    failures = if results == [ ] then "" else builtins.toJSON results;
    inherit cfPre;
  }
  ''
    if [ -n "$failures" ]; then echo "$failures" >&2; exit 1; fi
    cfRules=''${cfPre##* -f }
    # The tunnel's egress rule: its cgroup, the servers' ports (lan and any) on the box's own
    # addresses, everything else local refused.
    grep -qF 'socket cgroupv2 level 2 "system.slice/hinteros-cloudflared.service" jump cloudflared' $cfRules
    grep -qF 'fib daddr type local tcp dport { 8096, 32400 } accept' $cfRules
    grep -qF 'fib daddr type local udp dport { 7359, 32410, 32412, 32413, 32414, 41641 } accept' $cfRules
    grep -qF 'fib daddr type local meta l4proto tcp reject with tcp reset' $cfRules
    grep -qF 'fib daddr type local drop' $cfRules
    touch $out
  ''
