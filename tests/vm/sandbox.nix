# The app sandbox under cage (design/sandbox.md): apps.launch starts an app in the session
# daemon's bwrap sandbox. A probe app records from inside what it can reach: none of the
# HinterOS sockets, the D-Bus buses, uinput, the compositor's Wayland socket or the real home;
# the X display, pulse/native and a writable home of its own work. ~/Downloads is there only with
# the `downloads` grant, /dev/input only with `gamepad`. An apps.set_permission opt-out applies on
# the next launch, and a required permission cannot be denied. Sound: every app can play; only
# an app with `mic` can record (the others get the play-only socket, pulse/play).
{ self, pkgs }:
let
  # Writes one `<check>=yes|no` line per check to $HOME/probe.txt, then waits to be closed.
  probe = pkgs.writeShellApplication {
    name = "hinteros-sandbox-probe";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.pulseaudio
      pkgs.xdpyinfo
    ];
    text = ''
      check() {
        local name="$1"
        shift
        if "$@" >/dev/null 2>&1; then echo "$name=yes"; else echo "$name=no"; fi
      }
      other_in_run_hinteros() {
        local f
        for f in /run/hinteros/* /run/hinteros/.*; do
          case "$f" in */apps | */. | */.. | "/run/hinteros/*" | "/run/hinteros/.*") ;; *) return 0 ;; esac
        done
        return 1
      }
      play() {
        head -c 19200 /dev/zero | pacat --playback --raw
      }
      record() {
        rm -f "$HOME/rec.raw"
        timeout 3 parecord --raw "$HOME/rec.raw" || true
        test -s "$HOME/rec.raw"
      }
      rt="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
      {
        check session_sock test -e "$rt/hinteros/session.sock"
        check system_sock test -e /run/hinteros/system.sock
        # Only the profile's app env (when it has one) is there from /run/hinteros.
        check run_hinteros other_in_run_hinteros
        check uinput test -e /dev/uinput
        check real_home test -e "$HOME/real-home-marker"
        check other_app test -e /home/hinteros/.local/share/hinteros/sandbox/plain
        check bus test -e "$rt/bus"
        check system_bus test -e /run/dbus/system_bus_socket
        check wayland test -e "$rt/wayland-0"
        check gamescope test -e "$rt/gamescope-0"
        check pipewire test -e "$rt/pipewire-0"
        check wayland_env test -n "''${WAYLAND_DISPLAY:-}"
        check dbus_env test -n "''${DBUS_SESSION_BUS_ADDRESS:-}"
        check x11 xdpyinfo
        check pulse test -S "$rt/pulse/native"
        check home_writable touch "$HOME/written"
        check play play
        check record record
        check downloads test -e "$HOME/Downloads/marker"
        check input test -d /dev/input
        check udev test -e /run/udev
      } > "$HOME/probe.tmp"
      mv "$HOME/probe.tmp" "$HOME/probe.txt"
      exec sleep infinity
    '';
  };
in
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-sandbox";

  nodes.machine = _: {
    imports = [
      self.nixosModules.session
      self.nixosModules.daemon
      self.nixosModules.apps
      ../../nixos/vm
    ];

    hinteros.apps = {
      jellyfin.enable = false;
      youtube.enable = false;
      firefox.enable = false;
      probe = {
        enable = true;
        name = "Probe";
        package = probe;
        permissions = {
          gamepad = "required";
          downloads = "optional";
          mic = "optional";
        };
      };
      plain = {
        enable = true;
        name = "Plain";
        package = probe;
      };
    };

    # pulse/native and pulse/play in the profile's runtime dir; a sink and a source to use.
    services.pipewire = {
      enable = true;
      pulse.enable = true;
      wireplumber.enable = true;
      extraConfig.pipewire."10-null" = {
        "context.objects" =
          map
            (class: {
              factory = "adapter";
              args = {
                "factory.name" = "support.null-audio-sink";
                "node.name" = "null-${class}";
                "media.class" = "Audio/${class}";
                "audio.position" = "FL,FR";
              };
            })
            [
              "Sink"
              "Source/Virtual"
            ];
      };
    };

    environment.systemPackages = [
      pkgs.socat
      pkgs.pulseaudio
    ];
  };

  testScript = ''
    import json
    import shlex

    machine.wait_for_unit("multi-user.target")
    machine.wait_until_succeeds("pgrep -u hinteros -f '/bin/cage '")
    machine.wait_for_unit("hinteros-session.service", "hinteros")
    uid = machine.succeed("id -u hinteros").strip()
    sock = f"/run/user/{uid}/hinteros/session.sock"
    machine.wait_until_succeeds(f"test -S {sock}")
    machine.wait_until_succeeds(f"test -S /run/user/{uid}/pulse/native")
    machine.wait_until_succeeds(f"test -S /run/user/{uid}/pulse/play")
    home = "/home/hinteros"
    sandboxes = f"{home}/.local/share/hinteros/sandbox"

    # What the probe must not find in its own home, and what only grants give it.
    machine.succeed(f"runuser -u hinteros -- touch {home}/real-home-marker")
    machine.succeed(f"runuser -u hinteros -- mkdir -p {home}/Downloads")
    machine.succeed(f"runuser -u hinteros -- touch {home}/Downloads/marker")

    def rpc(*msgs, wait=2):
        hello = {"jsonrpc": "2.0", "id": 0, "method": "hello",
                 "params": {"api_version": "0.18", "client": {"name": "sandbox-test", "version": "0"}}}
        payload = "".join(json.dumps(m) + "\n" for m in (hello, *msgs))
        cmd = f"(printf %s {shlex.quote(payload)}; sleep {wait}) | socat -t{wait} - UNIX-CONNECT:{sock}"
        out = machine.succeed(f"runuser -u hinteros -- sh -c {shlex.quote(cmd)}")
        replies = [json.loads(line) for line in out.splitlines() if line.strip()]
        assert "error" not in replies[0], replies[0]
        return replies

    def call(method, params=None):
        return next(r for r in rpc({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}) if r.get("id") == 1)

    def ok(method, params=None):
        reply = call(method, params)
        assert "error" not in reply, reply
        return reply["result"]

    def run(app):
        """Launch `app`, return its probe results, close it."""
        out = f"{sandboxes}/{app}/probe.txt"
        machine.succeed(f"rm -f {out}")
        ok("apps.launch", {"id": app})
        machine.wait_until_succeeds(f"test -s {out}", timeout=60)
        res = dict(line.split("=", 1) for line in machine.succeed(f"cat {out}").split())
        print(app, res)
        ok("apps.close", {"id": app})
        machine.wait_until_fails("pgrep -u hinteros -f [h]interos-sandbox-probe", timeout=30)
        return res

    hidden = ["session_sock", "system_sock", "run_hinteros", "uinput", "real_home", "other_app",
              "bus", "system_bus", "wayland", "gamescope", "pipewire", "wayland_env", "dbus_env"]
    works = ["x11", "pulse", "home_writable", "play"]

    def expect(res, **want):
        for k in hidden:
            assert res[k] == "no", (k, res)
        for k in works:
            assert res[k] == "yes", (k, res)
        for k, v in want.items():
            assert res[k] == ("yes" if v else "no"), (k, res)

    # The plain app first: no permissions, so no Downloads, no /dev/input and no recording.
    expect(run("plain"), downloads=False, input=False, udev=False, record=False)
    # The app runs under bwrap, with its own home.
    machine.succeed(f"test -f {sandboxes}/plain/written")
    machine.succeed(f"test ! -e {home}/written")

    # Probe: gamepad (required), downloads and mic (optional, granted by default).
    expect(run("probe"), downloads=True, input=True, udev=True, record=True)

    by_id = {a["id"]: a for a in ok("apps.list")["apps"]}
    perms = {p["name"]: p for p in by_id["probe"]["permissions"]}
    assert perms["gamepad"]["required"] and perms["gamepad"]["granted"], perms
    assert not perms["downloads"]["required"] and perms["downloads"]["granted"], perms
    assert by_id["plain"]["permissions"] == [], by_id["plain"]

    # A required permission cannot be denied; an unknown one is refused.
    err = call("apps.set_permission", {"id": "probe", "permission": "gamepad", "granted": False})
    assert err["error"]["code"] == 2008, err  # permission_required
    err = call("apps.set_permission", {"id": "probe", "permission": "camera", "granted": False})
    assert err["error"]["code"] == 2007, err  # unknown_permission

    # Opt out of downloads and mic: stored per profile, applies on the next launch.
    ok("apps.set_permission", {"id": "probe", "permission": "downloads", "granted": False})
    ok("apps.set_permission", {"id": "probe", "permission": "mic", "granted": False})
    state = json.loads(machine.succeed(f"cat {home}/.local/state/hinteros/permissions.json"))
    assert sorted(state["denied"]["probe"]) == ["downloads", "mic"], state
    expect(run("probe"), downloads=False, input=True, udev=True, record=False)

    # Granted again: back on the next launch.
    ok("apps.set_permission", {"id": "probe", "permission": "downloads", "granted": True})
    ok("apps.set_permission", {"id": "probe", "permission": "mic", "granted": True})
    expect(run("probe"), downloads=True, input=True, udev=True, record=True)

    # Outside the sandbox the play-only socket refuses recording and module loading too.
    play = f"runuser -u hinteros -- env XDG_RUNTIME_DIR=/run/user/{uid} PULSE_SERVER=unix:/run/user/{uid}/pulse/play"
    machine.succeed(f"head -c 19200 /dev/zero | {play} pacat --playback --raw")
    machine.succeed(
        f"rm -f /tmp/rec.raw; {play} PULSE_PROP='pulse.server.type=x pipewire.client.access=unrestricted' "
        "timeout 3 parecord --raw /tmp/rec.raw || true; test ! -s /tmp/rec.raw"
    )
    machine.fail(f"{play} pactl load-module module-native-protocol-unix socket=/tmp/pulse-x")
  '';
}
