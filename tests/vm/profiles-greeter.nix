# Greeter mode end to end (profiles.md "The pieces", DECISIONS D7-D9, S4, J1-J3): a schema-2 box
# with `hinteros.profiles.greeter.enable` boots into the picker (cage + the launcher with
# --greeter, the session daemon in greeter mode as `hinteros-greeter`). Profiles: p1 =
# `hinteros`, the admin, locked with PIN 2468; p2 = `hinteros-p2`, unlocked, no PIN; the guest. A
# client of the greeter daemon's socket stands in for the picker's buttons
# (tests/vm/system/client/greeter.py), one of a profile's daemon for the launcher (session.py):
#   - at the picker, the admin p1 with five wrong PINs (never a wait: no admin backoff), then the
#     right one;
#   - switches with session.switch_profile, each straight from one session to the next with no
#     picker UI (a watcher samples the greeter user's processes every 50 ms: no compositor, no
#     launcher or daemon in greeter mode): p1 -> unlocked p2, p2 -> the guest, the guest -> the
#     locked p1 (its PIN given in the guest's session first; a missing or wrong one is refused
#     there and the guest's session stays), p1 -> the guest again;
#   - End guest session goes to the picker (the used-up switch hint does not lead back in).
# Each handover paints the PAM console splash ("Loading Sam…" etc. in block letters, journalled as
# hinteros-splash) on greetd's VT (/dev/vcsu1) with no log text, and end-others leaves nothing of
# the previous account running. Then root removes p1's forgotten PIN with `hinteros-system
# reset-pin James`: p1's session sees `pin_set: false` and sets a new PIN without the old one.
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

    def splashes():
        # What `pin splash` painted, in order (it journals the text; the VT has block letters).
        out = machine.succeed("journalctl -t hinteros-splash -o json --output-fields=HINTEROS_SPLASH")
        return [json.loads(l)["HINTEROS_SPLASH"] for l in out.splitlines() if l.strip()]

    def assert_splash(expected, before):
        # Since `before` (the count of splashes then): the handover painted `expected`, and
        # greetd's VT (tty1) shows the big letters and no log text (everything greetd runs logs
        # to the journal).
        new = splashes()[before:]
        assert expected in new, f"{expected!r} not painted: {new!r}"
        vt = json.loads(machine.succeed("python3 /etc/hinteros-test/vt.py 1"))
        assert vt["blocks"] > 40, f"no block letters on tty1: {vt!r}"
        for word in ["WARN", "INFO", "ERROR", "DEBUG", "hinteros_session", "Permission denied"]:
            assert word not in vt["text"], f"log text {word!r} on tty1: {vt['text'].strip()!r}"

    def session_of(user):
        machine.wait_until_succeeds(f"test -S {sock(user)}", timeout=120)
        machine.wait_until_succeeds(f"pgrep -u {user} -f '/bin/cage '", timeout=60)
        # greetd lets the greeter go first (the picker quits, or is stopped after 5 s).
        machine.wait_until_fails("pgrep -u hinteros-greeter -f '/bin/cage '", timeout=60)

    # Anything of the picker's UI as the greeter: the compositor (cage here, gamescope on a
    # box) or the launcher / session daemon in greeter mode. Sampled every 50 ms from boot on.
    GREETER_UI = "/bin/cage |gamescope|--greeter"
    machine.wait_for_unit("multi-user.target")
    machine.succeed(
        "systemd-run --unit=greeter-ui-watch ${pkgs.bash}/bin/sh -c "
        f"'while :; do ${pkgs.procps}/bin/pgrep -a -u hinteros-greeter -f -- \"{GREETER_UI}\" >> /tmp/greeter-ui; "
        "${pkgs.coreutils}/bin/sleep 0.05; done'"
    )
    machine.wait_for_unit("greetd.service")

    def watch_greeter():
        machine.succeed(": > /tmp/greeter-ui")
        return len(splashes())

    def assert_no_greeter_ui():
        seen = machine.succeed("cat /tmp/greeter-ui").strip()
        assert seen == "", f"the picker ran during the switch:\n{seen}"

    def switch(src, dst, user, expected, **params):
        # From `src`'s session to `dst` without the picker: old session, then new session,
        # with the console splash between.
        before = watch_greeter()
        r = sess(src, "session.switch_profile", {"id": dst, **params})
        assert r.get("result") == {}, r
        session_of(user)
        machine.wait_until_fails(f"pgrep -u {src} -f '/bin/cage '", timeout=60)
        assert_no_greeter_ui()
        assert_splash(expected, before)

    with subtest("the box boots into the picker, not into a profile"):
        picker_up()
        machine.fail("pgrep -u hinteros -f '/bin/cage '")
        machine.fail("pgrep -u hinteros-p2")
        assert "hinteros" not in machine.succeed("id -nG hinteros-greeter").split()
        assert "HinterOS" in splashes(), splashes()

    with subtest("the picker: the admin profile's PIN; wrong ones never lock it out"):
        before = len(splashes())
        g = greeter("p1", "0000", "0000", "0000", "0000", "0000", "2468")
        names = {p["id"]: p["name"] for p in g["list"]["profiles"]}
        assert names == {"p1": "James", "p2": "Sam"}, g
        assert [p["locked"] for p in g["list"]["profiles"]] == [True, False], g
        assert len(g["outcomes"]) == 6, g
        for o in g["outcomes"][:5]:
            assert o["ok"] is False and not o.get("locked_seconds"), g
        assert g["outcomes"][5]["ok"] is True, g
        session_of("hinteros")
        assert_splash("Loading James…", before)
        cur = sess("hinteros", "profile.current")["result"]
        assert cur["id"] == "p1" and cur["admin"] and cur["pin_set"], cur

    with subtest("switch to an unlocked profile: no picker, one session to the next"):
        switch("hinteros", "p2", "hinteros-p2", "Loading Sam…")
        cur = sess("hinteros-p2", "profile.current")["result"]
        assert cur["id"] == "p2" and not cur["admin"] and not cur["guest"], cur
        # end-others: nothing of p1 is left; the hint is used up.
        machine.wait_until_fails("pgrep -u hinteros", timeout=30)
        machine.fail("test -e /run/hinteros/switch.json")

    with subtest("switch to the guest: no picker"):
        switch("hinteros-p2", "guest", "hinteros-guest", "Loading Guest…")
        assert sess("hinteros-guest", "profile.current")["result"]["guest"]
        machine.wait_until_fails("pgrep -u hinteros-p2", timeout=30)

    with subtest("switch to a locked profile: its PIN in the old session first, then no picker"):
        before = watch_greeter()
        r = sess("hinteros-guest", "session.switch_profile", {"id": "p1"})
        assert r["error"]["code"] == 3016 and r["error"]["data"] == {"pin": "target"}, r
        r = sess("hinteros-guest", "session.switch_profile", {"id": "p1", "pin": "0000"})
        assert r["error"]["code"] == 3016 and r["error"]["data"] == {"pin": "target"}, r
        # A wrong PIN ends nothing.
        machine.succeed("pgrep -u hinteros-guest -f '/bin/cage '")
        machine.fail("test -e /run/hinteros/switch.json")
        switch("hinteros-guest", "p1", "hinteros", "Loading James…", pin="2468")
        cur = sess("hinteros", "profile.current")["result"]
        assert cur["id"] == "p1", cur
        machine.wait_until_fails("pgrep -u hinteros-guest", timeout=30)
        # The token was used up: the hint (and its token) is gone.
        machine.fail("test -e /run/hinteros/switch.json")

    with subtest("End guest session: the picker, not straight back into the guest"):
        switch("hinteros", "guest", "hinteros-guest", "Loading Guest…")
        before = len(splashes())
        r = sess("hinteros-guest", "session.end_guest")
        assert r.get("result") == {}, r
        machine.wait_until_fails("pgrep -u hinteros-guest -f '/bin/cage '", timeout=90)
        picker_up()
        assert_splash("HinterOS", before)
        assert "--greeter" in machine.succeed("cat /tmp/greeter-ui"), "the watch saw no picker"
        g = greeter("p1", "2468")
        assert g["outcomes"][-1]["ok"] is True, g
        session_of("hinteros")

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
