{
  description = "HinterOS: a NixOS module layer that turns a PC into a controller-driven console and smart TV";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Component repos. Their packages come in through their overlays (see overlays.default).
    # scripts/dev-override picks these up by input name.
    hinteros-launcher = {
      url = "git+https://justsomeshed.com/JSwartz/HinterOS/hinteros-launcher.git";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        git-hooks.follows = "git-hooks";
        # The launcher's schema check and integration tests use the same daemon as the box.
        hinteros-daemon.follows = "hinteros-daemon";
      };
    };
    hinteros-daemon = {
      url = "git+https://justsomeshed.com/JSwartz/HinterOS/hinteros-daemon.git";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        git-hooks.follows = "git-hooks";
      };
    };
    # The App Store catalog (design/catalog.md): app entries, Store index and vendor terms, locked
    # per release like the other inputs.
    hinteros-catalog = {
      url = "git+https://justsomeshed.com/JSwartz/HinterOS/hinteros-catalog.git";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        git-hooks.follows = "git-hooks";
      };
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      git-hooks,
      hinteros-launcher,
      hinteros-daemon,
      hinteros-catalog,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      overlayModule = import ./nixos/modules/overlay.nix { inherit self; };

      # The catalog (design/catalog.md) as a keyed module: importing it twice is harmless.
      catalogModule = {
        key = "hinteros:catalog";
        imports = [
          (import ./nixos/modules/catalog.nix {
            entries = hinteros-catalog.catalog;
            inherit (hinteros-catalog.lib) cacheableUnfree;
            index = hinteros-catalog.packages.${system}.index;
          })
        ];
      };
      withCatalog = path: {
        imports = [
          catalogModule
          path
        ];
      };

      mkVm =
        extraModules:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            self.nixosModules.default
            ./nixos/vm
            ./nixos/vm/qemu.nix
          ]
          ++ extraModules;
        };
    in
    {
      # Component packages (launcher, session and system daemons) plus our own.
      overlays.default = nixpkgs.lib.composeManyExtensions [
        hinteros-launcher.overlays.default
        hinteros-daemon.overlays.default
        (import ./nixos/overlay.nix)
      ];

      lib = {
        # The catalog's ids with the little the update check needs to say which apps a new
        # revision adds or retires: `{ <id> = { name; kind; status; statusReason; }; }`.
        # hinteros-system evaluates it against a target revision (`nix eval --json --option
        # allow-import-from-derivation false "<input url>&rev=<rev>#lib.catalogIds"`), so it must
        # stay a plain attribute set that needs no build.
        catalogIds = nixpkgs.lib.mapAttrs (_: e: {
          inherit (e) name status statusReason;
        }) hinteros-catalog.catalog;

        # mkDevice builds a device from its state.json; see nixos/lib/mk-device.nix.
        mkDevice = import ./nixos/lib/mk-device.nix { inherit self nixpkgs; };

        # Checked-in devices as functions of their state (mkDevice `selfFlake`).
        devices.devbox = import ./devices/devbox { inherit self; };
      };

      nixosModules = {
        default.imports = [
          overlayModule
          catalogModule
          ./nixos/modules
          # The vendor's trust (signing keys, cache keys) and version from release/: only here,
          # so configs that pick individual modules start out trusting nobody.
          ./nixos/modules/release.nix
        ];
        overlay = overlayModule;
        cache = ./nixos/modules/cache.nix;
        session = ./nixos/modules/session.nix;
        generic-hardware = ./nixos/modules/generic-hardware.nix;
        daemon = ./nixos/modules/daemon.nix;
        input = ./nixos/modules/input.nix;
        state = withCatalog ./nixos/modules/state.nix;
        catalog = catalogModule;
        fake-steam = ./nixos/modules/fake-steam.nix;
        unfree = ./nixos/modules/unfree.nix;
        firefox-kiosk = ./nixos/modules/firefox-kiosk.nix;
        apps = withCatalog ./nixos/modules/apps.nix;
        device-config = ./nixos/modules/device-config.nix;
        runtime = ./nixos/modules/runtime.nix;
        maintenance = ./nixos/modules/maintenance.nix;
        hardening = ./nixos/modules/hardening.nix;
        # The installer environment (hinteros-install, the offline closure); the ISO adds iso.nix.
        installer = import ./nixos/installer { inherit self; };
      };

      nixosConfigurations = {
        vm = mkVm [ ];
        # Same VM with the real compositor; needs a Vulkan GPU (e.g. virtio-gpu venus).
        vm-gamescope = mkVm [ { hinteros.session.compositor = "gamescope"; } ];
        # Dev box (mini PC #1), deployed with nixos-rebuild --target-host. See devices/devbox.
        devbox = self.lib.devices.devbox {
          state = builtins.fromJSON (builtins.readFile ./devices/devbox/state.json);
        };
        # The installer ISO: `nix build .#iso`. See nixos/installer.
        installer = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            self.nixosModules.default
            self.nixosModules.installer
            ./nixos/installer/iso.nix
          ];
        };
      };

      packages.${system} = {
        vm = self.nixosConfigurations.vm.config.system.build.vm;
        iso = self.nixosConfigurations.installer.config.system.build.isoImage;
        # The release tool (scripts/promote.sh), run by the owner: `nix run .#promote -- beta`.
        promote = pkgs.callPackage ./scripts/promote.nix { };
        # The same script devices ship, for a box whose running system predates it:
        # `sudo nix run "git+<repo>?ref=beta&rev=<rev>#hinteros-bootstrap-channel" -- beta <rev>`.
        hinteros-bootstrap-channel = pkgs.callPackage ./nixos/pkgs/hinteros-bootstrap-channel { };
        default = self.packages.${system}.vm;
      };

      apps.${system} = {
        vm = {
          type = "app";
          program = "${self.packages.${system}.vm}/bin/run-hinteros-vm-vm";
          meta.description = "Run the HinterOS test VM in a window";
        };
        promote = {
          type = "app";
          program = pkgs.lib.getExe self.packages.${system}.promote;
          meta.description = "Sign and move the HinterOS beta and stable channels";
        };
        default = self.apps.${system}.vm;
      };

      checks.${system} = {
        pre-commit = git-hooks.lib.${system}.run {
          src = ./.;
          hooks = {
            nixfmt.enable = true;
            statix.enable = true;
            deadnix.enable = true;
          };
        };
        boot = import ./tests/vm/boot.nix { inherit self pkgs; };
        gamescope = import ./tests/vm/gamescope.nix { inherit self pkgs; };
        gamescope-size = import ./tests/vm/gamescope-size.nix { inherit self pkgs; };
        gamescope-sandbox = import ./tests/vm/gamescope-sandbox.nix { inherit self pkgs; };
        input-layer = import ./tests/vm/input-layer.nix { inherit self pkgs; };
        fake-steam = import ./tests/vm/fake-steam.nix { inherit self pkgs; };
        config-sync = import ./tests/vm/config-sync.nix { inherit self pkgs; };
        runtime = import ./tests/vm/runtime.nix { inherit self pkgs; };
        runtime-settings = import ./tests/vm/runtime-settings.nix { inherit self pkgs; };
        installer-ui = import ./tests/vm/installer-ui.nix { inherit self pkgs; };
        installer-save-log = import ./tests/vm/installer-save-log.nix { inherit self pkgs; };
        hardening = import ./tests/vm/hardening.nix { inherit self pkgs; };
        wifi-iwd = import ./tests/vm/wifi-iwd.nix { inherit self pkgs; };
        tv-apps = import ./tests/vm/tv-apps.nix { inherit self pkgs; };
        sandbox = import ./tests/vm/sandbox.nix { inherit self pkgs; };
        sandbox-apps = import ./tests/vm/sandbox-apps.nix { inherit self pkgs; };
        sandbox-pad = import ./tests/vm/sandbox-pad.nix { inherit self pkgs; };
        sandbox-lan = import ./tests/vm/sandbox-lan.nix { inherit self pkgs; };
        steam-sockets = import ./tests/vm/steam-sockets.nix { inherit self pkgs; };
        typing = import ./tests/vm/typing.nix { inherit self pkgs; };
        system-escalation = import ./tests/vm/system-escalation.nix { inherit self pkgs; };
        system-authz = import ./tests/vm/system-authz.nix { inherit self pkgs; };
        system-jobs = import ./tests/vm/system-jobs.nix { inherit self pkgs; };
        polkit-agent = import ./tests/vm/polkit-agent.nix { inherit self pkgs; };
        session-restart = import ./tests/vm/session-restart.nix { inherit self pkgs; };
        store-install = import ./tests/vm/store-install.nix { inherit self pkgs; };
        profile-apps-system = import ./tests/vm/profile-apps-system.nix { inherit self pkgs; };
        profile-apps = import ./tests/vm/profile-apps.nix { inherit self pkgs; };
        profiles-greeter = import ./tests/vm/profiles-greeter.nix { inherit self pkgs; };
        profiles-switch = import ./tests/vm/profiles-switch.nix { inherit self pkgs; };
        profiles-pin = import ./tests/vm/profiles-pin.nix { inherit self pkgs; };
        profiles-isolation = import ./tests/vm/profiles-isolation.nix { inherit self pkgs; };
        profiles-lifecycle = import ./tests/vm/profiles-lifecycle.nix { inherit self pkgs; };
        profiles-lock = import ./tests/vm/profiles-lock.nix { inherit self pkgs; };
        apps-box-features = import ./tests/vm/apps-box-features.nix { inherit self pkgs; };
        guest = import ./tests/vm/guest.nix { inherit self pkgs; };
        install-offline = import ./tests/vm/install-offline.nix { inherit self pkgs; };
        install-offline-hw = import ./tests/vm/install-offline-hw.nix { inherit self pkgs; };
        install-app-failure = import ./tests/vm/install-offline.nix {
          inherit self pkgs;
          name = "hinteros-install-app-failure";
          # One online-only app (Steam, offered by the installer) that cannot be downloaded here, between two that are on the ISO;
          # onto a disk that already holds an old install.
          apps = [
            "youtube"
            "steam"
            "firefox"
          ];
          failedApps = [ "steam" ];
          onlineAppsHook = true;
          staleTarget = true;
        };
        install-offline-m900 = import ./tests/vm/install-offline.nix {
          inherit self pkgs;
          name = "hinteros-install-offline-m900";
          facterFixture = ./tests/vm/fixtures/facter-lenovo-m900.json;
        };
        time-zone = import ./tests/vm/time-zone.nix { inherit self pkgs; };
        install-validation = import ./tests/vm/install-validation.nix { inherit self pkgs; };
        install-newer = import ./tests/vm/install-newer.nix { inherit self pkgs; };
        apps = import ./tests/eval/apps.nix { inherit self pkgs; };
        runtime-eval = import ./tests/eval/runtime.nix { inherit self pkgs; };
        mk-device = import ./tests/eval/mk-device.nix { inherit self pkgs; };
        hardening-eval = import ./tests/eval/hardening.nix { inherit self pkgs; };
        server-eval = import ./tests/eval/server.nix { inherit self pkgs; };
        server-jellyfin = import ./tests/vm/server-jellyfin.nix { inherit self pkgs; };
        server-network = import ./tests/vm/server-network.nix { inherit self pkgs; };
        server-api = import ./tests/vm/server-api.nix { inherit self pkgs; };
        server-jellyfin-signin = import ./tests/vm/server-jellyfin-signin.nix { inherit self pkgs; };
        daemon-eval = import ./tests/eval/daemon.nix { inherit self pkgs; };
        installer-iso-eval = import ./tests/eval/installer-iso.nix { inherit self pkgs; };
        offline-inputs = import ./tests/eval/offline-inputs.nix { inherit self pkgs; };
        state-check = import ./tests/eval/state-check.nix { inherit self pkgs; };
        profiles-eval = import ./tests/eval/profiles.nix { inherit self pkgs; };
        promote = import ./tests/scripts/promote.nix { inherit self pkgs; };
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.nixfmt
          pkgs.statix
          pkgs.deadnix
        ];
        shellHook = self.checks.${system}.pre-commit.shellHook;
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
