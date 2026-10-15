# App size under gamescope (README "Display size"): the home app and the apps the daemon starts
# must cover the whole output, at the output's resolution, whatever its aspect. Regression test
# for the real-hardware bug where the launcher (a native Wayland client) was drawn as a small,
# blurry square: gamescope 3.16.31 never sizes Wayland toplevels, so apps now run on Xwayland,
# whose first server and the app displays (:2 and up) follow the output (--xwayland-count 2 + 4,
# xwayland-size-all.patch)
# and whose focused windows are resized to it (--force-windows-fullscreen).
#
# Two machines with gamescope's headless backend (lavapipe, as in tests/vm/gamescope.nix):
#   wide:   a 1920x1080 output.
#   square: a 1280x1024 (5:4) output with a smaller nested size (-w 640 -h 512). That stands in
#           for gamescope having started before the display came up (it then starts at 1280x720):
#           Xwaylands :0 and :2-:5 must still be the output size, not the nested size (:1 is).
# On each: the home app (an xterm, solid blue, that asks for a 20x4-character window and never
# for fullscreen) runs under the reaper like the launcher; its window and the Xwayland root must
# equal the output size and a gamescope screenshot must be blue edge to edge. Then the daemon
# starts an X11 app (solid red, same small size, like Firefox it is an Xwayland client) with
# apps.launch: same checks in red (on :2, the apps' Xwayland). Also: GDK_BACKEND=x11 for the compositor and the daemon, and
# gamescope's output in the journal (hinteros-compositor).
{ self, pkgs }:
let
  solidTerm =
    name: colour:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [ pkgs.xterm ];
      text = ''
        exec xterm -T ${name} -geometry 20x4 -bg '${colour}' -fg '${colour}' -cr '${colour}' \
          -fa Monospace -fs 10 -e sleep infinity
      '';
    };
  homefill = solidTerm "homefill" "#0000ff";
  appfill = solidTerm "appfill" "#ff0000";

  node =
    gamescopeArgs:
    { pkgs, ... }:
    {
      imports = [
        self.nixosModules.session
        self.nixosModules.daemon
      ];

      hinteros = {
        daemon = {
          enable = true;
          osk.enable = false;
          session.settings.apps = [
            {
              id = "appfill";
              name = "App fill";
              command = [ (pkgs.lib.getExe appfill) ];
            }
          ];
        };
        session = {
          enable = true;
          compositor = "gamescope";
          homeApp = homefill;
          gamescope = {
            backend = "headless";
            extraArgs = gamescopeArgs;
          };
          environment.VK_ICD_FILENAMES = "/run/opengl-driver/share/vulkan/icd.d/lvp_icd.x86_64.json";
        };
      };

      environment.systemPackages = [
        pkgs.imagemagick
        pkgs.socat
        pkgs.xorg.xprop
        pkgs.xorg.xwininfo
        pkgs.wayland-utils
      ];
      system.stateVersion = "25.11";
      virtualisation = {
        memorySize = 2048;
        cores = 2;
      };
    };
in
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-gamescope-size";

  nodes = {
    wide = node [
      "-W"
      "1920"
      "-H"
      "1080"
    ];
    square = node [
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

  testScript = ''
    import json
    import re
    import shlex

    def check(m, w, h, nested=None):
        m.wait_for_unit("multi-user.target")
        m.wait_until_succeeds("pgrep -u hinteros -f '/bin/gamescope '")
        uid = m.succeed("id -u hinteros").strip()
        env = f"XDG_RUNTIME_DIR=/run/user/{uid}"
        sock = f"/run/user/{uid}/hinteros/session.sock"

        def as_user(cmd, display=":0"):
            return f"runuser -u hinteros -- env {env} DISPLAY={display} sh -c {shlex.quote(cmd)}"

        def geometry(args, display=":0"):
            out = m.succeed(as_user(f"xwininfo {args}", display))
            sizes = re.findall(r"(Width|Height): (\d+)", out)
            gw = int(next(v for k, v in sizes if k == "Width"))
            gh = int(next(v for k, v in sizes if k == "Height"))
            return gw, gh

        def wait_geometry(what, args, display=":0"):
            with m.nested(f"waiting for {what} to be {w}x{h}"):
                for _ in range(30):
                    if m.execute(as_user(f"xwininfo {args}", display))[0] == 0 and geometry(args, display) == (w, h):
                        return
                    m.sleep(2)
                raise Exception(f"{what} is {geometry(args, display)}, not {w}x{h}")

        def colour_ok(rgb, colour):
            r, g, b = rgb
            return {"blue": b > 150 and r < 80 and g < 80, "red": r > 150 and g < 80 and b < 80}[colour]

        # gamescopectl's screenshot repaints the focused app at the nested size
        # (steamcompmgr.cpp, bRenderSizeScreenshot): the output size, or -w/-h when given.
        shot_size = nested or (w, h)

        def points(sw, sh):
            # The edges (1% in), the corners and the middle of the frame.
            xs = (sw // 100, sw // 4, sw // 2, 3 * sw // 4, sw - 1 - sw // 100)
            ys = (sh // 100, sh // 4, sh // 2, 3 * sh // 4, sh - 1 - sh // 100)
            return [(x, y) for x in xs for y in ys]

        def shot():
            m.execute(f"rm -f /tmp/shot.png; runuser -u hinteros -- env {env} gamescopectl screenshot /tmp/shot.png")
            m.sleep(2)
            if m.execute("test -s /tmp/shot.png")[0] != 0:
                return None, []
            sw, sh = (int(v) for v in m.succeed("magick /tmp/shot.png -format '%w %h' info:").split())
            pts = points(sw, sh)
            fmt = " ".join(
                f"%[fx:round(255*p{{{x},{y}}}.r)],%[fx:round(255*p{{{x},{y}}}.g)],%[fx:round(255*p{{{x},{y}}}.b)]"
                for x, y in pts
            )
            px = m.succeed(f"magick /tmp/shot.png -format {shlex.quote(fmt)} info:").split()
            return (sw, sh), list(zip(pts, [tuple(int(c) for c in p.split(",")) for p in px]))

        def wait_fill(colour):
            with m.nested(f"waiting for a screenshot that is {colour} edge to edge"):
                last = None
                for _ in range(20):
                    size, px = shot()
                    last = (size, px)
                    if size == shot_size and px and all(colour_ok(p, colour) for _, p in px):
                        return
                    m.sleep(3)
                print(m.execute("magick /tmp/shot.png -scale 8x8! txt:-")[1])
                raise Exception(f"not filled with {colour}: {last}")

        # The daemon focuses the home app (base layer), the home app is sized to the output.
        m.wait_for_unit("hinteros-session.service", "hinteros")
        m.wait_until_succeeds(as_user("xprop -root GAMESCOPECTRL_BASELAYER_APPID | grep -q 4100000000"), timeout=90)
        assert geometry("-root") == (w, h), ("Xwayland :0 root", geometry("-root"))
        # Every app display (:2-:5) follows the output too (xwayland-size-all.patch).
        for n in range(2, 6):
            assert geometry("-root", f":{n}") == (w, h), (f"Xwayland :{n} root", geometry("-root", f":{n}"))
        if nested:
            assert geometry("-root", ":1") == nested, ("Xwayland :1 root", geometry("-root", ":1"))
        # The first wl_output (what the daemon's display.modes/set_mode read as the current
        # mode) reports the output, not the nested size: with one Xwayland it stayed at the
        # nested size forever, so display.set_mode never saw a switch (real-hardware bug).
        info = m.succeed(as_user("WAYLAND_DISPLAY=gamescope-0 wayland-info"))
        first = info[info.index("'wl_output'"):]
        mode = re.search(r"width: (\d+) px, height: (\d+) px", first)
        assert mode and (int(mode.group(1)), int(mode.group(2))) == (w, h), first[:600]
        wait_geometry("the home app window", "-name homefill")
        wait_fill("blue")
        m.screenshot(f"home-{w}x{h}")

        # An X11 app the daemon starts (on the apps' Xwayland, :2) gets the output size too.
        hello = {"jsonrpc": "2.0", "id": 0, "method": "hello",
                 "params": {"api_version": "0.18", "client": {"name": "gamescope-size-test", "version": "0"}}}
        launch = {"jsonrpc": "2.0", "id": 1, "method": "apps.launch", "params": {"id": "appfill"}}
        payload = "".join(json.dumps(x) + "\n" for x in (hello, launch))
        out = m.succeed(as_user(f"(printf %s {shlex.quote(payload)}; sleep 3) | socat -t3 - UNIX-CONNECT:{sock}"))
        reply = next(r for r in map(json.loads, filter(str.strip, out.splitlines())) if r.get("id") == 1)
        assert "error" not in reply, reply
        wait_geometry("the app window", "-name appfill", ":2")
        wait_fill("red")
        m.screenshot(f"app-{w}x{h}")

        # Apps on Xwayland; gamescope's own output in the journal.
        for pat in ("/bin/gamescope ", "hinteros-session --config"):
            pid = m.succeed(f"pgrep -u hinteros -f '{pat}' | head -n1").strip()
            assert "GDK_BACKEND=x11" in m.succeed(f"tr '\\0' '\\n' < /proc/{pid}/environ"), pat
        m.wait_until_succeeds("journalctl -t hinteros-compositor | grep -q gamescope")

    start_all()
    check(wide, 1920, 1080)
    check(square, 1280, 1024, nested=(640, 512))
  '';
}
