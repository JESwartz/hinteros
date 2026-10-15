# The display split under gamescope (design/sandbox.md, step 3), headless as in
# tests/vm/gamescope.nix: gamescope runs three Xwaylands (#0 the home app and the OSK, #1 Steam's
# game display, #2 the apps). A sandboxed app started with apps.launch must land on #2, at the
# output size (1280x1024; the nested size is 640x512, which #2 kept without the patch), get focus
# (apps.launch / Home / apps.focus) and keyboard input, and from inside its sandbox reach
# neither #0 nor #1: not through socket files (only #2's is bound) and not through the abstract
# sockets @/tmp/.X11-unix/X<n> (gamescope is patched not to open them; the sandbox shares the
# network namespace). XTEST from #2 must not type into the home app. A fake Steam game must not
# land on #2. Prints the Xwaylands' RSS.
{ self, pkgs }:
let
  # Logs every line typed into it (the home app: it must never get the app's XTEST keys).
  homeLog = pkgs.writeShellApplication {
    name = "homelog";
    runtimeInputs = [ pkgs.xterm ];
    text = ''
      exec xterm -T homelog -geometry 20x4 -fa Monospace -fs 10 \
        -e sh -c 'exec cat >> /home/hinteros/home-typed'
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
        for n in 0 1 2; do
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
          session.settings.apps = [
            {
              id = "probe";
              name = "Probe";
              command = [ (pkgs.lib.getExe probe) ];
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
    machine.wait_until_succeeds("pgrep -u hinteros -f '/bin/gamescope '")
    machine.wait_for_unit("hinteros-session.service", "hinteros")
    uid = machine.succeed("id -u hinteros").strip()
    env = f"XDG_RUNTIME_DIR=/run/user/{uid}"
    sock = f"/run/user/{uid}/hinteros/session.sock"
    home = "/home/hinteros"
    box = f"{home}/.local/share/hinteros/sandbox/probe"

    def as_user(cmd, display=":0"):
        return f"runuser -u hinteros -- env {env} DISPLAY={display} sh -c {shlex.quote(cmd)}"

    def root_prop(name):
        return machine.execute(as_user(f"xprop -root {name}"))[1].strip()

    def geometry(args, display):
        out = machine.succeed(as_user(f"xwininfo {args}", display))
        sizes = dict(re.findall(r"(Width|Height): (\d+)", out))
        return int(sizes["Width"]), int(sizes["Height"])

    def rpc(*msgs, wait=2):
        hello = {"jsonrpc": "2.0", "id": 0, "method": "hello",
                 "params": {"api_version": "0.18", "client": {"name": "gamescope-sandbox-test", "version": "0"}}}
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

    # Three Xwaylands, :0 :1 :2 (nothing else runs X here); none on an abstract socket.
    machine.wait_until_succeeds(as_user("xprop -root GAMESCOPECTRL_BASELAYER_APPID | grep -q 4100000000"), timeout=90)
    for n in (0, 1, 2):
        machine.succeed(f"test -S /tmp/.X11-unix/X{n}")
    print(machine.succeed("ss -xlp | grep X11-unix"))
    machine.fail("ss -xlp | grep -q '@/tmp/.X11-unix'")
    assert geometry("-root", ":0") == (1280, 1024), geometry("-root", ":0")
    assert geometry("-root", ":1") == (640, 512), geometry("-root", ":1")
    assert geometry("-root", ":2") == (1280, 1024), ("apps' Xwayland follows the output", geometry("-root", ":2"))
    machine.wait_until_succeeds(as_user("xwininfo -name homelog", ":0"))

    # The sandboxed app lands on :2 at the output size, with focus.
    launched = ok("apps.launch", {"id": "probe"})["app"]
    app_id = launched["gamescope_app_id"]
    machine.wait_until_succeeds(f"test -s {box}/probe.txt", timeout=60)
    res = dict(line.split("=", 1) for line in machine.succeed(f"cat {box}/probe.txt").split())
    print("probe", res)
    assert res["display"] == ":2", res
    assert res["x11_own"] == "yes" and res["x11_2"] == "yes", res
    for n in (0, 1):
        assert res[f"x11_{n}"] == "no" and res[f"file_{n}"] == "no", (n, res)
    for n in (0, 1, 2):
        assert res[f"abstract_{n}"] == "no", (n, res)
    machine.wait_until_succeeds(as_user("xwininfo -name probe", ":2"), timeout=30)
    machine.fail(as_user("xwininfo -name probe", ":0"))
    machine.wait_until_succeeds(as_user("xwininfo -name probe | grep -q 'Width: 1280'", ":2"), timeout=30)
    assert geometry("-name probe", ":2") == (1280, 1024), geometry("-name probe", ":2")
    wait_focused(app_id)

    # Home: the launcher again; apps.focus: the app again.
    machine.succeed("pkill -USR1 -u hinteros -f 'hinteros-session --config'")
    wait_focused(4100000000)
    ok("apps.focus", {"id": "probe"})
    wait_focused(app_id)

    # Keyboard input reaches the app on :2 (XTEST of a trusted client on :0, through gamescope's
    # input emulation to the focused window; headless gamescope reads no input devices).
    machine.succeed(as_user("xdotool type --delay 50 hello && xdotool key Return", ":0"))
    machine.wait_until_succeeds(f"grep -qx hello {box}/typed", timeout=30)
    machine.fail(f"grep -q hello {home}/home-typed")

    # XTEST from the app's own display while the home app has focus: never reaches the home app.
    machine.succeed("pkill -USR1 -u hinteros -f 'hinteros-session --config'")
    wait_focused(4100000000)
    machine.succeed(f"runuser -u hinteros -- touch {box}/inject")
    machine.wait_until_succeeds(f"test -e {box}/injected", timeout=30)
    machine.sleep(3)
    typed_home = machine.execute(f"cat {home}/home-typed")[1]
    print("home app got:", repr(typed_home))
    assert "injected" not in typed_home, typed_home

    # A fake Steam game does not land on the apps' display.
    ok("apps.launch", {"url": "steam://rungameid/1000002"})
    machine.wait_until_succeeds(
        as_user("xwininfo -name 'Fake game 1000002'", ":0") + " || " + as_user("xwininfo -name 'Fake game 1000002'", ":1"),
        timeout=60,
    )
    machine.fail(as_user("xwininfo -name 'Fake game 1000002'", ":2"))
    for n in (0, 1):
        if machine.execute(as_user("xwininfo -name 'Fake game 1000002'", f":{n}"))[0] == 0:
            print(f"fake Steam game on :{n}")
    wait_focused(1000002)

    # The Xwaylands' memory.
    print(machine.succeed("ps -o pid,rss,args -C Xwayland"))
    print(machine.succeed("for p in $(pgrep -x Xwayland); do echo '== pid' $p; grep -E '^(Rss|Pss|Private_Dirty|Private_Clean):' /proc/$p/smaps_rollup; done"))
  '';
}
