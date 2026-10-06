# NixOS

- `modules/`: the HinterOS NixOS modules, exported by the flake as `nixosModules`.
- `hardware/`: per-model profiles. The `hardware.facter` report is always the baseline
  (`mkDefault`); a profile matched by DMI vendor/product overrides only that model's quirks.
