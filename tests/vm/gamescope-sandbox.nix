# The display split under gamescope, headless as in
# tests/vm/gamescope.nix: gamescope runs 2 + 4 Xwaylands (#0 the home app and the OSK, #1 Steam's
# game display, #2-#5 the app displays, one per running app). A sandboxed app started with
# apps.launch must land on #2, at the output size (1280x1024; the nested size is 640x512, which
# the app displays kept without the patch), get focus (apps.launch / Home / apps.focus) and
# keyboard input, and from inside its sandbox reach no other display: not through socket files
# (only its own is bound) and not through the abstract sockets @/tmp/.X11-unix/X<n> (gamescope is
# patched not to open them; the sandbox shares the network namespace). XTEST from #2 must not
# type into the home app. Steam's and gamescope's control properties set on #2 (its root:
# GAMESCOPECTRL_BASELAYER_APPID, mode control, new Xwayland; the app's window: STEAM_GAME,
# STEAM_OVERLAY, STEAM_INPUT_FOCUS, GAMESCOPE_EXTERNAL_OVERLAY) change neither focus nor the
# app's id nor global state, and neither do the window's set before it is mapped (an app on #3:
# its own id, not the STEAM_GAME it claims; overlay properties do not make it an overlay); the
# same mode control on #0 still works. CLIPBOARD and PRIMARY go from #0 to #1 but never to or
# from an app display, not even through a SelectionNotify sent to gamescope (on #0 only a
# SelectionNotify for gamescope's own window counts). A second app lands on #3
# and cannot reach #2 either. With every app
# display in use, apps.launch answers no_app_display; closing an app frees its display. A fake
# Steam game lands on no app display. The number of app displays follows the profile's setting
# (apps.displays.set, then session.restart: 1 -> 3 Xwaylands). Prints the Xwaylands' RSS.
{ self, pkgs }:
let
  # Logs every line typed into it (the home app: it must never get the app's XTEST keys).
  homeLog = pkgs.writeShellApplication {
    name = "homelog";
    runtimeInputs = [ pkgs.xterm ];
    text = ''
      exec xterm -T homelog -geometry 20x4 -fa Monospace -fs 10 \
        -e sh -c 'exec cat >> /home/hinteros-p1/home-typed'
    '';
  };

  # Inside the sandbox: one `<check>=yes|no` line per check to $HOME/probe.txt; then the first
  # line typed into its window to $HOME/typed; then, when $HOME/inject appears, types "injected"
  # with XTEST on its own display (while the home app has focus).
  probeScript = pkgs.writeShellApplication {
    name = "hinteros-display-probe";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.socat
      pkgs.xdpyinfo
      pkgs.xdotool
    ];
    text = ''
      check() {
        local name="$1"
        shift
        if "$@" >/dev/null 2>&1; then echo "$name=yes"; else echo "$name=no"; fi
      }
      abstract() {
        timeout 3 socat -u OPEN:/dev/null "ABSTRACT-CONNECT:/tmp/.X11-unix/X$1"
      }
      {
        echo "display=$DISPLAY"
        check x11_own xdpyinfo
        for n in 0 1 2 3 4 5; do
          check "x11_$n" xdpyinfo -display ":$n"
          check "file_$n" test -e "/tmp/.X11-unix/X$n"
          check "abstract_$n" abstract "$n"
        done
      } > "$HOME/probe.tmp"
      mv "$HOME/probe.tmp" "$HOME/probe.txt"
      IFS= read -r line
      printf '%s\n' "$line" > "$HOME/typed"
      while [ ! -e "$HOME/inject" ]; do sleep 1; done
      xdotool type --delay 50 "injected"
      xdotool key Return
      echo ok > "$HOME/injected"
      exec sleep infinity
    '';
  };
  # An X11 client whose window has properties (NAME=VALUE, CARDINAL) set before it is mapped:
  # what gamescope reads when it adds the window, not on a later PropertyNotify.
  premapped =
    pkgs.writers.writePython3Bin "premapped" { libraries = [ pkgs.python3Packages.xlib ]; }
      ''
        import sys
        import time

        from Xlib import Xatom, display

        d = display.Display()
        s = d.screen()
        # Painted: gamescope does not focus a window that never showed anything.
        w = s.root.create_window(
            0, 0, 400, 300, 0, s.root_depth, background_pixel=s.white_pixel
        )
        w.set_wm_name("premapped")
        for arg in sys.argv[1:]:
            name, value = arg.split("=")
            w.change_property(d.intern_atom(name), Xatom.CARDINAL, 32, [int(value)])
        w.map()
        d.sync()
        while True:
            time.sleep(60)
      '';
  # Sends gamescope's window (_NET_SUPPORTING_WM_CHECK) a SelectionNotify it never asked for:
  # SELECTION (CLIPBOARD or PRIMARY) is in a UTF8_STRING property on the requestor, the
  # client's own window ("own") or gamescope's ("gamescope"; any client can set it).
  forgeSelection =
    pkgs.writers.writePython3Bin "forge-selection" { libraries = [ pkgs.python3Packages.xlib ]; }
      ''
        import sys
        import time

        from Xlib import X, Xatom, display
        from Xlib.protocol import event

        selection, who, text = sys.argv[1:]
        d = display.Display()
        root = d.screen().root
        check = d.intern_atom("_NET_SUPPORTING_WM_CHECK")
        wm = root.get_full_property(check, Xatom.WINDOW).value[0]
        gamescope = d.create_resource_object("window", wm)
        own = root.create_window(0, 0, 1, 1, 0, X.CopyFromParent)
        requestor = gamescope if who == "gamescope" else own
        prop = d.intern_atom("HINTEROS_FORGED")
        utf8 = d.intern_atom("UTF8_STRING")
        requestor.change_property(prop, utf8, 8, text.encode())
        gamescope.send_event(
            event.SelectionNotify(
                time=X.CurrentTime,
                requestor=requestor,
                selection=d.intern_atom(selection),
                target=utf8,
                property=prop,
            )
        )
        d.sync()
        # The own window must stay until gamescope reads the property.
        time.sleep(3)
      '';
  probe = pkgs.writeShellApplication {
    name = "hinteros-display-probe-term";
    runtimeInputs = [ pkgs.xterm ];
    text = ''
      exec xterm -T probe -geometry 20x4 -fa Monospace -fs 10 -e ${pkgs.lib.getExe probeScript}
    '';
  };
in
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-gamescope-sandbox";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [
        self.nixosModules.session
        self.nixosModules.daemon
        self.nixosModules.fake-steam
      ];

      hinteros = {
        daemon = {
          enable = true;
          osk.enable = false;
          # Five probe apps, four app displays; two apps that set window properties before mapping.
          session.settings.apps =
            map
              (id: {
                inherit id;
                name = id;
                command = [ (pkgs.lib.getExe probe) ];
              })
              [
                "probe"
                "probe2"
                "probe3"
                "probe4"
                "probe5"
              ]
            ++ [
              {
                id = "premapped";
                name = "premapped";
                command = [
                  (pkgs.lib.getExe premapped)
                  "STEAM_GAME=7777"
                ];
              }
              {
                id = "premapped-overlay";
                name = "premapped-overlay";
                command = [
                  (pkgs.lib.getExe premapped)
                  "STEAM_OVERLAY=1"
                  "STEAM_INPUT_FOCUS=1"
                  "GAMESCOPE_EXTERNAL_OVERLAY=1"
                ];
              }
            ];
        };
        fakeSteam.enable = true;
        session = {
          enable = true;
          compositor = "gamescope";
          homeApp = homeLog;
          gamescope = {
            backend = "headless";
            extraArgs = [
              "-W"
              "1280"
              "-H"
              "1024"
              "-w"
              "640"
              "-h"
              "512"
            ];
          };
          environment.VK_ICD_FILENAMES = "/run/opengl-driver/share/vulkan/icd.d/lvp_icd.x86_64.json";
        };
      };

      environment.systemPackages = [
        pkgs.socat
        pkgs.xdotool
        pkgs.xclip
        forgeSelection
        pkgs.xorg.xprop
        pkgs.xorg.xwininfo
        pkgs.iproute2
        pkgs.procps
      ];
      system.stateVersion = "25.11";
      virtualisation = {
        memorySize = 3072;
        cores = 2;
      };
    };

  testScript = ''
    import json
    import re
    import shlex

    machine.wait_for_unit("multi-user.target")
    machine.wait_until_succeeds("pgrep -u hinteros-p1 -f '/bin/gamescope '")
    machine.wait_for_unit("hinteros-session.service", "hinteros-p1")
    uid = machine.succeed("id -u hinteros-p1").strip()
    env = f"XDG_RUNTIME_DIR=/run/user/{uid}"
    sock = f"/run/user/{uid}/hinteros/session.sock"
    home = "/home/hinteros-p1"
    box = f"{home}/.local/share/hinteros/sandbox/probe"

    def as_user(cmd, display=":0"):
        return f"runuser -u hinteros-p1 -- env {env} DISPLAY={display} sh -c {shlex.quote(cmd)}"

    def root_prop(name):
        return machine.execute(as_user(f"xprop -root {name}"))[1].strip()

    def geometry(args, display):
        out = machine.succeed(as_user(f"xwininfo {args}", display))
        sizes = dict(re.findall(r"(Width|Height): (\d+)", out))
        return int(sizes["Width"]), int(sizes["Height"])

    def rpc(*msgs, wait=2):
        hello = {"jsonrpc": "2.0", "id": 0, "method": "hello",
                 "params": {"api_version": "1.0", "client": {"name": "gamescope-sandbox-test", "version": "0"}}}
        payload = "".join(json.dumps(m) + "\n" for m in (hello, *msgs))
        out = machine.succeed(as_user(f"(printf %s {shlex.quote(payload)}; sleep {wait}) | socat -t{wait} - UNIX-CONNECT:{sock}"))
        replies = [json.loads(line) for line in out.splitlines() if line.strip()]
        assert "error" not in replies[0], replies[0]
        return replies

    def ok(method, params=None, wait=2):
        reply = next(r for r in rpc({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}, wait=wait) if r.get("id") == 1)
        assert "error" not in reply, reply
        return reply["result"]

    def wait_focused(app_id):
        machine.wait_until_succeeds(as_user(f"xprop -root GAMESCOPE_FOCUSED_APP | grep -qw {app_id}"), timeout=60)

    def probe_result(app):
        d = f"{home}/.local/share/hinteros/sandbox/{app}"
        machine.wait_until_succeeds(f"test -s {d}/probe.txt", timeout=60)
        res = dict(line.split("=", 1) for line in machine.succeed(f"cat {d}/probe.txt").split())
        print(app, res)
        return res

    def assert_alone(res, own):
        assert res["display"] == f":{own}", res
        assert res["x11_own"] == "yes" and res[f"x11_{own}"] == "yes", res
        for n in range(6):
            if n != own:
                assert res[f"x11_{n}"] == "no" and res[f"file_{n}"] == "no", (n, res)
            assert res[f"abstract_{n}"] == "no", (n, res)

    def call(method, params=None):
        return next(r for r in rpc({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}) if r.get("id") == 1)

    # Six Xwaylands, :0-:5 (nothing else runs X here; 2 + the default 4); none on an abstract
    # socket. The wrapper told the daemon how many app displays there are.
    machine.wait_until_succeeds(as_user("xprop -root GAMESCOPECTRL_BASELAYER_APPID | grep -q 4100000000"), timeout=90)
    machine.succeed("pgrep -u hinteros-p1 -af '/bin/gamescope ' | grep -q -- '--xwayland-count 6 '")
    for n in range(6):
        machine.wait_until_succeeds(f"test -S /tmp/.X11-unix/X{n}")
    machine.fail("test -e /tmp/.X11-unix/X6")
    assert machine.succeed(f"cat /run/user/{uid}/hinteros/app-displays").strip() == "4"
    assert ok("apps.displays.get") == {"count": 4, "active": 4, "min": 1, "max": 8}
    print(machine.succeed("ss -xlp | grep X11-unix"))
    machine.fail("ss -xlp | grep -q '@/tmp/.X11-unix'")
    assert geometry("-root", ":0") == (1280, 1024), geometry("-root", ":0")
    assert geometry("-root", ":1") == (640, 512), geometry("-root", ":1")
    for n in range(2, 6):
        assert geometry("-root", f":{n}") == (1280, 1024), ("app display follows the output", n, geometry("-root", f":{n}"))
    # Idle app displays, for the memory cost.
    print(machine.succeed("ps -o pid,rss,args -C Xwayland"))
    machine.wait_until_succeeds(as_user("xwininfo -name homelog", ":0"))

    # The sandboxed app lands on :2 at the output size, with focus.
    launched = ok("apps.launch", {"id": "probe"})["app"]
    app_id = launched["gamescope_app_id"]
    assert_alone(probe_result("probe"), 2)
    machine.wait_until_succeeds(as_user("xwininfo -name probe", ":2"), timeout=30)
    machine.fail(as_user("xwininfo -name probe", ":0"))
    machine.wait_until_succeeds(as_user("xwininfo -name probe | grep -q 'Width: 1280'", ":2"), timeout=30)
    assert geometry("-name probe", ":2") == (1280, 1024), geometry("-name probe", ":2")
    wait_focused(app_id)

    # Home: the launcher again; apps.focus: the app again.
    machine.succeed("pkill -USR1 -u hinteros-p1 -f 'hinteros-session --config'")
    wait_focused(4100000000)
    ok("apps.focus", {"id": "probe"})
    wait_focused(app_id)

    # Keyboard input reaches the app on :2 (XTEST of a trusted client on :0, through gamescope's
    # input emulation to the focused window; headless gamescope reads no input devices).
    machine.succeed(as_user("xdotool type --delay 50 hello && xdotool key Return", ":0"))
    machine.wait_until_succeeds(f"grep -qx hello {box}/typed", timeout=30)
    machine.fail(f"grep -q hello {home}/home-typed")

    # XTEST from the app's own display while the home app has focus: never reaches the home app.
    machine.succeed("pkill -USR1 -u hinteros-p1 -f 'hinteros-session --config'")
    wait_focused(4100000000)
    machine.succeed(f"runuser -u hinteros-p1 -- touch {box}/inject")
    machine.wait_until_succeeds(f"test -e {box}/injected", timeout=30)
    machine.sleep(3)
    typed_home = machine.execute(f"cat {home}/home-typed")[1]
    print("home app got:", repr(typed_home))
    assert "injected" not in typed_home, typed_home

    # Control properties from the apps' display count for nothing (the home app has focus).
    def focused():
        return root_prop("GAMESCOPE_FOCUSED_APP")

    def focusable():
        return root_prop("GAMESCOPE_FOCUSABLE_APPS")

    assert str(app_id) in focusable(), focusable()
    sockets = machine.succeed("ls /tmp/.X11-unix").split()
    ctrl_before = root_prop("GAMESCOPECTRL_BASELAYER_APPID")
    machine.succeed(as_user(f"xprop -root -f GAMESCOPECTRL_BASELAYER_APPID 32c -set GAMESCOPECTRL_BASELAYER_APPID {app_id}", ":2"))
    machine.succeed(as_user("xprop -root -f GAMESCOPE_XWAYLAND_MODE_CONTROL 32c -set GAMESCOPE_XWAYLAND_MODE_CONTROL 1,320,240,1", ":2"))
    machine.succeed(as_user("xprop -root -f GAMESCOPE_CREATE_XWAYLAND_SERVER 32c -set GAMESCOPE_CREATE_XWAYLAND_SERVER 7", ":2"))
    for atom, value in [("STEAM_GAME", 4100000000), ("STEAM_OVERLAY", 1), ("STEAM_INPUT_FOCUS", 1),
                        ("GAMESCOPE_EXTERNAL_OVERLAY", 1)]:
        machine.succeed(as_user(f"xprop -name probe -f {atom} 32c -set {atom} {value}", ":2"))
    machine.sleep(3)
    assert "4100000000" in focused(), ("focus moved", focused())
    assert root_prop("GAMESCOPECTRL_BASELAYER_APPID") == ctrl_before, root_prop("GAMESCOPECTRL_BASELAYER_APPID")
    assert str(app_id) in focusable(), ("the app's id changed", focusable())
    assert geometry("-root", ":1") == (640, 512), ("mode control from :2", geometry("-root", ":1"))
    assert machine.succeed("ls /tmp/.X11-unix").split() == sockets, "a new Xwayland from :2"
    # The same window properties set before the window is mapped (what gamescope reads when it
    # adds a window), by apps on the next display (:3): the app id claimed with STEAM_GAME is not
    # taken (the window has the app's own id), and the overlay properties do not make the window
    # an overlay (it gets focus like any app window). Each app is closed again, which frees :3.
    for pm, claimed in (("premapped", "7777"), ("premapped-overlay", None)):
        pm_id = ok("apps.launch", {"id": pm})["app"]["gamescope_app_id"]
        machine.wait_until_succeeds(as_user("xwininfo -name premapped", ":3"), timeout=30)
        wait_focused(pm_id)
        if claimed:
            for prop in (focused(), focusable()):
                assert not re.search(rf"\b{claimed}\b", prop), (pm, prop)
        ok("apps.close", {"id": pm})
        machine.wait_until_fails("pgrep -u hinteros-p1 -f bin/premapped", timeout=30)
        machine.wait_until_succeeds(as_user(f"! xprop -root GAMESCOPE_FOCUSABLE_APPS | grep -qw {pm_id}"), timeout=30)
    # Clipboard and primary selection: gamescope still copies them from #0 to #1, but never to or
    # from an app display. Apps on one display still share them there.
    def sel_set(display, sel, text):
        machine.succeed(as_user(f"printf {text} | xclip -selection {sel} -i >/dev/null 2>&1", display))

    def sel_get(display, sel):
        return machine.execute(as_user(f"timeout 5 xclip -o -selection {sel}", display))[1].strip()

    for sel in ("clipboard", "primary"):
        sel_set(":0", sel, f"home-{sel}")
        machine.wait_until_succeeds(as_user(f"timeout 5 xclip -o -selection {sel} | grep -qx home-{sel}", ":1"), timeout=30)
        machine.sleep(2)
        assert sel_get(":2", sel) == "", (sel, "home -> app display", sel_get(":2", sel))
        sel_set(":2", sel, f"app-{sel}")
        assert sel_get(":2", sel) == f"app-{sel}", (sel, sel_get(":2", sel))
        machine.sleep(3)
        assert sel_get(":0", sel) == f"home-{sel}", (sel, "app display -> home", sel_get(":0", sel))
        assert sel_get(":3", sel) == "", (sel, "app display -> app display", sel_get(":3", sel))
    # A SelectionNotify that gamescope did not ask for: from an app display it changes nothing
    # (requestor the app's window or gamescope's), and on :0 only one for gamescope's own window
    # counts. The last one is the control: it shows the forged event works.
    def forge(display, sel, who, text):
        machine.succeed(as_user(f"forge-selection {sel.upper()} {who} {text}", display))
        machine.sleep(2)

    for sel in ("clipboard", "primary"):
        for display, who in ((":2", "own"), (":2", "gamescope"), (":0", "own")):
            forge(display, sel, who, f"forged-{sel}")
            for home_display in (":0", ":1"):
                got = sel_get(home_display, sel)
                assert got == f"home-{sel}", (sel, "forged from", display, who, home_display, got)
        forge(":0", sel, "gamescope", f"forged-{sel}")
        machine.wait_until_succeeds(as_user(f"timeout 5 xclip -o -selection {sel} | grep -qx forged-{sel}", ":1"), timeout=30)
    machine.execute("pkill -u hinteros-p1 -x xclip")
    # The app's window is still an ordinary app window with its own id.
    ok("apps.focus", {"id": "probe"})
    wait_focused(app_id)
    machine.succeed("pkill -USR1 -u hinteros-p1 -f 'hinteros-session --config'")
    wait_focused(4100000000)
    # The same mode control on :0 still works (and is undone).
    machine.succeed(as_user("xprop -root -f GAMESCOPE_XWAYLAND_MODE_CONTROL 32c -set GAMESCOPE_XWAYLAND_MODE_CONTROL 1,320,240,1", ":0"))
    machine.wait_until_succeeds(as_user("xwininfo -root | grep -q 'Width: 320'", ":1"), timeout=30)
    machine.succeed(as_user("xprop -root -f GAMESCOPE_XWAYLAND_MODE_CONTROL 32c -set GAMESCOPE_XWAYLAND_MODE_CONTROL 1,640,512,1", ":0"))
    machine.wait_until_succeeds(as_user("xwininfo -root | grep -q 'Width: 640'", ":1"), timeout=30)

    # A second app gets the next display, and cannot reach the first app's (nor any other).
    second = ok("apps.launch", {"id": "probe2"})["app"]
    assert_alone(probe_result("probe2"), 3)
    machine.wait_until_succeeds(as_user("xwininfo -name probe", ":3"), timeout=30)
    wait_focused(second["gamescope_app_id"])
    # Switching between running apps.
    ok("apps.focus", {"id": "probe"})
    wait_focused(app_id)
    ok("apps.focus", {"id": "probe2"})
    wait_focused(second["gamescope_app_id"])

    # A fake Steam game takes no app display.
    ok("apps.launch", {"url": "steam://rungameid/1000002"})
    machine.wait_until_succeeds(
        as_user("xwininfo -name 'Fake game 1000002'", ":0") + " || " + as_user("xwininfo -name 'Fake game 1000002'", ":1"),
        timeout=60,
    )
    for n in range(2, 6):
        machine.fail(as_user("xwininfo -name 'Fake game 1000002'", f":{n}"))
    for n in (0, 1):
        if machine.execute(as_user("xwininfo -name 'Fake game 1000002'", f":{n}"))[0] == 0:
            print(f"fake Steam game on :{n}")
    wait_focused(1000002)

    # All four in use: the fifth app is refused, naming the four.
    for app, n in (("probe3", 4), ("probe4", 5)):
        ok("apps.launch", {"id": app})
        assert_alone(probe_result(app), n)
    full = call("apps.launch", {"id": "probe5"})
    print("full:", full)
    assert full["error"]["code"] == 2009, full
    assert sorted(a["id"] for a in full["error"]["data"]["apps"]) == ["probe", "probe2", "probe3", "probe4"], full
    machine.fail(f"test -e {home}/.local/share/hinteros/sandbox/probe5/probe.txt")

    # The Xwaylands' memory, all four app displays in use.
    print(machine.succeed("ps -o pid,rss,args -C Xwayland"))
    print(machine.succeed("for p in $(pgrep -x Xwayland); do echo '== pid' $p; grep -E '^(Rss|Pss|Private_Dirty|Private_Clean):' /proc/$p/smaps_rollup; done"))

    def until(fn, timeout=60):
        for _ in range(timeout):
            try:
                if fn():
                    return
            except Exception as e:
                print("not yet:", e)
            machine.sleep(1)
        assert fn(), "timed out"

    # Closing one frees its display once its processes are gone: then the fifth app gets it.
    ok("apps.close", {"id": "probe3"})
    until(lambda: "error" not in call("apps.launch", {"id": "probe5"}), timeout=30)
    assert_alone(probe_result("probe5"), 4)

    # The setting: applies at the next session start.
    assert ok("apps.displays.set", {"count": 1}) == {"count": 1, "active": 4, "min": 1, "max": 8}
    assert machine.succeed(f"cat {home}/.local/state/hinteros/app-displays").strip() == "1"
    bad = call("apps.displays.set", {"count": 9})
    assert bad["error"]["code"] == -32602, bad
    old_gs = machine.succeed("pgrep -u hinteros-p1 -f '/bin/gamescope '").strip()
    ok("session.restart")
    machine.wait_until_fails(f"kill -0 {old_gs}", timeout=60)
    machine.wait_until_succeeds("pgrep -u hinteros-p1 -af '/bin/gamescope ' | grep -q -- '--xwayland-count 3 '", timeout=120)
    machine.wait_until_succeeds(f"test \"$(cat /run/user/{uid}/hinteros/app-displays 2>/dev/null)\" = 1", timeout=60)
    machine.wait_until_succeeds(as_user("xprop -root GAMESCOPECTRL_BASELAYER_APPID | grep -q 4100000000"), timeout=90)
    for n in range(3):
        machine.wait_until_succeeds(f"test -S /tmp/.X11-unix/X{n}", timeout=60)
    # No fourth Xwayland of this user (a socket file may be left over, its server is gone).
    machine.wait_until_succeeds("! test -e /tmp/.X3-lock || ! kill -0 $(cat /tmp/.X3-lock)", timeout=60)
    until(lambda: ok("apps.displays.get") == {"count": 1, "active": 1, "min": 1, "max": 8}, timeout=120)
    machine.succeed(f"rm -f {home}/.local/share/hinteros/sandbox/probe/probe.txt")
    ok("apps.launch", {"id": "probe"})
    assert probe_result("probe")["display"] == ":2"
    again = call("apps.launch", {"id": "probe2"})
    assert again["error"]["code"] == 2009, again
    assert [a["id"] for a in again["error"]["data"]["apps"]] == ["probe"], again
  '';
}
