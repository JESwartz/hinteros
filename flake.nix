{
  description = "HinterOS: a NixOS module layer that turns a PC into a controller-driven console and smart TV";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Component repos. Not inputs yet: their flakes are not pushed.
    # Once they are, uncomment, run `nix flake lock`, add `hinteros-launcher` and
    # `hinteros-daemon` to the outputs arguments, and use their packages in
    # nixos/overlay.nix. scripts/dev-override picks these up by input name.
    #
    # hinteros-launcher = {
    #   url = "git+https://justsomeshed.com/JSwartz/HinterOS/hinteros-launcher.git";
    #   inputs.nixpkgs.follows = "nixpkgs";
    # };
    # hinteros-daemon = {
    #   url = "git+https://justsomeshed.com/JSwartz/HinterOS/hinteros-daemon.git";
    #   inputs.nixpkgs.follows = "nixpkgs";
    # };
  };

  outputs =
    {
      self,
      nixpkgs,
      git-hooks,
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
      overlays.default = import ./nixos/overlay.nix;

      nixosModules = {
        default.imports = [
          overlayModule
          ./nixos/modules
        ];
        overlay = overlayModule;
        session = ./nixos/modules/session.nix;
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
