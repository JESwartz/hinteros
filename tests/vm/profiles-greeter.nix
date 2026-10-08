# Greeter mode end to end (profiles.md "The pieces", DECISIONS D7-D9, S4): a schema-2 box with
# `hinteros.profiles.greeter.enable` boots into the picker (cage + the launcher with --greeter,
# the session daemon in greeter mode as `hinteros-greeter`). Profiles: p1 = `hinteros`, the admin,
# locked with PIN 2468; p2 = `hinteros-p2`, unlocked, no PIN. A client of the greeter daemon's
# socket stands in for the picker's buttons (tests/vm/system/client/greeter.py):
#   - greeter.login p2: no PIN asked (PAM `pin unlocked`), p2's session starts as hinteros-p2;
#   - from p2's session, session.switch_profile p1: the session ends, the picker comes back
#     (p1 is locked: no fast path), a wrong PIN is refused (PAM `pin verify`), the right one
#     starts p1's session as hinteros and nothing of p2 is left running (`pin end-others`).
# Each handover leaves greetd's VT (read from /dev/vcs1) with the PAM splash ("Loading Sam",
# "HinterOS" on the way back, "Loading James") and no log text (everything greetd runs logs to the
# journal). Then root removes p1's forgotten PIN with `hinteros-system reset-pin James`: p1's
# session sees `pin_set: false` and sets a new PIN without the old one.
{ self, pkgs }:
let
  fixture = ./fixtures/profiles-greeter;
  # p1's PIN as the service stores it (an argon2id PHC string; any parameters verify).
  p1Pin = pkgs.runCommand "profiles-greeter-p1-pin" { nativeBuildInputs = [ pkgs.libargon2 ]; } ''
    printf 2468 | argon2 hinteros-test-salt -id -t 2 -m 12 -p 1 -e > $out
  '';
  profilesJson = pkgs.writeText "profiles.json" (
    builtins.toJSON {
      version = 1;
      next = 3;
      profiles =
        let
          meta = name: color: admin: locked: {
            inherit
              name
              color
              admin
              locked
              ;
            created_at = 1790000000;
            last_used_at = null;
            appearance = {
              text_scale = 1.0;
              high_contrast = false;
              reduce_motion = false;
            };
          };
        in
        {
          p1 = meta "James" "teal" true true;
          p2 = meta "Sam" "orange" false false;
        };
    }
  );
in
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-profiles-greeter";
  meta.timeout = 1800;

  nodes.machine =
    { lib, ... }:
    {
      imports = [
        ../../nixos/modules
        self.nixosModules.catalog
        ../../nixos/vm
      ];
      hinteros = {
        state = builtins.fromJSON (builtins.readFile (fixture + "/state.json"));
        deviceConfig.configDir = fixture;
        profiles.greeter.enable = true;
      };
      systemd.tmpfiles.settings."10-hinteros-config"."/etc/hinteros".C = {
        user = "root";
        group = "root";
        mode = "0755";
        argument = "${fixture}";
      };
      # The profiles as hinteros-system keeps them, there before it starts at the first boot.
      systemd.services.hinteros-test-profiles = {
        wantedBy = [ "hinteros-system.service" ];
        before = [ "hinteros-system.service" ];
        unitConfig.ConditionPathExists = "!/var/lib/hinteros/profiles.json";
        serviceConfig.Type = "oneshot";
        script = ''
          install -d -m 0700 /var/lib/hinteros /var/lib/hinteros/pins
          install -m 0600 ${profilesJson} /var/lib/hinteros/profiles.json
          install -m 0600 ${p1Pin} /var/lib/hinteros/pins/p1
        '';
      };
      environment.etc."hinteros-test".source = ./system/client;
      environment.systemPackages = [ pkgs.python3 ];
      virtualisation.memorySize = lib.mkForce 3072;
    };

  testScript = ''
    import json

    ENV = "HINTEROS_SESSION_API=0.12 PYTHONPATH=/etc/hinteros-test"

    def sock(user):
        uid = machine.succeed(f"id -u {user}").strip()
        return f"/run/user/{uid}/hinteros/session.sock"

    def picker_up():
        machine.wait_until_succeeds(f"test -S {sock('hinteros-greeter')}", timeout=120)
        machine.wait_until_succeeds("pgrep -u hinteros-greeter -f -- '--greeter'")

    def greeter(target, *pins):
        out = machine.succeed(
            f"runuser -u hinteros-greeter -- env {ENV} HINTEROS_SESSION_SOCK={sock('hinteros-greeter')} "
            f"python3 /etc/hinteros-test/greeter.py {target} {' '.join(pins)}"
        )
        return json.loads(out)

    def sess(user, method, params=None):
        out = machine.succeed(
            f"runuser -u {user} -- env {ENV} HINTEROS_SESSION_SOCK={sock(user)} "
            f"python3 /etc/hinteros-test/session.py {method} '{json.dumps(params or {})}'"
        )
        return json.loads(out)["response"]

    def vt_text():
        # greetd's VT (tty1) as text: what the kernel console shows between two compositors.
        return machine.succeed("tr -c '[:print:]' ' ' < /dev/vcs1")

    def assert_splash(expected, gone=()):
        text = vt_text()
        assert expected in text, f"{expected!r} not on tty1: {text.strip()!r}"
        for g in gone:
            assert g not in text, f"{g!r} still on tty1: {text.strip()!r}"
        # Nothing greetd runs logs to the VT (everything goes to the journal).
        for word in ["WARN", "INFO", "ERROR", "DEBUG", "hinteros_session", "Permission denied"]:
            assert word not in text, f"log text {word!r} on tty1: {text.strip()!r}"

    def session_of(user):
        machine.wait_until_succeeds(f"test -S {sock(user)}", timeout=120)
        machine.wait_until_succeeds(f"pgrep -u {user} -f '/bin/cage '", timeout=60)
        # greetd lets the greeter go first (the picker quits, or is stopped after 5 s).
        machine.wait_until_fails("pgrep -u hinteros-greeter -f '/bin/cage '", timeout=60)

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("greetd.service")

    with subtest("the box boots into the picker, not into a profile"):
        picker_up()
        machine.fail("pgrep -u hinteros -f '/bin/cage '")
        machine.fail("pgrep -u hinteros-p2")
        assert "hinteros" not in machine.succeed("id -nG hinteros-greeter").split()

    with subtest("an unlocked profile: no PIN, its session starts as its own user"):
        g = greeter("p2")
        names = {p["id"]: p["name"] for p in g["list"]["profiles"]}
        assert names == {"p1": "James", "p2": "Sam"}, g
        assert [p["locked"] for p in g["list"]["profiles"]] == [True, False], g
        assert len(g["outcomes"]) == 1 and g["outcomes"][0]["ok"] is True, g
        session_of("hinteros-p2")
        # The console splash of the handover (PAM `pin splash`) is on greetd's VT.
        assert_splash("Loading Sam")
        cur = sess("hinteros-p2", "profile.current")["result"]
        assert cur["id"] == "p2" and not cur["admin"] and not cur["guest"], cur

    with subtest("switch to the locked p1: the picker asks for its PIN, a wrong one is refused"):
        r = sess("hinteros-p2", "session.switch_profile", {"id": "p1"})
        assert r.get("result") == {}, r
        machine.wait_until_fails("pgrep -u hinteros-p2 -f '/bin/cage '", timeout=90)
        picker_up()
        # On the way back to the picker: just "HinterOS", no log lines.
        assert_splash("HinterOS", gone=["Loading Sam"])
        pub = json.loads(machine.succeed("cat /run/hinteros/profiles-public.json"))
        assert pub["next"]["target"] == "p1" and not pub["next"]["fast"], pub
        g = greeter("p1", "0000", "2468")
        assert len(g["outcomes"]) == 2, g
        assert g["outcomes"][0]["ok"] is False, g
        assert g["outcomes"][1]["ok"] is True, g
        session_of("hinteros")
        assert_splash("Loading James", gone=["Loading Sam"])
        cur = sess("hinteros", "profile.current")["result"]
        assert cur["id"] == "p1" and cur["admin"] and cur["pin_set"], cur
        # end-others: nothing of p2 is left.
        machine.wait_until_fails("pgrep -u hinteros-p2", timeout=30)

    with subtest("a forgotten PIN: root removes it from the terminal, the profile sets a new one"):
        # On root's PATH (systemPackages); without an argument it lists the profiles.
        out = machine.succeed("hinteros-system reset-pin")
        assert "p1" in out and "James" in out and "PIN set" in out, out
        # Not as root: refused.
        machine.fail("runuser -u hinteros -- hinteros-system reset-pin p1")
        out = machine.succeed("hinteros-system reset-pin James")
        assert "Removed the PIN of James (p1)" in out, out
        machine.fail("test -e /var/lib/hinteros/pins/p1")
        cur = sess("hinteros", "profile.current")["result"]
        assert cur["id"] == "p1" and cur["locked"] and not cur["pin_set"], cur
        # The audit entry, without any PIN.
        machine.succeed("journalctl -o verbose HINTEROS_METHOD=reset-pin | grep -q 'PROFILE=p1'")
        # "Set your PIN" (no current PIN needed), then p1 has a PIN again.
        r = sess("hinteros", "system.profiles.set_pin", {"pin": "8642"})
        assert r.get("result") == {}, r
        cur = sess("hinteros", "profile.current")["result"]
        assert cur["pin_set"], cur
  '';
}
