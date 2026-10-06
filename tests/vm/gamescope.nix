# Real compositor plus session daemon (spike 3 as an automated test): gamescope runs headless
# on lavapipe (software Vulkan) in Steam mode (-e) with the xterm placeholder as home app under
# the reaper (launcher app id). The daemon sets GAMESCOPECTRL_BASELAYER_APPID, a fake Steam
# game is launched over the session socket and comes to the front (OCR of gamescope's own
# screenshot), and Home (SIGUSR1) brings the placeholder back. Covers session wiring and flags; the launcher flow tests use
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
      imports = [
        self.nixosModules.session
        self.nixosModules.daemon
        self.nixosModules.fake-steam
      ];

      hinteros = {
        daemon.enable = true;
        fakeSteam.enable = true;
        session = {
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
      };

      environment.systemPackages = [
        pkgs.tesseract
        pkgs.socat
        pkgs.xorg.xprop
      ];
      system.stateVersion = "25.11";
      virtualisation = {
        memorySize = 3072;
        cores = 2;
      };
    };

  testScript = ''
    import json
    import shlex

    machine.wait_for_unit("multi-user.target")
    machine.wait_until_succeeds("loginctl list-sessions --no-legend | grep -w hinteros")
    machine.wait_until_succeeds("pgrep -u hinteros -f '/bin/gamescope '")
    machine.wait_until_succeeds("pgrep -u hinteros -f '/bin/xterm '", timeout=60)

    uid = machine.succeed("id -u hinteros").strip()
    env = f"XDG_RUNTIME_DIR=/run/user/{uid}"
    sock = f"/run/user/{uid}/hinteros/session.sock"

    def as_user(cmd):
        return f"runuser -u hinteros -- env {env} DISPLAY=:0 sh -c {shlex.quote(cmd)}"

    def shot():
        # gamescope writes the file asynchronously, a moment after gamescopectl returns.
        machine.execute(f"rm -f /tmp/shot.png; runuser -u hinteros -- env {env} gamescopectl screenshot /tmp/shot.png")
        machine.sleep(2)
        return machine.execute("test -s /tmp/shot.png && tesseract /tmp/shot.png - 2>/dev/null")[1]

    def sees(*words, absent=()):
        # tesseract splits the monospace text ("Hi nter OS"), so ignore whitespace.
        text = "".join(shot().split()).lower()
        return any(w in text for w in words) and not any(w in text for w in absent)

    def wait_sees(what, *words, absent=(), tries=20):
        # Retry: the first frames can be black while a window maps.
        with machine.nested(f"waiting for {what} in a gamescope screenshot"):
            for _ in range(tries):
                if sees(*words, absent=absent):
                    return
                machine.sleep(3)
            raise Exception(f"OCR never found {what}; last: " + shot())

    def root_prop(name):
        return machine.execute(as_user(f"xprop -root {name}"))[1].strip()

    # The home app runs under the reaper, which gives its window the launcher app id.
    machine.succeed("pgrep -u hinteros -x reaper")

    # The daemon waited for / found gamescope's Xwayland and took over focus: without the
    # base-layer property gamescope in Steam mode shows nothing at all.
    machine.wait_for_unit("hinteros-session.service", "hinteros")
    machine.wait_until_succeeds(as_user("xprop -root GAMESCOPECTRL_BASELAYER_APPID | grep -q 4100000000"), timeout=60)
    machine.wait_until_succeeds(as_user("xprop -root GAMESCOPE_FOCUSED_APP | grep -q 4100000000"), timeout=60)
    wait_sees("the placeholder", "hinteros", "placeholder")

    # Session API 0.2 over the socket: launch a fake Steam game by URL.
    def rpc(*msgs, wait=2):
        hello = {"jsonrpc": "2.0", "id": 0, "method": "hello",
                 "params": {"api_version": "0.2", "client": {"name": "gamescope-test", "version": "0"}}}
        payload = "".join(json.dumps(m) + "\n" for m in (hello, *msgs))
        out = machine.succeed(as_user(f"(printf %s {shlex.quote(payload)}; sleep {wait}) | socat -t{wait} - UNIX-CONNECT:{sock}"))
        replies = [json.loads(line) for line in out.splitlines() if line.strip()]
        assert "error" not in replies[0] and replies[0]["result"]["api_version"] == "0.2", replies[0]
        return replies

    replies = rpc({"jsonrpc": "2.0", "id": 1, "method": "apps.launch", "params": {"url": "steam://rungameid/1000002"}})
    launch = next(r for r in replies if r.get("id") == 1)
    assert "error" not in launch and launch["result"]["app"]["gamescope_app_id"] == 1000002, launch

    machine.succeed(f"grep -q 'launch: 1000002' /run/user/{uid}/fake-steam.log")
    wait_sees("the fake game", "fakegame", absent=("placeholder",))
    machine.wait_until_succeeds(as_user("xprop -root GAMESCOPE_FOCUSED_APP | grep -q 1000002"), timeout=60)
    machine.screenshot("fake-game")

    # Home (SIGUSR1 stands in for Guide): the placeholder is back, the game keeps running.
    machine.succeed("pkill -USR1 -u hinteros -f 'hinteros-session --config'")
    wait_sees("the placeholder after Home", "hinteros", "placeholder", absent=("fakegame",))
    machine.succeed("pgrep -u hinteros -f 'Fake game 1000002'")
    machine.screenshot("home-again")

    machine.succeed("pgrep -u hinteros -f '/bin/gamescope '")
  '';
}
