# The real native apps in the app sandbox under cage: Jellyfin
# (Qt/mpv, Qt WebEngine), Plex HTPC (Qt WebEngine in its own FHS bwrap, unfree), VacuumTube
# (Electron), Moonlight (Qt) and the Firefox kiosk (YouTube, on a local https page) and plain
# Firefox entries. Each one starts with apps.launch, must map a window on the apps display, still
# run after some seconds and log no sandbox-caused errors (missing files, EACCES, user
# namespaces, Mesa, fonts, locale, sound; the hidden D-Bus buses are expected); its log is
# printed. Chromium's and Firefox's own sandboxes must work inside ours (more user namespaces
# than our sandbox alone makes). Its data must land in its sandbox home, never the real home. The
# VM has no internet: Plex cannot fetch Widevine, it must not crash. A probe app checks from
# inside what the apps rely on: TLS with the system CA (a local https server), fonts, the locale,
# sound, the GPU paths. Software rendering (llvmpipe). Real streaming, DRM, hardware video
# decoding and controllers are box checks.
{ self, pkgs }:
let
  host = "media.hinteros.test";

  # A test CA and a server certificate for `host`, made at build time.
  tls = pkgs.runCommand "sandbox-apps-tls" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out
    cd $out
    openssl req -x509 -newkey rsa:2048 -nodes -days 36500 -subj /CN=hinteros-test-ca \
      -keyout ca.key -out ca.crt
    openssl req -newkey rsa:2048 -nodes -subj /CN=${host} -keyout server.key -out server.csr
    printf 'subjectAltName=DNS:${host}\n' > ext
    openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 36500 \
      -extfile ext -out server.crt
  '';

  # Inside the sandbox: one `<check>=yes|no` line per check to $HOME/probe.txt.
  probe = pkgs.writeShellApplication {
    name = "hinteros-apps-probe";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.fontconfig
      pkgs.glibc
      pkgs.pulseaudio
      pkgs.gnugrep
    ];
    text = ''
      check() {
        local name="$1"
        shift
        echo "== $name" >&2
        if "$@" >/dev/null; then echo "$name=yes"; else echo "$name=no"; fi
      }
      play() {
        head -c 19200 /dev/zero | pacat --playback --raw
      }
      fonts_ok() {
        test -n "$(fc-list)"
      }
      locale_ok() {
        test -z "$(locale 2>&1 >/dev/null)"
      }
      render_nodes() {
        local f out=""
        for f in /dev/dri/renderD*; do
          if [ -e "$f" ]; then out="$out''${f##*/},"; fi
        done
        echo "$out"
      }
      {
        check tls curl -fsS https://${host}/
        check fonts fonts_ok
        check locale locale_ok
        check play play
        # The GPU: render nodes only (the VM may have none), never the display (card) nodes.
        check dri_card sh -c 'ls /dev/dri/card*'
        echo "dri_render=$(render_nodes)"
        check opengl test -e /run/opengl-driver/lib
      } > "$HOME/probe.tmp" 2> "$HOME/probe.err"
      mv "$HOME/probe.tmp" "$HOME/probe.txt"
      exec sleep infinity
    '';
  };
in
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-sandbox-apps";
  meta.timeout = 3600;
  # Plex HTPC is unfree: the catalog allows it by name (unfree.nix sets nixpkgs.config).
  node.pkgsReadOnly = false;

  nodes.machine =
    { lib, pkgs, ... }:
    {
      imports = [
        self.nixosModules.session
        self.nixosModules.daemon
        self.nixosModules.apps
        ../../nixos/vm
      ];

      # Own pkgs (not the read-only test pkgs), so the overlay comes in here.
      nixpkgs.overlays = [ self.overlays.default ];

      hinteros.apps = {
        youtube.kiosk.url = "https://${host}/youtube.html";
        firefox.kiosk.url = "https://${host}/firefox.html";
        plex-htpc.enable = true;
        vacuum-tube.enable = true;
        moonlight.enable = true;
        probe = {
          enable = true;
          name = "Probe";
          package = probe;
          # The https server is on this box (127.0.0.1): local network.
          permissions.lan = "required";
        };
      };

      # A local https server with a certificate from the test CA, which the system trusts.
      security.pki.certificateFiles = [ "${tls}/ca.crt" ];
      networking.hosts."127.0.0.1" = [ host ];
      services.nginx = {
        enable = true;
        virtualHosts.${host} = {
          onlySSL = true;
          sslCertificate = "${tls}/server.crt";
          sslCertificateKey = "${tls}/server.key";
          root = pkgs.writeTextDir "youtube.html" ''
            <!doctype html><meta charset=utf-8><title>TLS PAGE</title><p>TLS PAGE</p>
          '';
          locations."= /firefox.html".alias = pkgs.writeText "firefox.html" ''
            <!doctype html><meta charset=utf-8><title>TLS PAGE</title><p>TLS PAGE</p>
          '';
          locations."= /".return = "200 ok";
        };
      };

      # pulse/native and pulse/play in the profile's runtime dir, and a sink to play to.
      services.pipewire = {
        enable = true;
        pulse.enable = true;
        wireplumber.enable = true;
        extraConfig.pipewire."10-null"."context.objects" = [
          {
            factory = "adapter";
            args = {
              "factory.name" = "support.null-audio-sink";
              "node.name" = "null-sink";
              "media.class" = "Audio/Sink";
              "audio.position" = "FL,FR";
            };
          }
        ];
      };

      environment.systemPackages = [
        pkgs.socat
        pkgs.xdotool
        pkgs.xprop
        pkgs.xwininfo
      ];
      virtualisation.memorySize = lib.mkForce 6144;
      virtualisation.cores = lib.mkForce 4;
    };

  testScript = ''
    import json
    import re
    import shlex
    import time

    machine.wait_for_unit("multi-user.target")
    machine.wait_until_succeeds("pgrep -u hinteros-p1 -f '/bin/cage '")
    machine.wait_for_unit("hinteros-session.service", "hinteros-p1")
    machine.wait_for_unit("nginx.service")
    uid = machine.succeed("id -u hinteros-p1").strip()
    sock = f"/run/user/{uid}/hinteros/session.sock"
    machine.wait_until_succeeds(f"test -S {sock}")
    machine.wait_until_succeeds(f"test -S /run/user/{uid}/pulse/play")
    home = "/home/hinteros-p1"
    sandboxes = f"{home}/.local/share/hinteros/sandbox"

    def rpc(*msgs, wait=2):
        hello = {"jsonrpc": "2.0", "id": 0, "method": "hello",
                 "params": {"api_version": "1.0", "client": {"name": "sandbox-apps-test", "version": "0"}}}
        payload = "".join(json.dumps(m) + "\n" for m in (hello, *msgs))
        cmd = f"(printf %s {shlex.quote(payload)}; sleep {wait}) | socat -t{wait} - UNIX-CONNECT:{sock}"
        out = machine.succeed(f"runuser -u hinteros-p1 -- sh -c {shlex.quote(cmd)}")
        replies = [json.loads(line) for line in out.splitlines() if line.strip()]
        assert "error" not in replies[0], replies[0]
        return replies

    def ok(method, params=None):
        reply = next(r for r in rpc({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}) if r.get("id") == 1)
        assert "error" not in reply, reply
        return reply["result"]

    # What the system trusts and serves works outside the sandbox.
    machine.succeed("curl -fsS https://${host}/")

    def userns_of(process):
        """User namespaces of the matching processes, but the host's (the reaper, bwrap's own)."""
        return len(machine.succeed(
            f"for p in $(pgrep -u hinteros-p1 -f {shlex.quote(process)}); do readlink /proc/$p/ns/user; done"
            " | sort -u | grep -vxF \"$(readlink /proc/1/ns/user)\" || true"
        ).split())

    # The probe: TLS with the system CA, fonts, the locale, sound, the GPU paths.
    ok("apps.launch", {"id": "probe"})
    machine.wait_until_succeeds(f"test -s {sandboxes}/probe/probe.txt", timeout=60)
    res = dict(line.split("=", 1) for line in machine.succeed(f"cat {sandboxes}/probe/probe.txt").split())
    print("probe", res)
    print(machine.succeed(f"cat {sandboxes}/probe/probe.err"))
    # What our sandbox alone makes: an app with more has its own sandbox working inside.
    base_userns = userns_of("[h]interos-apps-probe|^sleep infinity$")
    print("user namespaces of the sandbox", base_userns)
    assert base_userns >= 1, base_userns
    probe_failed = [k for k in ("tls", "fonts", "locale", "play", "opengl") if res[k] != "yes"]
    if res["dri_card"] != "no":
        probe_failed.append("dri_card")
    host_render = machine.succeed("ls /dev/dri | grep renderD | tr '\\n' , || true").strip()
    print("render nodes on the host:", repr(host_render), machine.succeed("ls -l /dev/dri || true"))
    if res["dri_render"] != host_render:
        probe_failed.append("dri_render")
    ok("apps.close", {"id": "probe"})
    machine.wait_until_fails("pgrep -u hinteros-p1 -f [h]interos-apps-probe", timeout=30)

    # The display the sandboxed apps get (cage: its Xwayland), seen as the profile user.
    def windows():
        """Visible X windows with a name: {id: name}."""
        script = ('for w in $(xdotool search --onlyvisible --name --class --classname .); do '
                  'echo "$w $(xdotool getwindowname "$w") / $(xprop -id "$w" WM_CLASS | cut -d= -f2)"; done')
        out = machine.succeed(f"runuser -u hinteros-p1 -- env DISPLAY=:0 sh -c {shlex.quote(script)}")
        return dict((line.split(" ", 1) + [""])[:2] for line in out.splitlines() if line.strip())

    print("windows before the apps", windows())

    # Sandbox-caused errors in an app's log.
    BAD = re.compile("|".join([
        r"Permission denied", r"EACCES", r"Operation not permitted", r"EPERM",
        r"No such file or directory", r"cannot open shared object",
        r"[Ff]ailed to connect to (the )?(session |system )?bus", r"org\.freedesktop\.portal",
        r"[Nn]o usable sandbox", r"[Nn]amespace", r"setuid sandbox", r"credentials\.cc",
        r"MESA-LOADER", r"failed to load driver", r"libEGL warning", r"glx: failed",
        r"Fontconfig (error|warning)", r"[Cc]annot load default config file",
        r"[Cc]ertificate", r"SSL", r"locale", r"LC_ALL",
        r"pa_context_connect\(\) failed", r"[Cc]onnection refused", r"PulseAudio",
        r"Can't mount", r"bwrap:", r"Read-only file system",
    ]))

    # Not caused by the sandbox, or by design:
    EXPECTED = re.compile("|".join([
        # The D-Bus buses are hidden by design; Chromium (Electron, Qt
        # WebEngine) logs it and goes on without them.
        r"dbus/bus\.cc.*Failed to connect to the bus", r"dbus/object_proxy\.cc.*NameHasOwner",
        # GTK (Firefox): the accessibility bus, through the session bus.
        r"Failed to create DBus proxy for org\.a11y\.Bus",
        # Without state.json (this VM) the token request is an error; a box always has one.
        r"Jellyfin app: no sign-in token: reading /etc/hinteros/state\.json",
        # Plex's bundled (older) fontconfig reads the system's /etc/fonts, also without our
        # sandbox (its own FHS bwrap binds the host's /etc/fonts).
        r"Fontconfig warning: \"/etc/fonts/conf\.d/",
        # The VM has no VDPAU driver (Moonlight probes hardware decoders; on a box the drivers
        # are in /run/opengl-driver, which is bound).
        r"Failed to open VDPAU backend",
    ]))

    # Real home dirs an app could write to by mistake (outside the sandbox).
    leak_dirs = [".config", ".cache", ".local/share", ".pki", ".mozilla", ".electron", ".nv"]

    def real_home():
        return set(machine.succeed(
            f"cd {home} && for d in {' '.join(leak_dirs)}; do test -e $d && find $d -maxdepth 1; done; true"
        ).split())

    results = {}

    def try_app(app, process, data, settle=20, window_timeout=240, nested=False):
        """Launch `app`, wait for its window, check it still runs after `settle` s, collect its log."""
        before_home = real_home()
        before = windows()
        cursor = machine.succeed("journalctl -n0 --show-cursor | tail -n1").strip().removeprefix("-- cursor: ")
        ok("apps.launch", {"id": app})
        start = time.time()
        new = {}
        while time.time() - start < window_timeout:
            new = {w: n for w, n in windows().items() if w not in before}
            if new:
                break
            time.sleep(5)
        mapped = bool(new)
        if not mapped:
            # All top-level windows, also unmapped ones, to see what the app made.
            print(machine.succeed("runuser -u hinteros-p1 -- env DISPLAY=:0 xwininfo -root -children -int || true"))
        if mapped:
            time.sleep(settle)
        running = machine.execute(f"pgrep -u hinteros-p1 -f {shlex.quote(process)}")[0] == 0
        userns = userns_of(process)
        machine.screenshot(f"app-{app}")
        log = machine.succeed(
            f"journalctl --after-cursor={shlex.quote(cursor)} _SYSTEMD_USER_UNIT=hinteros-session.service -o cat || true"
        )
        print(f"===== {app} log =====\n{log}\n===== end {app} =====")
        bad = sorted({line for line in log.splitlines() if BAD.search(line) and not EXPECTED.search(line)})
        ok("apps.close", {"id": app})
        machine.wait_until_fails(f"pgrep -u hinteros-p1 -f {shlex.quote(process)}", timeout=60)
        after_home = real_home()
        tree = machine.succeed(f"cd {sandboxes}/{app} && find . -maxdepth 3 | sort")
        print(f"===== {app} sandbox home =====\n{tree}")
        found = [d for d in data if machine.execute(f"test -e {shlex.quote(sandboxes + '/' + app + '/' + d)}")[0] == 0]
        results[app] = {
            "windows": sorted(new.values()),
            "mapped": mapped,
            "running": running,
            "userns": userns,
            "bad": bad,
            "data": found,
            "leaked": sorted(after_home - before_home),
        }
        print(app, json.dumps(results[app], indent=1))
        if nested:
            results[app]["nested_ok"] = userns > base_userns

    try_app("jellyfin-desktop", "[j]ellyfin-desktop", [".local/share/jellyfin-desktop", ".config/jellyfin-desktop"])
    try_app("moonlight", "[m]oonlight", [".config/Moonlight Game Streaming Project"])
    try_app("vacuum-tube", "[V]acuumTube|[v]acuum-tube|[e]lectron", [".config/VacuumTube"], nested=True)
    try_app("plex-htpc", "[P]lex|[p]lex-htpc", [".local/share/plex-htpc", ".local/share/Plex HTPC", ".config/Plex HTPC", ".cache/plex"], settle=40)
    try_app("youtube", "[f]irefox", [".local/share/hinteros/firefox/youtube"], nested=True)
    try_app("firefox", "[f]irefox", [".local/share/hinteros/firefox/firefox"], nested=True)

    # Baseline: Plex's fontconfig warnings also come without our sandbox.
    base = machine.succeed(
        "runuser -u hinteros-p1 -- env DISPLAY=:0 HOME=/tmp/plex-base sh -c "
        "'mkdir -p $HOME; timeout -s KILL 30 plex-htpc > /tmp/plex-base.log 2>&1; true'; "
        "grep -c 'Fontconfig warning' /tmp/plex-base.log || true"
    ).strip()
    print("plex without the sandbox: fontconfig warnings:", base)
    machine.succeed("pkill -u hinteros-p1 -f '[p]lex' || true")

    print(json.dumps(results, indent=1))
    failed = {a: r for a, r in results.items()
              if not r["mapped"] or not r["running"] or r["bad"] or not r["data"] or r["leaked"]
              or r.get("nested_ok") is False}
    assert not probe_failed, (probe_failed, res)
    assert not failed, json.dumps(failed, indent=1)
  '';
}
