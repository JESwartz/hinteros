# NixOS

- `modules/`: the HinterOS NixOS modules, exported by the flake as `nixosModules`.
  - `session.nix`: greetd autologin into gamescope running the home app.
    Options: `hinteros.session.enable`, `.user` (default `hinteros`), `.compositor`
    (`gamescope` or `cage`), `.environment`, `.homeApp`
    (package, default `pkgs.hinteros-placeholder-home`), `.gamescope.package`, `.gamescope.extraArgs`.
  - `overlay.nix`: adds `overlays.default` to nixpkgs.
- `overlay.nix`, `pkgs/`: the overlay and its packages. `hinteros-placeholder-home` is an xterm
  showing text; the Flutter launcher replaces it.
- `vm/`: the test system (`default.nix`, shared with the VM tests) and the interactive QEMU
  hardware (`qemu.nix`).
- `hardware/`: per-model profiles. The `hardware.facter` report is always the baseline
  (`mkDefault`); a profile matched by DMI vendor/product overrides only that model's quirks.

## VM and gamescope

gamescope does not start on the VM's software Vulkan (llvmpipe lacks DRM format modifiers and
dma-buf export), so the VM and the `boot` test use `hinteros.session.compositor = "cage"`
(software rendering). `nixosConfigurations.vm-gamescope` is the same VM with gamescope, for
a Vulkan-capable setup. Whether gamescope can be tested in a VM is M0 spike 2.
