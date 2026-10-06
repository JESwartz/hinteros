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

      nixosModules = {
        default.imports = [
          overlayModule
          ./nixos/modules
        ];
        overlay = overlayModule;
        session = ./nixos/modules/session.nix;
        daemon = ./nixos/modules/daemon.nix;
      };

      nixosConfigurations = {
        vm = mkVm [ ];
        # Same VM with the real compositor; needs a Vulkan GPU (e.g. virtio-gpu venus).
        vm-gamescope = mkVm [ { hinteros.session.compositor = "gamescope"; } ];
      };

      packages.${system} = {
        vm = self.nixosConfigurations.vm.config.system.build.vm;
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
