# Real compositor plus session daemon (spike 3 as an automated test): gamescope runs headless
# on lavapipe (software Vulkan) in Steam mode (-e) with the xterm placeholder as home app under
# the reaper (launcher app id). The daemon sets GAMESCOPECTRL_BASELAYER_APPID. Over the session
# socket (API 0.15) the test checks games.list (tools filtered), launching a fake Steam game (it
# comes to the front, OCR of gamescope's own screenshot), Home (SIGUSR1), apps.close
# (app_exited closed, placeholder back), Steam itself (Big Picture, app 769) and a Steam Guard
# style pop-up (steam_attention, steam.focus). Covers session wiring and flags; the launcher flow
# tests use cage (tests/vm/boot.nix) because Flutter cannot present GL frames under software gamescope
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

    # Session API 0.15 over the socket.
    def rpc(*msgs, wait=2):
        hello = {"jsonrpc": "2.0", "id": 0, "method": "hello",
                 "params": {"api_version": "0.15", "client": {"name": "gamescope-test", "version": "0"}}}
        payload = "".join(json.dumps(m) + "\n" for m in (hello, *msgs))
        out = machine.succeed(as_user(f"(printf %s {shlex.quote(payload)}; sleep {wait}) | socat -t{wait} - UNIX-CONNECT:{sock}"))
        replies = [json.loads(line) for line in out.splitlines() if line.strip()]
        assert "error" not in replies[0] and replies[0]["result"]["api_version"] == "0.15", replies[0]
        return replies

    def call(method, params=None, wait=2):
        replies = rpc({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}, wait=wait)
        return next(r for r in replies if r.get("id") == 1)

    def ok(method, params=None, wait=2):
        reply = call(method, params, wait)
        assert "error" not in reply, reply
        return reply["result"]

    # Steam is installed here (the fake Steam), so apps.list leads with its built-in tile.
    assert ok("apps.list")["apps"][0]["id"] == "steam", ok("apps.list")

    # Runtime settings wiring: gamescope and the daemon both run with the mode files
    # (this test still pins -W/-H because the headless backend has no real display).
    for name, pat in (("gamescope", "/bin/gamescope "), ("hinteros-session", "hinteros-session --config")):
        pid = machine.succeed(f"pgrep -u hinteros -f '{pat}' | head -n1").strip()
        penv = machine.succeed(f"tr '\0' '\n' < /proc/{pid}/environ")
        assert "GAMESCOPE_MODE_SAVE_FILE=/home/hinteros/.local/state/hinteros/gamescope-modes" in penv, (name, penv)
        assert f"GAMESCOPE_PATCHED_EDID_FILE=/run/user/{uid}/gamescope-edid" in penv, (name, penv)
    machine.succeed("test -d /home/hinteros/.local/state/hinteros")
    # display.modes answers under gamescope (modes, or a clean error: the headless backend writes no modes file).
    modes = call("display.modes")
    print("display.modes", modes)
    assert "result" in modes or modes["error"]["data"]["service"] == "display", modes

    # A long-lived subscriber, so events can be checked after the fact.
    sub = [
        {"jsonrpc": "2.0", "id": 0, "method": "hello",
         "params": {"api_version": "0.15", "client": {"name": "gamescope-test-events", "version": "0"}}},
        {"jsonrpc": "2.0", "id": 1, "method": "subscribe",
         "params": {"events": ["app_started", "app_exited", "focus_changed", "steam_attention"]}},
    ]
    payload = "".join(json.dumps(m) + "\n" for m in sub)
    machine.succeed(as_user(
        f"(printf %s {shlex.quote(payload)}; sleep 3000) | socat - UNIX-CONNECT:{sock} > /tmp/events.log 2>&1 &"
        " sleep 1"
    ))

    def events(name):
        out = machine.succeed("cat /tmp/events.log")
        msgs = [json.loads(line) for line in out.splitlines() if line.strip().startswith("{")]
        return [m["params"] for m in msgs if m.get("method") == name]

    def wait_event(name, pred=lambda p: True):
        with machine.nested(f"waiting for event {name}"):
            for _ in range(30):
                found = [p for p in events(name) if pred(p)]
                if found:
                    return found[-1]
                machine.sleep(1)
            raise Exception(f"no {name} event; log: " + machine.succeed("cat /tmp/events.log"))

    # games.list: the fake library's games, none of its tools (Proton, runtime, redistributables).
    games = ok("games.list")["games"]
    assert sorted(g["name"] for g in games) == ["Fake Platformer", "Fake Puzzle", "Fake Racer"], games
    assert all(g["artwork"]["portrait"] for g in games), games

    # Launch a game by Steam URL: its window comes to the front.
    launch = call("apps.launch", {"url": "steam://rungameid/1000002"})
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

    # Launching it again focuses the running game; apps.close ends it and the placeholder returns.
    ok("apps.launch", {"url": "steam://rungameid/1000002"})
    wait_sees("the fake game again", "fakegame", absent=("placeholder",))
    ok("apps.close", {"id": "steam-1000002"})
    wait_event("app_exited", lambda p: p["id"] == "steam-1000002" and p["reason"] == "closed")
    wait_sees("the placeholder after close", "hinteros", "placeholder", absent=("fakegame",))
    machine.fail("pgrep -u hinteros -f 'Fake game 1000002'")

    # Steam itself: Big Picture is gamescope app 769.
    steam = ok("apps.launch", {"id": "steam"}, wait=3)["app"]
    assert steam["id"] == "steam" and steam["gamescope_app_id"] == 769, steam
    wait_sees("Big Picture", "fakebigpicture", absent=("placeholder",))
    machine.wait_until_succeeds(as_user("xprop -root GAMESCOPE_FOCUSED_APP | grep -q 769"), timeout=60)
    machine.screenshot("big-picture")
    machine.succeed("pkill -USR1 -u hinteros -f 'hinteros-session --config'")
    wait_sees("the placeholder after Big Picture", "hinteros", "placeholder", absent=("fakebigpicture",))

    # Close Steam (it shuts down, through the stub), then a Steam Guard style pop-up appears while the
    # placeholder is focused: steam_attention with its title, steam.focus shows it, Home returns.
    ok("apps.close", {"id": "steam"})
    wait_event("app_exited", lambda p: p["id"] == "steam" and p["reason"] == "closed")
    machine.succeed(f"grep -q '^shutdown$' /run/user/{uid}/fake-steam.log")
    # A Steam window within 10 s of our own Steam request (here the close) is Steam's answer and gets
    # focus (daemon README, "Steam games"); only a later pop-up is a steam_attention banner.
    machine.sleep(12)
    machine.succeed(as_user("steam --hinteros-fake-popup 'Steam Guard'"))
    attention = wait_event("steam_attention", lambda p: any(w["title"] == "Steam Guard" for w in p["windows"]))
    assert attention["windows"], attention
    ok("steam.focus", wait=3)
    wait_sees("the Steam Guard pop-up", "steamguard", absent=("placeholder",))
    machine.screenshot("steam-guard")
    machine.succeed("pkill -USR1 -u hinteros -f 'hinteros-session --config'")
    wait_sees("the placeholder after the pop-up", "hinteros", "placeholder", absent=("steamguard",))

    machine.succeed("pgrep -u hinteros -f '/bin/gamescope '")

    # greetd restarted (what a crashed or restarted session looks like from the outside): the new
    # gamescope gets a new Xwayland, the session daemon is a new process of the new user manager,
    # and it must take over focus again - the base layer property is set and the home app shows.
    old_inv = machine.succeed(as_user("systemctl --user show -p InvocationID --value hinteros-session.service")).strip()
    old_gs = machine.succeed("pgrep -u hinteros -o -f '/bin/gamescope '").strip()
    print("greetd restart: old gamescope", old_gs, "old daemon invocation", old_inv)
    machine.succeed("systemctl restart greetd")
    machine.wait_until_fails(f"kill -0 {old_gs}", timeout=60)
    machine.wait_until_succeeds("pgrep -u hinteros -f '/bin/gamescope '", timeout=120)
    machine.wait_until_succeeds("loginctl list-sessions --no-legend | grep -w hinteros", timeout=120)
    machine.wait_until_succeeds("test -S /run/user/" + uid + "/hinteros/session.sock", timeout=120)
    machine.wait_until_succeeds(as_user("systemctl --user show -p InvocationID --value hinteros-session.service | grep -qvx " + old_inv), timeout=120)
    machine.wait_until_succeeds(as_user("xprop -root GAMESCOPECTRL_BASELAYER_APPID | grep -q 4100000000"), timeout=120)
    machine.wait_until_succeeds(as_user("xprop -root GAMESCOPE_FOCUSED_APP | grep -q 4100000000"), timeout=120)
    wait_sees("the placeholder after greetd restarted", "hinteros", "placeholder")
  '';
}
