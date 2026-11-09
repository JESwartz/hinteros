# Creating, renaming and removing profiles (VM `profiles-lifecycle`). Greeter mode; p1 =
# `hinteros-p1` (James, admin, unlocked, PIN 2468), p2 = `hinteros-p2` (Sam, unlocked, PIN 1357);
# the starter env is Firefox + YouTube.
#   - profiles.create from p1's session is a job whose apply flow adds the account (a rebuild:
#     the stub "builds" the specialisation with it): `hinteros-p3` has uid 20003, home 0700,
#     groups users + hinteros only, its metadata and PIN, and the starter env as its app profile;
#     p1's compositor and launcher keep running (same pids).
#   - Renaming another profile needs the admin PIN; renaming yourself does not.
#   - The admin profile cannot be removed (from the UI path: the service refuses it).
#   - Removing p3 (admin PIN) kills its processes (also a system-level unit of its uid), switches
#     to the system without the account and deletes its home without following a planted
#     `~/link -> /etc`; its PIN, metadata, app profile links and published link are gone.
#   - Ids are never reused: the next profile is p4.
#   - The limit: with 8 accounts in the running state.json a create gives `profile_limit`.
#   - A profile removes itself with its own PIN (not with a wrong one); its session ends and the
#     picker comes back without it.
#   - From the picker: greeter.create makes p5 over greeter.sock, and its one-time token lets the
#     picker straight in (no PIN prompt for the new, locked profile).
# STUBBED: the system builds (the specialisations); the switches, users, homes and everything the
# jobs do after the build are real.
{ self, pkgs }:
let
  profiles = import ./system/profiles.nix { inherit self pkgs; };
  st =
    accounts:
    profiles.mkState {
      inherit accounts;
      guest = false;
    };
in
profiles.mkTest {
  name = "profiles-lifecycle";
  timeout = 3600;
  state = st [
    "p1"
    "p2"
  ];
  profiles = {
    p1 = {
      name = "James";
      admin = true;
      pin = "2468";
    };
    p2 = {
      name = "Sam";
      color = "orange";
      pin = "1357";
    };
  };
  overrides.youtube.kiosk.url = "file:///etc/hinteros-pages/youtube.html";
  envs.starter.ids = [
    "firefox"
    "youtube"
  ];
  appProfiles = {
    hinteros-p1 = "starter";
    hinteros-p2 = "starter";
  };
  starter = "starter";
  specialisations = {
    with-p3 = st [
      "p1"
      "p2"
      "p3"
    ];
    with-p4 = st [
      "p1"
      "p2"
      "p4"
    ];
    with-p5 = st [
      "p1"
      "p2"
      "p5"
    ];
  };

  testScript = ''
    systems = boot_box()
    APPS = "/nix/var/nix/profiles/hinteros/apps"

    def rev(user="hinteros-p1"):
        return sys_ok(user, "settings.get")["revision"]

    def ids_in_state():
        return [p["id"] for p in state_json()["profiles"]]

    def listed():
        return {p["id"]: p for p in sys_ok("hinteros-p1", "profiles.list")["profiles"]}

    def create(user, name, pin, system, **extra):
        stub_build(systems[system])
        # The launcher's update check at session start is a job of its own and may start at
        # any moment after enter() (jobs_idle cannot see it coming): job_busy while it runs.
        for _ in range(5):
            resp = sysrpc(user, "profiles.create", {"name": name, "pin": pin, "locked": False, "revision": rev(user), **extra})
            if resp.get("error", {}).get("code") != 3005:
                break
            jobs_idle(user)
        assert "result" in resp, (user, name, resp)
        r = resp["result"]
        done = wait_job(user, r["job_id"])
        assert done["state"] == "succeeded" and done["kind"] == "profiles_create", done
        return r["id"]

    def assert_gone(pid, user, home):
        machine.fail(f"id {user}")
        machine.fail(f"test -e {home}")
        machine.fail(f"ls /var/lib/hinteros/pins/{pid}*")
        machine.fail(f"test -e {APPS}/{user}")
        machine.fail(f"ls {APPS} | grep -q '^{user}-'")
        machine.fail(f"test -e /run/hinteros/apps/{user}")
        assert pid not in profiles_file()["profiles"]
        assert pid not in [p["id"] for p in public()["profiles"]]
        assert pid not in ids_in_state()
        reg = json.loads(machine.succeed("cat /var/lib/hinteros/apps/registry.json"))
        assert pid not in reg["owners"], reg

    enter("p1", "hinteros-p1")
    jobs_idle("hinteros-p1")
    starter = env_path("starter")
    assert machine.succeed("readlink -f /nix/var/nix/profiles/hinteros/starter").strip() == starter

    with subtest("create a profile from a session: a rebuild, the session stays"):
        cage = machine.succeed("pgrep -u hinteros-p1 -o -f '/bin/cage '").strip()
        launcher = machine.succeed("pgrep -u hinteros-p1 -o -f hinteros-launcher").strip()
        new = create("hinteros-p1", "Alex", "4444", "with-p3", color="purple")
        assert new == "p3", new
        assert current_system() == systems["with-p3"]
        assert ids_in_state() == ["p1", "p2", "p3"], state_json()
        assert machine.succeed("id -u hinteros-p3").strip() == "20003"
        assert set(machine.succeed("id -nG hinteros-p3").split()) == {"users", "hinteros"}
        assert machine.succeed("stat -c '%a %U' /home/hinteros-p3").strip() == "700 hinteros-p3"
        meta = profiles_file()["profiles"]["p3"]
        assert meta["name"] == "Alex" and meta["color"] == "purple" and not meta["admin"] and not meta["locked"], meta
        assert machine.succeed("stat -c '%a %U' /var/lib/hinteros/pins/p3").strip() == "600 hinteros-system"
        assert machine.succeed(f"readlink -f {APPS}/hinteros-p3").strip() == starter
        machine.wait_until_succeeds("test -L /run/hinteros/apps/hinteros-p3")
        assert "p3" in [p["id"] for p in public()["profiles"]]
        assert listed()["p3"]["user"] == "hinteros-p3"
        # Not a session restart: the same compositor and launcher.
        assert machine.succeed("pgrep -u hinteros-p1 -o -f '/bin/cage '").strip() == cage
        assert machine.succeed("pgrep -u hinteros-p1 -o -f hinteros-launcher").strip() == launcher

    with subtest("rename: another profile needs the admin PIN, yourself not"):
        r = sess("hinteros-p1", "system.profiles.rename", {"id": "p2", "name": "Samantha"})
        assert r["error"]["code"] == 3016 and r["error"]["data"] == {"pin": "admin"}, r
        r = sess("hinteros-p1", "system.profiles.rename", {"id": "p2", "name": "Samantha", "admin_pin": "1357"})
        assert r["error"]["code"] == 3016 and r["error"]["data"]["pin"] == "admin", r
        assert listed()["p2"]["name"] == "Sam"
        assert sess_ok("hinteros-p1", "system.profiles.rename", {"id": "p2", "name": "Samantha", "admin_pin": "2468"}) == {}
        assert sess_ok("hinteros-p1", "system.profiles.rename", {"id": "p1", "name": "Jim"}) == {}
        names = {p["id"]: p["name"] for p in public()["profiles"]}
        assert names["p1"] == "Jim" and names["p2"] == "Samantha", names
        # Display names are checked (no control characters, not empty).
        r = sess("hinteros-p1", "system.profiles.rename", {"id": "p1", "name": "   "})
        assert r["error"]["code"] == -32602, r

    with subtest("the admin profile cannot be removed"):
        for pin in ["2468", "0000"]:
            r = sess("hinteros-p1", "system.profiles.remove", {"id": "p1", "confirm_id": "p1", "pin": pin, "revision": rev()})
            assert r["error"]["code"] == -32602 and r["error"]["data"]["reason"] == "admin", r
        machine.succeed("id hinteros-p1")
        assert profiles_file()["profiles"]["p1"]["admin"] is True

    with subtest("remove p3 with the admin PIN: its processes, account and data are gone, /etc is not"):
        machine.succeed("runuser -u hinteros-p3 -- sh -c 'ln -s /etc ~/link && mkdir -p ~/.local/share/Steam && echo save > ~/.local/share/Steam/save'")
        machine.succeed("systemd-run --uid=hinteros-p3 --unit=p3-leftover sleep 1000")
        machine.wait_until_succeeds("pgrep -u hinteros-p3 -f 'sleep 1000'")
        # A file of p3's in /etc: deleting the home must not follow ~/link to it.
        machine.succeed("echo keep > /etc/p3-owned && chown hinteros-p3 /etc/p3-owned")
        r = sess("hinteros-p1", "system.profiles.remove", {"id": "p3", "confirm_id": "p2", "admin_pin": "2468", "revision": rev()})
        assert r["error"]["code"] == -32602, r
        r = sess("hinteros-p1", "system.profiles.remove", {"id": "p3", "confirm_id": "p3", "admin_pin": "4444", "revision": rev()})
        assert r["error"]["code"] == 3016 and r["error"]["data"]["pin"] == "admin", r
        stub_build(systems[""])
        r = sess_ok("hinteros-p1", "system.profiles.remove", {"id": "p3", "confirm_id": "p3", "admin_pin": "2468", "revision": rev()})
        done = wait_job("hinteros-p1", r["job_id"])
        assert done["state"] == "succeeded" and done["kind"] == "profiles_remove", done
        assert current_system() == systems[""]
        machine.fail("pgrep -u 20003")
        machine.fail("systemctl is-active p3-leftover.service")
        assert_gone("p3", "hinteros-p3", "/home/hinteros-p3")
        assert machine.succeed("cat /etc/p3-owned") == "keep\n"
        machine.succeed("test -s /etc/hinteros/state.json && test -s /etc/passwd")
        assert set(listed()) == {"p1", "p2"}

    with subtest("ids are never reused: the next profile is p4"):
        assert create("hinteros-p1", "Bea", "5555", "with-p4") == "p4"
        assert machine.succeed("id -u hinteros-p4").strip() == "20004"
        assert profiles_file()["next"] == 5, profiles_file()

    with subtest("at most 8 profiles"):
        machine.succeed("cp /etc/hinteros/state.json /root/state.json")
        machine.succeed(
            "jq -c '.profiles = ([\"p1\",\"p2\",\"p4\",\"p5\",\"p6\",\"p7\",\"p8\",\"p9\"] "
            "| map({id: .}))' "
            "/root/state.json > /etc/hinteros/state.json"
        )
        assert len(ids_in_state()) == 8
        r = sysrpc("hinteros-p1", "profiles.create", {"name": "Nine", "pin": "9999", "locked": False, "revision": rev()})
        assert r["error"]["code"] == 3015 and r["error"]["data"] == {"max": 8}, r
        machine.succeed("cp /root/state.json /etc/hinteros/state.json")
        assert ids_in_state() == ["p1", "p2", "p4"]
        # Nothing was created or reserved by the refusal.
        assert profiles_file()["next"] == 5, profiles_file()

    with subtest("a profile removes itself with its own PIN; the picker comes back without it"):
        switch("hinteros-p1", "p4", "hinteros-p4")
        r = sess("hinteros-p4", "system.profiles.remove", {"id": "p4", "confirm_id": "p4", "pin": "2468", "revision": rev("hinteros-p4")})
        assert r["error"]["code"] == 3016 and r["error"]["data"] == {"pin": "self"}, r
        r = sess("hinteros-p4", "system.profiles.remove", {"id": "p4", "confirm_id": "p4", "revision": rev("hinteros-p4")})
        assert r["error"]["code"] == 3016 and r["error"]["data"] == {"pin": "self"}, r
        stub_build(systems[""])
        # p4's launcher runs its update check at session start: wait it out, as create() does.
        for _ in range(5):
            resp = sess("hinteros-p4", "system.profiles.remove", {"id": "p4", "confirm_id": "p4", "pin": "5555", "revision": rev("hinteros-p4")})
            if resp.get("error", {}).get("code") != 3005:
                break
            jobs_idle("hinteros-p4")
        assert "result" in resp, resp
        r = resp["result"]
        # The job ends the session first (as a switch does); follow it as p1 (read-only).
        done = wait_job("hinteros-p1", r["job_id"])
        assert done["state"] == "succeeded", done
        assert_gone("p4", "hinteros-p4", "/home/hinteros-p4")
        picker_up()
        assert [p["id"] for p in greeter_call("greeter.list")["result"]["profiles"]] == ["p1", "p2"]

    with subtest("Add profile at the picker: over greeter.sock, then straight in"):
        stub_build(systems["with-p5"])
        r = greeter_call("greeter.create", {"name": "Cat", "color": "green", "pin": "6666", "locked": True})
        assert "result" in r and r["result"]["id"] == "p5", r
        done = wait_job("hinteros-p1", r["result"]["job_id"])
        assert done["state"] == "succeeded" and done["kind"] == "profiles_create", done
        assert machine.succeed("id -u hinteros-p5").strip() == "20005"
        assert public()["next"]["target"] == "p5" and public()["next"]["fast"] is True, public()
        # The new profile is locked, but its one-time token lets the picker in without a PIN.
        g = greeter("p5")
        assert len(g["outcomes"]) == 1 and g["outcomes"][0]["ok"] is True, g
        session_of("hinteros-p5")
        cur = sess_ok("hinteros-p5", "profile.current")
        assert cur["id"] == "p5" and cur["locked"] and cur["pin_set"], cur
        assert machine.succeed(f"readlink -f {APPS}/hinteros-p5").strip() == starter
  '';
}
