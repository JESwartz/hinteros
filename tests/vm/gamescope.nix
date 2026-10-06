# Smoke test for the real compositor: the session module's gamescope path runs headless on
# lavapipe (software Vulkan) with the xterm placeholder home app, and a gamescope screenshot
# shows the placeholder text. Covers session wiring and flags; the launcher flow tests use
# cage (tests/vm/boot.nix) because Flutter cannot present GL frames under software gamescope
# (M0 spike 2).
#
# Why this works although gamescope crashed earlier in the VM (vkAllocateMemory failure in
# vulkan_create_flat_texture): that was the DRM/scanout path, which needs DRM format
# modifiers and dma-buf export that lavapipe lacks (the spike could not reproduce it with
# headless on the same nixpkgs). The headless backend creates no scanout
# and starts fine, provided lavapipe is selected explicitly (VK_ICD_FILENAMES; no GPU ICD
# exists in the VM) and the session has a real XDG_RUNTIME_DIR (greetd/logind provides it).
{ self, pkgs }:
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-gamescope";
  enableOCR = true;

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ self.nixosModules.session ];

      hinteros.session = {
        enable = true;
        compositor = "gamescope";
        homeApp = pkgs.hinteros-placeholder-home;
        gamescope = {
          backend = "headless";
          extraArgs = [
            "-W"
            "1280"
            "-H"
            "720"
            "-f"
          ];
        };
        environment.VK_ICD_FILENAMES = "/run/opengl-driver/share/vulkan/icd.d/lvp_icd.x86_64.json";
      };

      environment.systemPackages = [ pkgs.tesseract ];
      system.stateVersion = "25.11";
      virtualisation = {
        memorySize = 3072;
        cores = 2;
      };
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_until_succeeds("loginctl list-sessions --no-legend | grep -w hinteros")
    machine.wait_until_succeeds("pgrep -u hinteros -f '/bin/gamescope '")
    machine.wait_until_succeeds("pgrep -u hinteros -f '/bin/xterm '", timeout=60)

    uid = machine.succeed("id -u hinteros").strip()
    env = f"XDG_RUNTIME_DIR=/run/user/{uid}"

    def shot():
        # gamescope writes the file asynchronously, a moment after gamescopectl returns.
        machine.execute(f"rm -f /tmp/shot.png; runuser -u hinteros -- env {env} gamescopectl screenshot /tmp/shot.png")
        machine.sleep(2)
        return machine.execute("test -s /tmp/shot.png && tesseract /tmp/shot.png - 2>/dev/null")[1]

    def has_text():
        # tesseract splits the monospace "HinterOS" ("Hi nter OS"), so ignore whitespace.
        text = "".join(shot().split()).lower()
        return "hinteros" in text or "placeholder" in text

    # Retry: the first frames can be black while xterm maps.
    with machine.nested("waiting for the placeholder text in a gamescope screenshot"):
        for _ in range(20):
            if has_text():
                break
            machine.sleep(3)
        else:
            raise Exception("OCR never found the placeholder text; last: " + shot())

    machine.succeed("pgrep -u hinteros -f '/bin/gamescope '")
  '';
}
