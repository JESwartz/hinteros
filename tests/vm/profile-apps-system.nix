# The system side of per-profile apps and accounts (apps.md build plan steps 3, 6, 9; profiles.md),
# without the M7 daemon: hinteros-system's part (setting a profile's Nix profile, publishing
# /run/hinteros/apps/<user>) is done by hand here, the way its jobs do it (DECISIONS D4). Checks:
#   - accounts: p1 = hinteros-p1, p2 = hinteros-p2 (uid 20002), the guest (uid 20000), all in
#     `hinteros`, homes 0700, no static device groups needed for the checks below;
#   - /nix/var/nix/profiles/hinteros{,/apps} root 0755; a profile user cannot repoint its link;
#   - an env built by `config.hinteros.appEnv.build` works as a profile: its manifest, its kiosk
#     wrapper;
#   - an app package is not trusted outside the sandbox: one that ships a Vulkan layer, a font and
#     a `bin/ls` (Moonlight's entry with a test package) adds none of them to the env, and neither
#     the env nor the package is on PATH, XDG_DATA_DIRS or any other search path of the
#     compositor, Xwayland, the home app or the session daemon (/proc/<pid>/environ); the app
#     still starts (apps.launch, in its sandbox) and its icon resolves from its desktop file;
#   - the box-wide Firefox policies with no Firefox package in the system;
#   - the automatic clean-up from state.json `settings.cleanup` (daily, keepSystem 2,
#     keepProfiles 3): the timer's service trims an app profile to its 3 newest generations and
#     the system profile to its 2 newest, keeping the booted system's older generation;
#   - the guest's home is emptied at boot, the app profiles survive a reboot.
{ self, pkgs }:
let
  # What an app package must never put into an unsandboxed process: an implicit Vulkan layer, a
  # font, a `bin/` name of a common command. Plus a desktop file and an icon, which the daemon
  # reads by path. The app writes a marker in its (sandbox) home, then waits.
  trustApp =
    pkgs.runCommand "hinteros-trust-app"
      {
        meta.mainProgram = "hinteros-trust-app";
      }
      ''
        mkdir -p $out/bin $out/share/applications $out/share/icons/hicolor/256x256/apps \
          $out/share/vulkan/implicit_layer.d $out/share/fonts/truetype
        cat > $out/bin/hinteros-trust-app <<EOF
        #!${pkgs.runtimeShell}
        echo started > "\$HOME/trust-started"
        exec ${pkgs.coreutils}/bin/sleep infinity
        EOF
        cat > $out/bin/ls <<EOF
        #!${pkgs.runtimeShell}
        echo shadowed > /tmp/trust-shadowed
        EOF
        chmod +x $out/bin/*
        printf '[Desktop Entry]\nType=Application\nName=Trust\nExec=hinteros-trust-app\nIcon=hinteros-trust\n' \
          > $out/share/applications/hinteros-trust.desktop
        cp ${pkgs.nixos-icons}/share/icons/hicolor/256x256/apps/nix-snowflake.png \
          $out/share/icons/hicolor/256x256/apps/hinteros-trust.png
        echo '{"file_format_version":"1.0.0","layer":{"name":"VK_LAYER_HINTEROS_trust","type":"GLOBAL","library_path":"/tmp/trust.so","api_version":"1.3.0","implementation_version":"1","description":"test","disable_environment":{"TRUST_OFF":"1"}}}' \
          > $out/share/vulkan/implicit_layer.d/trust.json
        echo font > $out/share/fonts/truetype/trust.ttf
      '';
in
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-profile-apps-system";
  meta.timeout = 1800;

  nodes.machine =
    { config, lib, ... }:
    let
      envs = {
        empty = config.hinteros.appEnv.build [ ];
        firefox = config.hinteros.appEnv.build [ "firefox" ];
        both = config.hinteros.appEnv.build [
          "youtube"
          "firefox"
        ];
        trust = config.hinteros.appEnv.build [ "moonlight" ];
      };
    in
    {
      imports = [
        ../../nixos/modules
        self.nixosModules.catalog
        ../../nixos/vm
      ];
      hinteros = {
        state = {
          schemaVersion = 2;
          base = "unstable";
          stateVersion = "25.11";
          profiles = [
            { id = "p1"; }
            { id = "p2"; }
          ];
          requirements = [ ];
          services = [ ];
          settings = {
            guest.enable = true;
            cleanup = {
              frequency = "daily";
              keepSystem = 2;
              keepProfiles = 3;
            };
          };
        };
        # Moonlight's entry with the test package (only the `trust` env has it).
        appEnv.overrides.moonlight = {
          package = trustApp;
          desktopId = "hinteros-trust";
        };
        # Apps, not the picker: autologin of p1 (greeter mode: profiles-greeter).
        profiles.greeter.enable = false;
      };
      system.extraDependencies = lib.attrValues envs;
      environment.etc."hinteros-test/envs.json".text = builtins.toJSON (
        lib.mapAttrs (_: e: e.outPath) envs
      );
      environment.systemPackages = [ pkgs.socat ];
      virtualisation.memorySize = lib.mkForce 2048;
    };

  testScript = ''
    import json
    import shlex

    envs = json.loads(machine.succeed("cat /etc/hinteros-test/envs.json"))
    P = "/nix/var/nix/profiles/hinteros/apps/hinteros-p1"
    LINK = "/run/hinteros/apps/hinteros-p1"

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("greetd.service")
    machine.wait_until_succeeds("pgrep -u hinteros-p1 -f '/bin/cage '")

    with subtest("accounts"):
        assert machine.succeed("id -u hinteros-p2").strip() == "20002"
        assert machine.succeed("id -u hinteros-guest").strip() == "20000"
        for u in ["hinteros-p1", "hinteros-p2", "hinteros-guest"]:
            assert "hinteros" in machine.succeed(f"id -nG {u}").split(), u
            assert machine.succeed(f"stat -c %a /home/{u}").strip() == "700", u
        machine.fail("runuser -u hinteros-p2 -- ls /home/hinteros-p1")

    with subtest("root-owned app profiles"):
        assert machine.succeed("stat -c '%U %a' /nix/var/nix/profiles/hinteros/apps").strip() == "root 755"
        machine.succeed(f"nix-env -p {P} --set {envs['firefox']}")
        machine.succeed(f"mkdir -p /run/hinteros/apps && ln -sfn {P} {LINK}")
        machine.fail(f"runuser -u hinteros-p1 -- ln -sfn /tmp {P}")
        machine.fail(f"runuser -u hinteros-p1 -- rm {P}")
        machine.fail("runuser -u hinteros-p1 -- touch /nix/var/nix/profiles/hinteros/apps/x")

    with subtest("the env as a profile: manifest, wrapper"):
        m = json.loads(machine.succeed(f"runuser -u hinteros-p1 -- cat {LINK}/share/hinteros/apps.json"))
        assert m["version"] == 1 and m["ids"] == ["firefox"] and m["steam"] is None and m["box"] == [], m
        assert [a["id"] for a in m["apps"]] == ["firefox"], m
        assert m["apps"][0]["command"][0].endswith("/bin/hinteros-firefox-kiosk"), m
        machine.succeed(f"runuser -u hinteros-p1 -- test -x {LINK}/bin/hinteros-firefox-kiosk")
        e = json.loads(machine.succeed(f"cat {envs['empty']}/share/hinteros/apps.json"))
        assert e["ids"] == [] and e["apps"] == [], e

    with subtest("the env reaches no unsandboxed process; its app starts and its icon resolves"):
        # Its own profile, so that p1's generations below stay as they are.
        T = "/nix/var/nix/profiles/hinteros/apps/trust-test"
        machine.succeed(f"nix-env -p {T} --set {envs['trust']} && ln -sfn {T} {LINK}")
        env_out = envs["trust"]
        app_pkg = machine.succeed(f"readlink -f {LINK}/bin/hinteros-trust-app").strip().rsplit("/bin/", 1)[0]
        # Only what the daemon reads is in the env; the package keeps its own share.
        for d in ["bin/hinteros-trust-app", "share/applications/hinteros-trust.desktop",
                  "share/icons/hicolor/256x256/apps/hinteros-trust.png", "share/hinteros/apps.json"]:
            machine.succeed(f"test -e {LINK}/{d}")
        for d in ["share/vulkan", "share/fonts"]:
            machine.fail(f"test -e {LINK}/{d}")
            machine.succeed(f"test -e {app_pkg}/{d}")

        uid = machine.succeed("id -u hinteros-p1").strip()
        sock = f"/run/user/{uid}/hinteros/session.sock"
        machine.wait_for_unit("hinteros-session.service", "hinteros-p1")
        machine.wait_until_succeeds(f"test -S {sock}")

        def rpc(*msgs, wait=2):
            hello = {"jsonrpc": "2.0", "id": 0, "method": "hello",
                     "params": {"api_version": "0.21", "client": {"name": "trust-test", "version": "0"}}}
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

        def moonlight():
            return next((a for a in ok("apps.list")["apps"] if a["id"] == "moonlight"), None)

        # The daemon follows the link (a reload); the icon comes from the env's share by path.
        for _ in range(60):
            m = moonlight()
            if m and m.get("icon"):
                break
            machine.sleep(1)
        print("moonlight", m)
        assert m and m.get("icon", "").endswith("/hicolor/256x256/apps/hinteros-trust.png"), m
        machine.succeed(f"test -f {m['icon']}")

        box = "/home/hinteros-p1/.local/share/hinteros/sandbox/moonlight"
        ok("apps.launch", {"id": "moonlight"})
        machine.wait_until_succeeds(f"test -s {box}/trust-started", timeout=60)

        def environ(pid):
            text = machine.succeed(f"tr '\\0' '\\n' < /proc/{pid}/environ")
            return dict(l.split("=", 1) for l in text.splitlines() if "=" in l)

        # Every process of the console session (the compositor, its Xwayland, the home loop and
        # the home app: all in the login session's scope), and the session daemon.
        session = machine.succeed(
            "for p in $(pgrep -u hinteros-p1); do grep -qs '/session-' /proc/$p/cgroup && echo $p:$(cat /proc/$p/comm); done; true"
        ).split()
        procs = {f"session {s.split(':', 1)[1]} {s.split(':', 1)[0]}": s.split(":", 1)[0] for s in session}
        assert any("cage" in k for k in procs) and len(procs) >= 3, procs
        procs["session daemon"] = machine.succeed(
            f"runuser -u hinteros-p1 -- env XDG_RUNTIME_DIR=/run/user/{uid} systemctl --user show -p MainPID --value hinteros-session.service"
        ).strip()
        bad = ["/run/hinteros/apps", "/nix/var/nix/profiles/hinteros", env_out, app_pkg]
        for name, pid in procs.items():
            env = environ(pid)
            print(name, pid, {k: env.get(k) for k in ["PATH", "XDG_DATA_DIRS", "VK_IMPLICIT_LAYER_PATH"]})
            for k, v in env.items():
                for b in bad:
                    assert b not in v, (name, k, v)
        machine.fail("test -e /tmp/trust-shadowed")
        ok("apps.close", {"id": "moonlight"})
        machine.wait_until_fails(f"pgrep -u hinteros-p1 -f '{app_pkg}/bin/hinteros-trust-app'", timeout=30)
        machine.succeed(f"ln -sfn {P} {LINK} && rm -f {T} {T}-*-link")

    with subtest("Firefox policies box-wide, no Firefox in the system"):
        pol = json.loads(machine.succeed("cat /etc/firefox/policies/policies.json"))["policies"]
        assert pol["ExtensionSettings"]["hinteros-osk@hinteros"]["installation_mode"] == "force_installed", pol
        assert pol["Preferences"]["xpinstall.signatures.required"] == {"Value": False, "Status": "locked"}, pol
        machine.succeed("test -e " + pol["ExtensionSettings"]["hinteros-osk@hinteros"]["install_url"].removeprefix("file://"))
        machine.fail("test -e /run/current-system/sw/bin/firefox")
        machine.fail("test -e /run/current-system/sw/bin/firefox-esr")

    with subtest("settings.cleanup: daily; the timer's service trims to keepProfiles and keepSystem"):
        machine.succeed("systemctl cat nix-gc.timer | grep -x 'OnCalendar=daily'")
        for e in ["both", "empty", "firefox", "both"]:
            machine.succeed(f"nix-env -p {P} --set {envs[e]}")
        gens = machine.succeed(f"nix-env -p {P} --list-generations")
        assert len(gens.strip().splitlines()) == 5, gens
        # A system profile of 5 generations: 2 and 5 are the booted (and running) system, 5 the
        # current one. Keeping 2 removes 1 and 3; 2 stays because it is the booted system.
        S = "/nix/var/nix/profiles/system"
        booted = machine.succeed("readlink -f /run/booted-system").strip()
        machine.succeed(f"rm -f {S} {S}-*-link")
        for p in [envs["empty"], booted, envs["firefox"], envs["both"], booted]:
            machine.succeed(f"nix-env -p {S} --set {p}")
        # (nix-collect-garbage may fail on the VM's host store; the trims come first)
        machine.execute("systemctl start nix-gc.service")
        gens = machine.succeed(f"nix-env -p {P} --list-generations")
        assert [l.split()[0] for l in gens.strip().splitlines()] == ["3", "4", "5"], gens
        assert machine.succeed(f"readlink -f {P}").strip() == envs["both"]
        gens = machine.succeed(f"nix-env -p {S} --list-generations")
        assert [l.split()[0] for l in gens.strip().splitlines()] == ["2", "4", "5"], gens
        assert machine.succeed(f"readlink -f {S}").strip() == booted
        machine.succeed("journalctl -u nix-gc.service --no-pager | grep 'removing generation(s) 1 3, keeping the newest 2'")

    with subtest("guest home emptied at boot; app profiles survive"):
        machine.succeed("runuser -u hinteros-guest -- touch /home/hinteros-guest/left-behind")
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("multi-user.target")
        machine.fail("test -e /home/hinteros-guest/left-behind")
        assert machine.succeed("stat -c '%U %a' /home/hinteros-guest").strip() == "hinteros-guest 700"
        assert machine.succeed(f"readlink -f {P}").strip() == envs["both"]
        machine.fail(f"test -e {LINK}")
  '';
}
