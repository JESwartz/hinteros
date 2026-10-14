# The system side of per-profile apps and accounts (apps.md build plan steps 3, 6, 9; profiles.md),
# without the M7 daemon: hinteros-system's part (setting a profile's Nix profile, publishing
# /run/hinteros/apps/<user>) is done by hand here, the way its jobs do it (DECISIONS D4). Checks:
#   - schema-2 accounts: p1 = hinteros, p2 = hinteros-p2 (uid 20002), the guest (uid 20000), all in
#     `hinteros`, homes 0700, no static device groups needed for the checks below;
#   - /nix/var/nix/profiles/hinteros{,/apps} root 0755; a profile user cannot repoint its link;
#   - an env built by `config.hinteros.appEnv.build` works as a profile: its manifest, its kiosk
#     wrapper, and the session command puts it on PATH and XDG_DATA_DIRS (cage's environment);
#   - the box-wide Firefox policies with no Firefox package in the system;
#   - the automatic clean-up from state.json `settings.cleanup` (daily, keepSystem 2,
#     keepProfiles 3): the timer's service trims an app profile to its 3 newest generations and
#     the system profile to its 2 newest, keeping the booted system's older generation;
#   - the guest's home is emptied at boot, the app profiles survive a reboot.
{ self, pkgs }:
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
      };
    in
    {
      imports = [
        ../../nixos/modules
        self.nixosModules.catalog
        ../../nixos/vm
      ];
      hinteros.state = {
        schemaVersion = 2;
        profiles = [
          {
            id = "p1";
            user = "hinteros";
          }
          {
            id = "p2";
            user = "hinteros-p2";
          }
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
      system.extraDependencies = lib.attrValues envs;
      environment.etc."hinteros-test/envs.json".text = builtins.toJSON (
        lib.mapAttrs (_: e: e.outPath) envs
      );
      # Apps, not the picker: autologin of p1 (greeter mode: profiles-greeter).
      hinteros.profiles.greeter.enable = false;
      virtualisation.memorySize = lib.mkForce 2048;
    };

  testScript = ''
    import json

    envs = json.loads(machine.succeed("cat /etc/hinteros-test/envs.json"))
    P = "/nix/var/nix/profiles/hinteros/apps/hinteros"
    LINK = "/run/hinteros/apps/hinteros"

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("greetd.service")
    machine.wait_until_succeeds("pgrep -u hinteros -f '/bin/cage '")

    with subtest("accounts"):
        assert machine.succeed("id -u hinteros-p2").strip() == "20002"
        assert machine.succeed("id -u hinteros-guest").strip() == "20000"
        for u in ["hinteros", "hinteros-p2", "hinteros-guest"]:
            assert "hinteros" in machine.succeed(f"id -nG {u}").split(), u
            assert machine.succeed(f"stat -c %a /home/{u}").strip() == "700", u
        machine.fail("runuser -u hinteros-p2 -- ls /home/hinteros")

    with subtest("root-owned app profiles"):
        assert machine.succeed("stat -c '%U %a' /nix/var/nix/profiles/hinteros/apps").strip() == "root 755"
        machine.succeed(f"nix-env -p {P} --set {envs['firefox']}")
        machine.succeed(f"mkdir -p /run/hinteros/apps && ln -sfn {P} {LINK}")
        machine.fail(f"runuser -u hinteros -- ln -sfn /tmp {P}")
        machine.fail(f"runuser -u hinteros -- rm {P}")
        machine.fail("runuser -u hinteros -- touch /nix/var/nix/profiles/hinteros/apps/x")

    with subtest("the env as a profile: manifest, wrapper"):
        m = json.loads(machine.succeed(f"runuser -u hinteros -- cat {LINK}/share/hinteros/apps.json"))
        assert m["version"] == 1 and m["ids"] == ["firefox"] and m["steam"] is None and m["box"] == [], m
        assert [a["id"] for a in m["apps"]] == ["firefox"], m
        assert m["apps"][0]["command"][0].endswith("/bin/hinteros-firefox-kiosk"), m
        machine.succeed(f"runuser -u hinteros -- test -x {LINK}/bin/hinteros-firefox-kiosk")
        e = json.loads(machine.succeed(f"cat {envs['empty']}/share/hinteros/apps.json"))
        assert e["ids"] == [] and e["apps"] == [], e

    with subtest("the session command puts the profile's env on PATH and XDG_DATA_DIRS"):
        pid = machine.succeed("pgrep -u hinteros -o -f '/bin/cage '").strip()
        env = dict(l.split("=", 1) for l in machine.succeed(f"tr '\\0' '\\n' < /proc/{pid}/environ").splitlines() if "=" in l)
        # (cage's own wrapper puts Xwayland in front)
        path = env["PATH"].split(":")
        assert LINK + "/bin" in path and path.index(LINK + "/bin") < path.index("/run/current-system/sw/bin"), path
        assert LINK + "/share" in env["XDG_DATA_DIRS"].split(":"), env["XDG_DATA_DIRS"]

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
