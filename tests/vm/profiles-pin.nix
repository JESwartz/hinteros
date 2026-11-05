# PINs (profiles.md "PINs and locking", "PAM: where the PIN and the kill are enforced",
# "Authority"; DECISIONS D9, D14, H2, J4; VM `profiles-pin`). Greeter mode; p1 = `hinteros-p1`
# (James, the admin profile, locked, PIN 2468), p2 = `hinteros-p2` (Sam, locked, PIN 1357), p3 =
# `hinteros-p3`, a spare account (no metadata), and the admin account `hinteros-admin`.
#   - greetd's PAM stack, probed over greetd's IPC as root: it refuses root, the admin account,
#     a system user and the spare (outside first-boot mode) whatever is typed, and wants the PIN
#     of a locked profile (right: success; the session is never started).
#   - The picker: three wrong PINs for p2 are free, the fourth starts the lock ("locked for 1 s"),
#     each further one doubles it; during a lock even the right PIN is refused. The lock and the
#     failure count survive a reboot (the next wrong PIN locks for the next doubled time); the
#     right PIN after the wait works and resets the count.
#   - The admin profile's PIN has no wait (J4) but 10 wrong tries a boot, counted from the API
#     and the greeter's PAM helper together: then every check is refused, the right PIN too
#     (`reboot_required`, `hinteros:reboot`), audited once; a service restart keeps it, a reboot
#     ends it.
#   - Admin actions need the admin PIN, from any profile (here p2's session): rename and reset
#     another profile's PIN, guest on/off, the starter set; another profile's PIN is not enough.
#     A profile's own changes need its own PIN, which shares the backoff with the picker.
#   - The resume token (profiles.switch to one's own id) lets `pin unlocked` pass once, and not
#     after it expired.
#   - `hinteros-system reset-pin` (root only, H2) removes a forgotten PIN and its backoff; the
#     profile then enters without one and sets a new PIN without the old one.
# Not covered in a VM: the admin profile's own PIN reset through polkit `profiles.recover` with
# the admin password (needs the polkit agent on the TV; polkit-agent covers the agent itself).
{ self, pkgs }:
let
  profiles = import ./system/profiles.nix { inherit self pkgs; };
  adminHash = pkgs.runCommand "admin-pw" { nativeBuildInputs = [ pkgs.mkpasswd ]; } ''
    echo -n "$(mkpasswd -m sha-512 -S saltsaltsalt hunter2)" > $out
  '';
in
profiles.mkTest {
  name = "profiles-pin";
  timeout = 2400;
  state = profiles.mkState {
    accounts = [
      "p1"
      "p2"
      "p3"
    ];
    guest = false;
  };
  profiles = {
    p1 = {
      name = "James";
      admin = true;
      locked = true;
      pin = "2468";
    };
    p2 = {
      name = "Sam";
      color = "orange";
      locked = true;
      pin = "1357";
    };
  };
  extraModule = {
    hinteros.admin = {
      enable = true;
      hashedPasswordFile = "${adminHash}";
    };
  };

  testScript = ''
    boot_box()

    def greetd(user, *answers):
        return json.loads(machine.succeed(f"python3 /etc/hinteros-test/greetd.py {user} {' '.join(answers)}"))

    def pin_state(pid):
        return json.loads(machine.succeed(f"cat /var/lib/hinteros/pins/{pid}.state"))["data"]

    def try_pin(target, pin):
        g = greeter(target, pin)
        assert len(g["outcomes"]) == 1, g
        return g["outcomes"][0]

    def wait_unlocked(pid):
        until = pin_state(pid)["locked_until"]
        while int(machine.succeed("date +%s").strip()) <= until:
            machine.sleep(1)

    with subtest("greetd's PAM stack: who may enter at all"):
        picker_up()
        # Not members of `hinteros`: refused before any PIN (no prompt).
        for user in ["root", "hinteros-admin", "nobody"]:
            r = greetd(user, "2468")
            assert r["result"] == "error" and r["prompts"] == 0, (user, r)
        # A spare outside first-boot mode: asked, and refused whatever is typed.
        r = greetd("hinteros-p3", "2468")
        assert r["result"] == "error", r
        # A locked profile: its PIN.
        r = greetd("hinteros-p2", "0000")
        assert r["result"] == "error" and r["prompts"] == 1, r
        assert any("hinteros:wrong" in m for m in r["messages"]), r
        r = greetd("hinteros-p2", "1357")
        assert r["result"] == "success" and r["prompts"] == 1, r
        # (that success reset the one failure)
        assert pin_state("p2")["failures"] == 0, pin_state("p2")
        # Nothing was started: still the picker.
        picker_up()
        machine.fail("pgrep -u hinteros-p2")
        assert "hinteros-p3" not in [p["user"] for p in public()["profiles"]], public()
        assert public()["first_boot"] is False

    with subtest("the picker: three free tries, then a doubling wait"):
        for _ in range(3):
            o = try_pin("p2", "0000")
            assert o["ok"] is False and not o.get("locked_s"), o
        o = try_pin("p2", "0000")
        assert o["ok"] is False and o.get("locked_s") == 1, o
        wait_unlocked("p2")
        o = try_pin("p2", "0000")
        assert o["ok"] is False and o["locked_s"] == 2, o
        wait_unlocked("p2")
        o = try_pin("p2", "0000")
        assert o["ok"] is False and o["locked_s"] == 4, o
        wait_unlocked("p2")
        o = try_pin("p2", "0000")
        assert o["ok"] is False and o["locked_s"] == 8, o
        # During the lock even the right PIN is refused, with the time left.
        o = try_pin("p2", "1357")
        assert o["ok"] is False and 0 < o["locked_s"] <= 8, o
        # profiles.list shows the wait; the admin profile never has one. (The public view, which
        # the picker reads, is not republished after a failure in PAM: a daemon gap, see the
        # M7 VM test report. The picker has the wait from greeter_result.)
        p = {x["id"]: x for x in sys_ok("hinteros-p1", "profiles.list")["profiles"]}
        assert p["p2"]["locked_until"], p
        assert not p["p1"]["locked_until"], p
        assert pin_state("p2")["failures"] == 7, pin_state("p2")

    with subtest("the wait and the failures survive a reboot"):
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("hinteros-system.service")
        assert pin_state("p2")["failures"] == 7, pin_state("p2")
        picker_up()
        wait_unlocked("p2")
        # The eighth failure doubles again (16 s), it does not start over at 1 s.
        o = try_pin("p2", "0000")
        assert o["ok"] is False and o["locked_s"] == 16, o
        wait_unlocked("p2")
        g = greeter("p2", "1357")
        assert g["outcomes"][-1]["ok"] is True, g
        session_of("hinteros-p2")
        assert pin_state("p2") == {"failures": 0, "locked_until": 0}, pin_state("p2")

    with subtest("the admin PIN: no wait, but 10 wrong tries a boot, then only a reboot helps"):
        def rename_p1(pin):
            return sess("hinteros-p2", "system.profiles.rename", {"id": "p1", "name": "Jim", "admin_pin": pin})

        def pam_verify(pin):
            return machine.succeed(f"printf '{pin}\\0' | env PAM_USER=hinteros-p1 hinteros-system pin verify || true").strip()

        locked_out = {"pin": "admin", "reboot_required": True}
        # API (any profile's session) and the greeter's PAM helper share one count; no wait.
        for _ in range(6):
            r = rename_p1("0000")
            assert r["error"]["code"] == 3016 and r["error"]["data"] == {"pin": "admin"}, r
        for _ in range(3):
            assert pam_verify("0000") == "hinteros:wrong"
        assert not {x["id"]: x for x in public()["profiles"]}["p1"]["locked_until"]
        assert machine.succeed("stat -c '%a %U' /var/lib/hinteros/pins/p1.tries").strip() == "600 hinteros-system"
        # The tenth: refused until a reboot, even the right PIN, on every path.
        r = rename_p1("0000")
        assert r["error"]["code"] == 3016 and r["error"]["data"] == locked_out, r
        r = rename_p1("2468")
        assert r["error"]["code"] == 3016 and r["error"]["data"] == locked_out, r
        r = sess("hinteros-p2", "system.guest.set", {"enabled": True, "admin_pin": "2468"})
        assert r["error"]["code"] == 3016 and r["error"]["data"] == locked_out, r
        assert pam_verify("2468") == "hinteros:reboot"
        assert profiles_file()["profiles"]["p1"]["name"] == "James"
        # Audited once, when it started.
        out = machine.succeed("journalctl -o verbose HINTEROS_PIN_OUTCOME=lockout_started")
        assert out.count("HINTEROS_PROFILE=p1") == 1, out
        # A restart of the service keeps it.
        machine.succeed("systemctl restart hinteros-system.service")
        machine.wait_for_unit("hinteros-system.service")
        for _ in range(60):
            r = rename_p1("2468")
            if r.get("error", {}).get("code") != 3001:
                break
            time.sleep(1)
        assert r["error"]["code"] == 3016 and r["error"]["data"] == locked_out, r
        # A reboot ends it; then the right PIN works and wrong is only wrong again.
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("hinteros-system.service")
        assert pam_verify("0000") == "hinteros:wrong"
        enter("p2", "hinteros-p2", "1357")
        assert sess_ok("hinteros-p2", "system.profiles.rename", {"id": "p1", "name": "James", "admin_pin": "2468"}) == {}
        assert json.loads(machine.succeed("cat /var/lib/hinteros/pins/p1.tries"))["data"]["failures"] == 0

    with subtest("admin actions need the admin PIN, from any profile"):
        # Rename another profile: no PIN, its own PIN, the admin PIN.
        r = sess("hinteros-p2", "system.profiles.rename", {"id": "p1", "name": "Jim"})
        assert r["error"]["code"] == 3016 and r["error"]["data"] == {"pin": "admin"}, r
        r = sess("hinteros-p2", "system.profiles.rename", {"id": "p1", "name": "Jim", "admin_pin": "1357"})
        assert r["error"]["code"] == 3016 and r["error"]["data"]["pin"] == "admin", r
        assert profiles_file()["profiles"]["p1"]["name"] == "James"
        assert sess_ok("hinteros-p2", "system.profiles.rename", {"id": "p1", "name": "Jim", "admin_pin": "2468"}) == {}
        assert profiles_file()["profiles"]["p1"]["name"] == "Jim"
        # Renaming yourself needs nothing.
        assert sess_ok("hinteros-p2", "system.profiles.rename", {"id": "p2", "name": "Sammy"}) == {}
        # Reset another profile's PIN (here: p2's own, as a parent would): the admin PIN.
        before = machine.succeed("cat /var/lib/hinteros/pins/p2")
        r = sess("hinteros-p2", "system.profiles.reset_pin", {"id": "p2", "new_pin": "9753", "admin_pin": "1357"})
        assert r["error"]["code"] == 3016 and r["error"]["data"]["pin"] == "admin", r
        assert machine.succeed("cat /var/lib/hinteros/pins/p2") == before
        assert sess_ok("hinteros-p2", "system.profiles.reset_pin", {"id": "p2", "new_pin": "9753", "admin_pin": "2468"}) == {}
        # Guest on/off and the starter set: the admin PIN (no job without it).
        r = sess("hinteros-p2", "system.guest.set", {"enabled": True, "admin_pin": "9753"})
        assert r["error"]["code"] == 3016 and r["error"]["data"]["pin"] == "admin", r
        r = sess("hinteros-p2", "system.starter_set.set", {"ids": [], "admin_pin": "9753"})
        assert r["error"]["code"] == 3016 and r["error"]["data"]["pin"] == "admin", r
        # Removing the admin profile: never.
        rev = sys_ok("hinteros-p2", "settings.get")["revision"]
        r = sess("hinteros-p2", "system.profiles.remove", {"id": "p1", "confirm_id": "p1", "admin_pin": "2468", "revision": rev})
        assert r["error"]["code"] == -32602 and r["error"]["data"]["reason"] == "admin", r
        assert [j for j in sys_ok("hinteros-p2", "jobs.list")["jobs"] if j["state"] == "running"] == []

    with subtest("own changes need the own PIN, which shares the backoff"):
        r = sess("hinteros-p2", "system.profiles.set_locked", {"locked": False, "pin": "2468"})
        assert r["error"]["code"] == 3016 and r["error"]["data"] == {"pin": "self"}, r
        r = sess("hinteros-p2", "system.profiles.set_pin", {"pin": "1111", "current_pin": "0000"})
        assert r["error"]["code"] == 3016 and r["error"]["data"] == {"pin": "self"}, r
        r = sess("hinteros-p2", "system.profiles.set_pin", {"pin": "1111"})
        assert r["error"]["code"] == 3016 and r["error"]["data"] == {"pin": "self"}, r
        assert pin_state("p2")["failures"] == 2, pin_state("p2")
        r = sess("hinteros-p2", "system.profiles.unlock", {"pin": "0000"})
        assert r["error"]["code"] == 3016 and "retry_after_ms" not in r["error"]["data"], r
        r = sess("hinteros-p2", "system.profiles.unlock", {"pin": "0000"})
        assert r["error"]["code"] == 3016 and r["error"]["data"]["retry_after_ms"] == 1000, r
        assert pin_state("p2")["failures"] == 4, pin_state("p2")
        wait_unlocked("p2")
        assert sess_ok("hinteros-p2", "system.profiles.set_locked", {"locked": True, "pin": "9753"}) == {}
        assert pin_state("p2")["failures"] == 0, pin_state("p2")

    with subtest("the resume token: once, and not after it expired"):
        unlocked = "env PAM_USER=hinteros-p2 hinteros-system pin unlocked"
        # Locked, with a PIN, no token: not without the PIN.
        machine.fail(unlocked)
        assert sys_ok("hinteros-p2", "profiles.switch", {"id": "p2"}) == {}
        hint = json.loads(machine.succeed("cat /run/hinteros/switch.json"))
        assert hint["token"]["user"] == "hinteros-p2", hint
        assert machine.succeed("stat -c '%a %U' /run/hinteros/switch.json").strip() == "600 hinteros-system"
        # A token is bound to its user.
        machine.fail("env PAM_USER=hinteros-p1 hinteros-system pin unlocked")
        machine.succeed(unlocked)
        machine.fail(unlocked)
        # Another one, expired.
        assert sys_ok("hinteros-p2", "profiles.switch", {"id": "p2"}) == {}
        machine.succeed(
            "t=$(($(date +%s) - 1)); jq -c --argjson t $t '.expires = $t | .token.expires = $t' "
            "/run/hinteros/switch.json > /run/hinteros/switch.new && mv /run/hinteros/switch.new /run/hinteros/switch.json"
        )
        machine.fail(unlocked)
        machine.succeed("rm -f /run/hinteros/switch.json")

    with subtest("a forgotten PIN: reset-pin from root"):
        # Some failures first: the reset clears them too.
        for _ in range(4):
            sess("hinteros-p2", "system.profiles.unlock", {"pin": "0000"})
        assert pin_state("p2")["failures"] == 4
        # Not as a profile user.
        machine.fail("runuser -u hinteros-p2 -- hinteros-system reset-pin p2")
        machine.fail("hinteros-system reset-pin Nobody")
        out = machine.succeed("hinteros-system reset-pin Sammy")
        assert "Sammy (p2)" in out, out
        machine.fail("test -e /var/lib/hinteros/pins/p2")
        assert pin_state("p2")["failures"] == 0, pin_state("p2")
        machine.succeed("journalctl -o verbose HINTEROS_METHOD=reset-pin | grep -q 'PROFILE=p2'")
        # Without a PIN the profile enters without one (even though it is locked)...
        machine.succeed("env PAM_USER=hinteros-p2 hinteros-system pin unlocked")
        cur = sess_ok("hinteros-p2", "profile.current")
        assert cur["locked"] and not cur["pin_set"], cur
        assert {x["id"]: x for x in sys_ok("hinteros-p2", "profiles.list")["profiles"]}["p2"]["pin_set"] is False
        # ...and sets a new PIN without the old one ("Set your PIN"); then the old way again.
        assert sess_ok("hinteros-p2", "system.profiles.set_pin", {"pin": "8642"}) == {}
        machine.fail("env PAM_USER=hinteros-p2 hinteros-system pin unlocked")
        r = sess("hinteros-p2", "system.profiles.set_pin", {"pin": "1111"})
        assert r["error"]["code"] == 3016 and r["error"]["data"] == {"pin": "self"}, r
        # The admin profile's own PIN, by id: root can always remove it.
        out = machine.succeed("hinteros-system reset-pin p1")
        assert "(p1)" in out, out
        machine.fail("test -e /var/lib/hinteros/pins/p1")
  '';
}
