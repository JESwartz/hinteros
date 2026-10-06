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
      };
    };
    hinteros-daemon = {
      url = "git+https://justsomeshed.com/JSwartz/HinterOS/hinteros-daemon.git";
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
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      overlayModule = import ./nixos/modules/overlay.nix { inherit self; };

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

      # mkDevice builds a device from its state.json; see nixos/lib/mk-device.nix.
      lib.mkDevice = import ./nixos/lib/mk-device.nix { inherit self nixpkgs; };

      nixosModules = {
        default.imports = [
          overlayModule
          ./nixos/modules
        ];
        overlay = overlayModule;
        session = ./nixos/modules/session.nix;
        daemon = ./nixos/modules/daemon.nix;
        input = ./nixos/modules/input.nix;
        state = ./nixos/modules/state.nix;
        fake-steam = ./nixos/modules/fake-steam.nix;
        unfree = ./nixos/modules/unfree.nix;
        firefox-kiosk = ./nixos/modules/firefox-kiosk.nix;
        apps = ./nixos/modules/apps.nix;
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
        devbox = import ./devices/devbox { inherit self; };
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
        default = self.packages.${system}.vm;
      };

      apps.${system} = {
        vm = {
          type = "app";
          program = "${self.packages.${system}.vm}/bin/run-hinteros-vm-vm";
          meta.description = "Run the HinterOS test VM in a window";
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
        input-layer = import ./tests/vm/input-layer.nix { inherit self pkgs; };
        fake-steam = import ./tests/vm/fake-steam.nix { inherit self pkgs; };
        config-sync = import ./tests/vm/config-sync.nix { inherit self pkgs; };
        runtime = import ./tests/vm/runtime.nix { inherit self pkgs; };
        hardening = import ./tests/vm/hardening.nix { inherit self pkgs; };
        tv-apps = import ./tests/vm/tv-apps.nix { inherit self pkgs; };
        typing = import ./tests/vm/typing.nix { inherit self pkgs; };
        install-validation = import ./tests/vm/install-validation.nix { inherit self pkgs; };
        apps = import ./tests/eval/apps.nix { inherit self pkgs; };
        runtime-eval = import ./tests/eval/runtime.nix { inherit self pkgs; };
        mk-device = import ./tests/eval/mk-device.nix { inherit self pkgs; };
        hardening-eval = import ./tests/eval/hardening.nix { inherit self pkgs; };
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
