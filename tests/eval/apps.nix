# Eval-level tests for the app registry and the unfree allowlist. Nothing is built.
{ self, pkgs }:
let
  inherit (pkgs) lib;

  # No state: the box-wide apps of the test VMs, the three on the ISO on.
  mk =
    extra:
    self.lib.mkDevice {
      state = null;
      extraModules = [
        { system.stateVersion = "25.11"; }
        extra
      ];
    };

  appsOf = c: map (a: a.id) (c.config.hinteros.daemon.session.settings.apps or [ ]);
  base = mk { };
  # Crunchyroll is a Store app: not on the ISO, but installable.
  crunchy = mkApps [ "crunchyroll" ] { };
  noOsk = mk {
    hinteros.daemon.osk.enable = false;
    hinteros.daemon.osk.summon = "none";
  };
  cage = mk { hinteros.session.compositor = "cage"; };
  settings = c: c.config.hinteros.daemon.session.settings;
  plex = mk { hinteros.apps.plex-htpc.enable = true; };
  forbidden = mk {
    hinteros.apps.plex-htpc.enable = true;
    hinteros.forbidUnfree = true;
  };
  entry = c: id: lib.findFirst (a: a.id == id) null c.config.hinteros.daemon.session.settings.apps;
  failedAssertions = c: map (a: a.message) (lib.filter (a: !a.assertion) c.config.assertions);

  catalogEntries = self.inputs.hinteros-catalog.catalog;
  liveIds = builtins.attrNames (
    lib.filterAttrs (_: e: e.status != "removed" && (e.kind or "app") == "app") catalogEntries
  );
  # App envs (app-env.nix).
  env = c: ids: c.config.hinteros.appEnv.build ids;
  drv = e: builtins.unsafeDiscardStringContext e.drvPath;
  # Another box: other compositor and session settings.
  otherBox = cage;
  envFails = c: ids: !(builtins.tryEval (drv (env c ids))).success;
  # Exactly these box-wide apps.
  mkApps =
    ids: extra:
    self.lib.mkDevice {
      state = null;
      extraModules = [
        {
          system.stateVersion = "25.11";
          hinteros = {
            disk = {
              enable = true;
              rootUuid = "11111111-2222-3333-4444-555555555555";
              espUuid = "ABCD-1234";
            };
            apps = lib.genAttrs liveIds (id: {
              enable = lib.mkOverride 900 (lib.elem id ids);
            });
          };
        }
        extra
      ];
    };
  c2 = self.lib.mkDevice {
    state = {
      schemaVersion = 2;
      base = "unstable";
      stateVersion = "25.11";
      profiles = [ { id = "p1"; } ];
      requirements = [ ];
      services = [ ];
    };
  };
  # A device with every catalog entry enabled (nothing built: the drv paths below force evaluation).
  every = mkApps liveIds { };
  iso = self.nixosConfigurations.installer;
  cacheable = self.inputs.hinteros-catalog.lib.cacheableUnfree;
  # What the cache job builds: everything but unfree-and-not-redistributable.
  cacheJob = mkApps (lib.filter (id: !(lib.elem id [ "plex-htpc" ])) liveIds) {
    hinteros.forbidUnfree = true;
    hinteros.unfreeExceptions = cacheable;
  };
  sessionCmd = c: c.config.hinteros.session.command;
  gs = mk { hinteros.session.compositor = "gamescope"; };

  # The box-wide Firefox policies and the wrapped Firefox the kiosk apps run (firefox-kiosk.nix).
  fx =
    c:
    let
      k = c.config.hinteros.firefoxKiosk;
    in
    {
      inherit (k) policies autoConfig;
      finalPackage = k.firefox;
      hasNativeHost = lib.hasInfix "hinteros-session" k.firefox.buildCommand;
    };
  oskOff = mk { hinteros.firefoxKiosk.oskExtension = "off"; };
  oskEsr = mk { hinteros.firefoxKiosk.oskExtension = "esr-unsigned"; };
  oskSigned = mk {
    hinteros.firefoxKiosk.oskExtension = "signed";
    hinteros.firefoxKiosk.oskExtensionXpi = "/nix/store/00000000000000000000000000000000-signed/osk.xpi";
  };
  oskSignedNoXpi = mk { hinteros.firefoxKiosk.oskExtension = "signed"; };
  extId = "hinteros-osk@hinteros";
  oskFailures = c: lib.filter (lib.hasInfix "oskExtension") (failedAssertions c);
  hasSub = s: sub: lib.hasInfix sub (toString s);

  # The Store-only streaming apps (Firefox ESR kiosk entries; not offered by the installer, not on the ISO).
  streaming = [
    "netflix"
    "disney-plus"
    "apple-tv"
    "prime-video"
    "hbo-max"
    "hulu"
    "paramount-plus"
    "tubi"
    "pluto-tv"
    "twitch"
    "spotify"
  ];
  appIds = import ../../nixos/lib/app-ids.nix catalogEntries;
  stream2 = mkApps [
    "netflix"
    "spotify"
    "youtube"
  ] { };
  streamAll = mkApps streaming { };
  # Launched through the shared Firefox kiosk wrapper: `wrapper <id> <url>`.
  isKiosk =
    id: e: lib.hasSuffix "/bin/hinteros-firefox-kiosk" (lib.head e.command) && lib.elem id e.command;

  results = lib.runTests {
    # The env's manifest: the same entries session.toml has for the same apps, Steam's path, the
    # box features; sorted, de-duplicated ids.
    testEnvManifest =
      let
        m =
          (env base [
            "youtube"
            "steam"
            "jellyfin-desktop"
            "youtube"
          ]).manifest;
      in
      {
        expr = [
          m.version
          m.ids
          (map (a: a.id) m.apps)
          m.box
          (lib.hasSuffix "/bin/steam" m.steam.path)
          (lib.findFirst (a: a.id == "youtube") null m.apps == entry base "youtube")
          (lib.findFirst (a: a.id == "jellyfin-desktop") null m.apps == entry base "jellyfin-desktop")
          (env base [ "youtube" ]).manifest.steam
          (env base [ "youtube" ]).manifest.box
        ];
        expected = [
          1
          [
            "jellyfin-desktop"
            "steam"
            "youtube"
          ]
          [
            "jellyfin-desktop"
            "youtube"
          ]
          [
            "graphics32"
            "steam-devices"
          ]
          true
          true
          true
          null
          [ ]
        ];
      };
    # Same ids, same system: same store path, whatever the order, duplicates or unrelated box
    # settings; Steam is stock pkgs.steam, so it does not depend on the box's graphics (spike 8).
    testEnvDeterministic = {
      expr = [
        (
          drv (
            env base [
              "firefox"
              "jellyfin-desktop"
            ]
          ) == drv (
            env base [
              "jellyfin-desktop"
              "firefox"
              "firefox"
            ]
          )
        )
        (drv (env base [ "firefox" ]) == drv (env otherBox [ "firefox" ]))
        (drv (env base [ "steam" ]) == drv (env otherBox [ "steam" ]))
        (drv (env base [ "steam" ]) == drv (env cacheJob [ "steam" ]))
        (drv (env base [ "firefox" ]) == drv (env c2 [ "firefox" ]))
        (drv (env base [ "firefox" ]) != drv (env base [ "jellyfin-desktop" ]))
      ];
      expected = [
        true
        true
        true
        true
        true
        true
      ];
    };
    # Unfree per env: the cache job's envs may hold Steam, never Plex; the system's own allowlist
    # lists no app on a device, and the env still evaluates (its own nixpkgs instance).
    testEnvUnfree = {
      expr = [
        (envFails cacheJob [ "plex-htpc" ])
        (envFails cacheJob [ "steam" ])
        (envFails c2 [ "plex-htpc" ])
        c2.config.hinteros.unfreeAllowlist
        (envFails base [ "no-such-app" ])
        (envFails base [ "jellyfin-server" ])
      ];
      expected = [
        true
        false
        false
        [ ]
        true
        true
      ];
    };
    testDefaultApps = {
      expr = appsOf base;
      expected = [
        "jellyfin-desktop"
        "youtube"
        "firefox"
      ];
    };
    # Without a state (test VMs): the installer's onIso apps, not every entry with `onIso` (the
    # Store-only streaming apps are on the ISO too).
    testStatelessDefaultApps = {
      expr = appsOf (
        self.inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            self.nixosModules.session
            self.nixosModules.daemon
            self.nixosModules.apps
            self.nixosModules.overlay
            {
              hinteros.daemon.enable = true;
              hinteros.session.enable = true;
              system.stateVersion = "25.11";
              boot.loader.grub.enable = false;
              fileSystems."/".device = "none";
            }
          ];
        }
      );
      expected = [
        "jellyfin-desktop"
        "youtube"
        "firefox"
      ];
    };
    testNoUnfreeByDefault = {
      expr = base.config.hinteros.unfreeAllowlist;
      expected = [ ];
    };
    testInputKeysEmitted = {
      expr = [
        (entry base "youtube").input
        (entry base "youtube").back_key
        (entry base "jellyfin-desktop" ? input)
      ];
      expected = [
        "keyboard"
        "escape"
        false
      ];
    };
    testOskDefaults = {
      expr = [
        (settings base).osk.enable
        (settings base).osk.summon
        (lib.hasSuffix "/bin/hinteros-osk" (lib.head (settings base).osk.command))
      ];
      expected = [
        true
        "guide+context"
        true
      ];
    };
    testOskOff = {
      expr = [
        (settings noOsk).osk.enable
        (settings noOsk).osk.summon
      ];
      expected = [
        false
        "none"
      ];
    };
    testUsKeyboardLayout = {
      expr = base.config.hinteros.session.environment.XKB_DEFAULT_LAYOUT;
      expected = "us";
    };
    # cage: apps and the daemon find cage's sockets without per-test overrides.
    testCageSockets = {
      expr = [
        (settings cage).gamescope.wayland_display
        cage.config.systemd.user.services.hinteros-session.environment.DISPLAY
      ];
      expected = [
        "wayland-0"
        ":0"
      ];
    };
    # A gamescope version the daemon's vendored protocol was not reviewed against must not evaluate.
    testGamescopePinFails = {
      expr = lib.any (lib.hasInfix "gamescope is") (
        failedAssertions (mk {
          hinteros.session.compositor = "gamescope";
          hinteros.session.gamescope.reviewedVersion = "0.0.0";
        })
      );
      expected = true;
    };
    testGamescopePinOk = {
      expr = lib.any (lib.hasInfix "gamescope is") (
        failedAssertions (mk {
          hinteros.session.compositor = "gamescope";
        })
      );
      expected = false;
    };
    # design/sandbox.md: every app entry says whether it is sandboxed and carries the catalog's
    # permissions; session.toml turns the sandbox on with bwrap by store path.
    testSandboxSettings = {
      expr = {
        firefox = {
          inherit (entry base "firefox") sandbox permissions;
        };
        youtube = {
          inherit (entry base "youtube") sandbox;
          hasPermissions = (entry base "youtube") ? permissions;
        };
        plex = (entry plex "plex-htpc").permissions;
        enable = (settings base).sandbox.enable;
        bwrap = lib.hasSuffix "/bin/bwrap" (settings base).sandbox.bwrap;
        # Apps play through the play-only socket; `mic` gets the full one.
        pulse = {
          inherit ((settings base).sandbox) pulse_socket pulse_record_socket;
          unit = base.config.systemd.user.services ? hinteros-pulse-play;
        };
        off =
          (settings (mk {
            hinteros.sandbox.enable = false;
          })).sandbox.enable;
        protectTunables =
          base.config.systemd.user.services.hinteros-session.serviceConfig ? ProtectKernelTunables;
      };
      expected = {
        firefox = {
          sandbox = true;
          permissions = {
            downloads = "optional";
            lan = "optional";
          };
        };
        youtube = {
          sandbox = true;
          hasPermissions = false;
        };
        plex = {
          gamepad = "required";
          lan = "optional";
        };
        enable = true;
        bwrap = true;
        pulse = {
          pulse_socket = "pulse/play";
          pulse_record_socket = "pulse/native";
          unit = true;
        };
        off = false;
        protectTunables = false;
      };
    };
    # design/sandbox.md `lan`: the daemon owns its cgroup subtree, session.toml turns the filter
    # on, hinteros-system takes lan_filter.* and the oneshot unit (the only one with
    # CAP_NET_ADMIN) loads the table; the path unit follows /etc/resolv.conf. Off: none of it.
    testLanFilter =
      let
        units = c: c.config.systemd.services;
        user = c: c.config.systemd.user.services.hinteros-session.serviceConfig;
        of = c: {
          lan_filter = (settings c).sandbox.lan_filter;
          inherit ((user c)) Delegate ProtectControlGroups;
          flag = ((units c).hinteros-system.environment.HINTEROS_LAN_FILTER or null) == "true";
          unit = (units c) ? hinteros-lan-filter;
          path = c.config.systemd.paths ? hinteros-lan-filter;
        };
        on = units base;
      in
      {
        expr = {
          on = of base;
          off = of (mk {
            hinteros.sandbox.lan.enable = false;
          });
          noSandbox = of (mk {
            hinteros.sandbox.enable = false;
          });
          caps = on.hinteros-lan-filter.serviceConfig.CapabilityBoundingSet;
          families = on.hinteros-lan-filter.serviceConfig.RestrictAddressFamilies;
          systemCaps = on.hinteros-system.serviceConfig.CapabilityBoundingSet;
          systemFamilies = on.hinteros-system.serviceConfig.RestrictAddressFamilies;
          exec = lib.hasInfix "lan-filter-apply --nft /nix/store/" on.hinteros-lan-filter.serviceConfig.ExecStart;
          resolv = base.config.systemd.paths.hinteros-lan-filter.pathConfig.PathModified;
        };
        expected = {
          on = {
            lan_filter = true;
            Delegate = true;
            ProtectControlGroups = false;
            flag = true;
            unit = true;
            path = true;
          };
          off = {
            lan_filter = false;
            Delegate = false;
            ProtectControlGroups = true;
            flag = false;
            unit = false;
            path = false;
          };
          noSandbox = {
            lan_filter = false;
            Delegate = false;
            ProtectControlGroups = true;
            flag = false;
            unit = false;
            path = false;
          };
          caps = [ "CAP_NET_ADMIN" ];
          families = [
            "AF_NETLINK"
            "AF_UNIX"
          ];
          # hinteros-system itself still has no network and no CAP_NET_ADMIN.
          systemCaps = [ "CAP_SYS_PTRACE" ];
          systemFamilies = [ "AF_UNIX" ];
          exec = true;
          resolv = "/etc/resolv.conf";
        };
      };
    # Daemon README, "Pointer and on-screen keyboard": plain Firefox gets address_bar, kiosk apps do not.
    testAddressBar = {
      expr = [
        (entry base "firefox").address_bar or false
        (entry base "youtube").address_bar or false
        (entry base "jellyfin-desktop").address_bar or false
        (entry crunchy "crunchyroll").address_bar or false
      ];
      expected = [
        true
        false
        false
        false
      ];
    };
    # gamescope never hides the pointer on inactivity (only the daemon does, with gamescopectl,
    # an absolute store path) and scales it up for a TV; the home app gets the large theme.
    testPointerSettings =
      let
        p = (settings gs).pointer;
      in
      {
        expr = [
          (p ? idle_ms)
          (lib.hasInfix "--hide-cursor-delay 86400000" (sessionCmd gs))
          (lib.hasInfix "--cursor-scale-height 540" (sessionCmd gs))
          (lib.hasInfix "XCURSOR_THEME=Adwaita" (sessionCmd gs))
          (lib.hasInfix "--cursor-scale-height" (sessionCmd cage))
          (lib.hasInfix "XCURSOR_THEME" (sessionCmd cage))
          (lib.hasInfix "--cursor-scale-height" (
            sessionCmd (mk {
              hinteros.session.compositor = "gamescope";
              hinteros.session.cursor.scaleHeight = null;
            })
          ))
          (lib.hasSuffix "/bin/gamescopectl" (lib.head p.hide_command))
          (lib.tail p.hide_command)
          (lib.tail p.show_command)
          (settings cage).pointer.hide_command
          (settings gs).osk.auto_show
          ((settings gs).osk ? field_summon)
        ];
        expected = [
          false
          true
          true
          true
          false
          false
          false
          true
          [
            "paint_cursor_plane"
            "0"
          ]
          [
            "paint_cursor_plane"
            "1"
          ]
          [ ]
          false
          false
        ];
      };
    testYoutubeKioskUserAgent = {
      expr = lib.elem "--user-agent" (entry base "youtube").command;
      expected = true;
    };
    testCrunchyrollNoUserAgent = {
      expr = lib.elem "--user-agent" (entry crunchy "crunchyroll").command;
      expected = false;
    };
    testPlexAllowlisted = {
      expr = [
        (appsOf plex)
        (lib.elem "plex-htpc" plex.config.hinteros.unfreeAllowlist)
      ];
      expected = [
        [
          "jellyfin-desktop"
          "plex-htpc"
          "youtube"
          "firefox"
        ]
        true
      ];
    };
    # Icons: the catalog's fields reach session.toml; no generated icon files.
    testIconFields = {
      expr = [
        (entry base "jellyfin-desktop").desktop_id
        (entry base "youtube").firefox_profile
        (entry base "youtube").site_url
        (lib.hasPrefix "https://" (entry base "youtube").icon_url)
        (entry crunchy "crunchyroll" ? icon_url)
        (builtins.match "[0-9a-f]{64}" (entry base "youtube").icon_sha256 != null)
        (entry crunchy "crunchyroll" ? icon_sha256)
        (lib.any (a: a ? icon) (settings base).apps)
      ];
      expected = [
        "org.jellyfin.JellyfinDesktop"
        "~/.local/share/hinteros/firefox/youtube"
        "https://www.youtube.com"
        true
        false
        true
        false
        false
      ];
    };
    # The catalog index and vendor terms are installed.
    testIndexInstalled = {
      expr = lib.elem base.config.hinteros.catalog.index base.config.environment.systemPackages;
      expected = true;
    };
    # Steam only adds system config (its tile is the daemon's built-in one) and is cached: allowed by name.
    testSteamNotListed = {
      expr =
        let
          s = mkApps [ "steam" ] { };
        in
        [
          (appsOf s)
          s.config.programs.steam.enable
          s.config.hinteros.unfreeAllowlist
          s.config.hardware.graphics.enable32Bit
        ];
      expected = [
        [ ]
        false
        [
          "steam"
          "steam-unwrapped"
        ]
        true
      ];
    };
    # Unfree for the cache job: only the catalog's cacheable names (Steam, Modrinth), never Plex.
    testCacheableIsSteamAndModrinth = {
      expr = cacheable;
      expected = [
        "modrinth-app"
        "modrinth-app-unwrapped"
        "steam"
        "steam-unwrapped"
      ];
    };
    testCacheJobPasses = {
      expr = failedAssertions cacheJob;
      expected = [ ];
    };
    testCacheJobRefusesPlex = {
      expr = lib.any (lib.hasInfix "plex-htpc") (
        failedAssertions (
          mkApps [ "plex-htpc" ] {
            hinteros.forbidUnfree = true;
            hinteros.unfreeExceptions = cacheable;
          }
        )
      );
      expected = true;
    };
    # The ISO is fully free: no allowlist, no exceptions, Steam not on it (it is cached, not shipped).
    testIsoFullyFree = {
      expr = [
        iso.config.hinteros.unfreeAllowlist
        iso.config.hinteros.unfreeExceptions
        iso.config.hinteros.forbidUnfree
        (lib.any (a: !a.assertion) iso.config.assertions)
      ];
      expected = [
        [ ]
        [ ]
        true
        false
      ];
    };
    # Streaming apps are Store apps: known to the catalog, never in the installer's lists.
    testStreamingStoreOnly = {
      expr = [
        (lib.all (id: catalogEntries ? ${id}) streaming)
        (lib.filter (id: lib.elem id appIds.all) streaming)
        (lib.filter (id: lib.elem id appIds.onIso) streaming)
        (lib.filter (id: lib.elem id appIds.preselected) streaming)
        (lib.filter (id: catalogEntries.${id}.starter != null) streaming)
      ];
      expected = [
        true
        [ ]
        [ ]
        [ ]
        [ ]
      ];
    };
    # Not installed: not in the registry (the default device has the ISO apps only).
    testStreamingAbsentUntilInstalled = {
      expr = lib.filter (id: lib.elem id (appsOf base)) streaming;
      expected = [ ];
    };
    # Installed: listed by apps.list (session.toml), as Firefox kiosk entries with their own
    # profile, controller as keyboard, and no User-Agent override (that is YouTube's alone).
    testStreamingListedWhenInstalled = {
      expr = [
        (lib.sort (a: b: a < b) (appsOf stream2))
        (lib.all
          (
            id:
            let
              e = entry stream2 id;
            in
            isKiosk id e
            && !(lib.elem "--user-agent" e.command)
            && e.firefox_profile == "~/.local/share/hinteros/firefox/${id}"
            && e.input == "keyboard"
            && e.back_key == "escape"
          )
          [
            "netflix"
            "spotify"
          ]
        )
        (entry stream2 "netflix").name
        (lib.elem "--user-agent" (entry stream2 "youtube").command)
      ];
      expected = [
        [
          "netflix"
          "spotify"
          "youtube"
        ]
        true
        "Netflix"
        true
      ];
    };
    # All of them at once: every one is a listed kiosk entry with its own profile directory, the
    # profile policies (OSK extension, ESR) are the shared ones, and nothing unfree is pulled in.
    testStreamingAllKiosk = {
      expr = [
        (lib.sort (a: b: a < b) (appsOf streamAll))
        (lib.all (id: isKiosk id (entry streamAll id)) streaming)
        (lib.length (lib.unique (map (id: (entry streamAll id).firefox_profile) streaming)))
        streamAll.config.hinteros.unfreeAllowlist
        (lib.hasSuffix "esr" (fx streamAll).finalPackage.version)
        ((fx streamAll).policies.ExtensionSettings ? "${extId}")
      ];
      expected = [
        (lib.sort (a: b: a < b) streaming)
        true
        (lib.length streaming)
        [ ]
        true
        true
      ];
    };
    testEveryEntryEnabled = {
      expr = lib.all (id: every.config.hinteros.apps.${id}.enable) liveIds;
      expected = true;
    };
    # gamescope: mode files for the runtime display settings, no fixed output size.
    testGamescopeModeFiles = {
      expr = [
        (lib.hasInfix "hinteros-display-env" (sessionCmd gs))
        (lib.hasInfix " -W" (sessionCmd gs))
        (lib.hasInfix " -H" (sessionCmd gs))
        (lib.hasInfix " -r " (sessionCmd gs))
        (lib.hasInfix "hinteros-display-env" gs.config.systemd.user.services.hinteros-session.serviceConfig.ExecStart)
      ];
      expected = [
        true
        false
        false
        false
        true
      ];
    };
    # gamescope's Vulkan loader: only the system's drivers and implicit layers (no profile, home
    # or app env); a VM's VK_ICD_FILENAMES keeps its driver; cage gets nothing.
    testGamescopeVulkanSearchPaths = {
      expr = [
        (lib.hasInfix "VK_IMPLICIT_LAYER_PATH=/run/opengl-driver/share/vulkan/implicit_layer.d:/run/opengl-driver-32/share/vulkan/implicit_layer.d'" (
          sessionCmd gs
        ))
        (lib.hasInfix "VK_DRIVER_FILES=/run/opengl-driver/share/vulkan/icd.d:/run/opengl-driver-32/share/vulkan/icd.d'" (
          sessionCmd gs
        ))
        (lib.hasInfix "VK_DRIVER_FILES" (
          sessionCmd (mk {
            hinteros.session.compositor = "gamescope";
            hinteros.session.environment.VK_ICD_FILENAMES = "/x.json";
          })
        ))
        (lib.hasInfix "VK_" (sessionCmd cage))
      ];
      expected = [
        true
        true
        false
        false
      ];
    };
    # gamescope: apps on Xwayland sized to the output (README "Display size"), output logged.
    testGamescopeAppSize = {
      expr = [
        (lib.hasInfix "--xwayland-count 6 --force-windows-fullscreen" (sessionCmd gs))
        (lib.hasInfix "GDK_BACKEND=x11" (sessionCmd gs))
        gs.config.systemd.user.services.hinteros-session.environment.GDK_BACKEND
        (lib.hasInfix "systemd-cat --identifier hinteros-compositor" (sessionCmd gs))
        (cage.config.hinteros.session.environment.GDK_BACKEND or "unset")
        (cage.config.systemd.user.services.hinteros-session.environment.GDK_BACKEND or "unset")
      ];
      expected = [
        true
        true
        "x11"
        true
        "unset"
        "unset"
      ];
    };
    # gamescope: each app on an Xwayland of its own from the third on, patched
    # (design/sandbox.md step 3), their number read before gamescope starts; cage: one display.
    testGamescopeAppsDisplay = {
      expr = [
        (settings gs).gamescope.apps_display
        ((settings cage).gamescope.apps_display or "unset")
        (settings gs).gamescope.app_displays
        (lib.hasInfix "hinteros-app-displays" (sessionCmd gs))
        (lib.hasInfix "hinteros-app-displays" (sessionCmd cage))
        (lib.hasInfix "hinteros-app-displays" gs.config.systemd.user.services.hinteros-session.serviceConfig.ExecStart)
        (lib.all
          (p: lib.elem p (map baseNameOf (gs.config.hinteros.session.gamescope.package.patches or [ ])))
          [
            "xwayland-no-abstract-socket.patch"
            "xwayland-size-all.patch"
            "xwayland-apps-no-input-emulation.patch"
          ]
        )
      ];
      expected = [
        "auto+2"
        "unset"
        4
        true
        false
        false
        true
      ];
    };
    testPactl = {
      expr = lib.hasSuffix "/bin/pactl" (settings base).audio.pactl;
      expected = true;
    };
    testForbidUnfreeFails = {
      expr = lib.any (lib.hasInfix "forbidUnfree") (failedAssertions forbidden);
      expected = true;
    };
    # Firefox auto-OSK extension: the native-messaging host is always installed.
    # The default is the owner's choice: Firefox ESR with the extension force-installed.
    testOskExtensionDefault = {
      expr = [
        base.config.hinteros.firefoxKiosk.oskExtension
        (lib.hasSuffix "esr" (fx base).finalPackage.version)
        ((fx base).policies.ExtensionSettings ? "${extId}")
      ];
      expected = [
        "esr-unsigned"
        true
        true
      ];
    };
    # about:home has no search box: no extension runs there, so it would get no OSK.
    testFirefoxHomeNoSearch = {
      expr = (fx base).policies.FirefoxHome;
      expected = {
        Search = false;
      };
    };
    testOskExtensionOff = {
      expr = [
        oskOff.config.hinteros.firefoxKiosk.oskExtension
        ((fx oskOff).policies.ExtensionSettings or { } ? "${extId}")
        (fx oskOff).autoConfig
        (lib.hasSuffix "esr" (fx oskOff).finalPackage.version)
        (fx oskOff).hasNativeHost
        (settings oskOff).osk.auto_show
        (settings oskOff).input.xbox_label_swap
      ];
      expected = [
        "off"
        false
        ""
        false
        true
        false
        "auto"
      ];
    };
    testOskExtensionEsrUnsigned = {
      expr = [
        (lib.hasSuffix "esr" (fx oskEsr).finalPackage.version)
        (hasSub (fx oskEsr).autoConfig ''lockPref("xpinstall.signatures.required", false);'')
        # Spike 8: the signature pref is box-wide in the policies too, so any env's Firefox gets it.
        (fx oskEsr).policies.Preferences."xpinstall.signatures.required"
        (fx oskEsr).hasNativeHost
        (fx oskEsr).policies.ExtensionSettings.${extId}.installation_mode
        (hasSub (fx oskEsr).policies.ExtensionSettings.${extId}.install_url
          "hinteros-osk-firefox-extension"
        )
        (lib.hasPrefix "file:///nix/store/" (fx oskEsr).policies.ExtensionSettings.${extId}.install_url)
        (lib.hasSuffix "/hinteros-osk@hinteros.xpi"
          (fx oskEsr).policies.ExtensionSettings.${extId}.install_url
        )
        (fx oskEsr).policies.ExtensionSettings.${extId}.private_browsing
        (hasSub (fx oskEsr).autoConfig ''lockPref("extensions.quarantineIgnoredByUser.${extId}", true);'')
        # The address bar reporter.
        (hasSub (fx oskEsr).autoConfig "hinteros-firefox-chrome")
        (oskFailures oskEsr)
      ];
      expected = [
        true
        true
        {
          Value = false;
          Status = "locked";
        }
        true
        "force_installed"
        true
        true
        true
        true
        true
        true
        [ ]
      ];
    };
    testOskExtensionSigned = {
      expr = [
        (lib.hasSuffix "esr" (fx oskSigned).finalPackage.version)
        ((fx oskSigned).policies.Preferences ? "xpinstall.signatures.required")
        # No signature override, but the address bar reporter.
        (hasSub (fx oskSigned).autoConfig "xpinstall.signatures.required")
        (hasSub (fx oskSigned).autoConfig "hinteros-firefox-chrome")
        (fx oskSigned).policies.ExtensionSettings.${extId}.install_url
        (oskFailures oskSigned)
      ];
      expected = [
        false
        false
        false
        true
        "file:///nix/store/00000000000000000000000000000000-signed/osk.xpi"
        [ ]
      ];
    };
    testOskExtensionSignedNeedsXpi = {
      expr = lib.any (lib.hasInfix "oskExtensionXpi") (oskFailures oskSignedNoXpi);
      expected = true;
    };
    testForbidUnfreeOkWithoutUnfree = {
      expr = lib.any (lib.hasInfix "forbidUnfree") (
        failedAssertions (mk {
          hinteros.forbidUnfree = true;
        })
      );
      expected = false;
    };
  };
in
pkgs.runCommand "hinteros-apps-eval"
  {
    # Evaluation only: every catalog entry in one device config, and the ISO (which throws on any
    # unfree package, as it allows none).
    everyDrv = builtins.unsafeDiscardStringContext every.config.system.build.toplevel.drvPath;
    # Every app in one env (as hinteros-system builds them).
    envDrv = drv (env base liveIds);
    cacheDrv = builtins.unsafeDiscardStringContext cacheJob.config.system.build.toplevel.drvPath;
    isoDrv = builtins.unsafeDiscardStringContext iso.config.system.build.isoImage.drvPath;
  }
  (
    if results == [ ] then
      "touch $out"
    else
      ''
        cat >&2 <<'EOT'
        ${builtins.toJSON results}
        EOT
        exit 1
      ''
  )
