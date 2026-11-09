# The guest (VM `guest`).
# Greeter mode; p1 = `hinteros-p1` (James, admin, unlocked); the starter set is Firefox + YouTube.
#   - The guest starts with the starter env (its link under /run points straight at it), enters
#     from the picker without a PIN, has no PIN, is never admin, and cannot do admin actions
#     without the admin PIN.
#   - It installs Moonlight (an env only it has, in the store but in no system closure) and
#     writes files in its home.
#   - End guest session (session.end_guest -> system guest.end) wipes the guest at once, without a
#     reboot: the session ends, the home is emptied, its /tmp and /dev/shm files, terms records and
#     usage entry go, the link is the starter env again (a GC then frees the guest-only env and
#     Moonlight while the starter env stays), and the next guest starts as new. Only the guest may
#     end the guest session.
#   - The safety net: after a reboot the home is empty too (the boot's tmpfiles `D!`) and the link
#     is the starter env again.
{ self, pkgs }:
let
  profiles = import ./system/profiles.nix { inherit self pkgs; };
in
profiles.mkTest {
  name = "guest";
  timeout = 2400;
  state = profiles.mkState {
    accounts = [ "p1" ];
    guest = true;
  };
  profiles.p1 = {
    name = "James";
    admin = true;
    pin = "2468";
  };
  overrides.youtube.kiosk.url = "file:///etc/hinteros-pages/youtube.html";
  envs = {
    starter.ids = [
      "firefox"
      "youtube"
    ];
    # Only the guest will have it: in the VM's store, not kept alive by the system.
    guest = {
      ids = [
        "firefox"
        "moonlight"
        "youtube"
      ];
      rooted = false;
    };
  };
  appProfiles.hinteros-p1 = "starter";
  starter = "starter";

  testScript = ''
    boot_box()
    LINK = "/run/hinteros/apps/hinteros-guest"
    HOME = "/home/hinteros-guest"
    starter = env_path("starter")
    guest_env = env_path("guest")
    moonlight = machine.succeed(f"readlink -f {guest_env}/bin/moonlight").strip()
    moonlight = "/".join(moonlight.split("/")[:4])

    with subtest("the guest starts with the starter set, without a PIN"):
        # The service gives the guest the starter env when the box is idle.
        machine.wait_until_succeeds(f"test -L {LINK}", timeout=120)
        assert machine.succeed(f"readlink -f {LINK}").strip() == starter
        picker_up()
        assert public()["guest"]["enabled"] is True, public()
        g = greeter("guest")
        assert len(g["outcomes"]) == 1 and g["outcomes"][0]["ok"] is True, g
        session_of("hinteros-guest")
        cur = sess_ok("hinteros-guest", "profile.current")
        assert cur["guest"] and cur["id"] is None and not cur["admin"] and not cur["pin_set"], cur
        for _ in range(30):
            if {"firefox", "youtube"} <= {a["id"] for a in sess_ok("hinteros-guest", "apps.list")["apps"]}:
                break
            machine.sleep(1)
        assert {"firefox", "youtube"} <= {a["id"] for a in sess_ok("hinteros-guest", "apps.list")["apps"]}
        # Admin actions: only with the admin PIN (the PIN is the authority, not the profile).
        r = sess("hinteros-guest", "system.profiles.rename", {"id": "p1", "name": "Guest was here"})
        assert r["error"]["code"] == 3016 and r["error"]["data"]["pin"] == "admin", r
        r = sess("hinteros-guest", "system.profiles.set_pin", {"pin": "1234"})
        assert "error" in r, r

    with subtest("the guest installs an app and writes files"):
        mine = sys_ok("hinteros-guest", "apps.list")
        assert mine["ids"] == ["firefox", "youtube"], mine
        # The session checks for updates when it starts: that job holds the queue for a moment.
        for _ in range(60):
            if not [x for x in sys_ok("hinteros-guest", "jobs.list")["jobs"] if x["state"] == "running"]:
                break
            machine.sleep(1)
        j = sys_ok("hinteros-guest", "apps.install", {"ids": ["moonlight"], "revision": mine["revision"]})["job_id"]
        done = wait_job("hinteros-guest", j)
        assert done["state"] == "succeeded", done
        assert machine.succeed(f"readlink -f {LINK}").strip() == guest_env
        # A temporary root under /run, not a profile under /nix/var.
        machine.fail("test -e /nix/var/nix/profiles/hinteros/apps/hinteros-guest")
        for _ in range(30):
            if "moonlight" in [a["id"] for a in sess_ok("hinteros-guest", "apps.list")["apps"]]:
                break
            machine.sleep(1)
        assert "moonlight" in [a["id"] for a in sess_ok("hinteros-guest", "apps.list")["apps"]]
        machine.succeed(
            "runuser -u hinteros-guest -- sh -c 'echo note > ~/notes.txt && mkdir -p ~/.local/share/Steam && echo login > ~/.local/share/Steam/login'"
        )
        # The starter set itself is unchanged.
        assert machine.succeed("readlink -f /nix/var/nix/profiles/hinteros/starter").strip() == starter

    with subtest("End guest session: wiped at once, no reboot"):
        # What the wipe must remove beside the home: the guest's terms acceptances (a record of
        # p1's stays), its usage entry, its files in /tmp and /dev/shm (root's stay).
        machine.succeed(
            "f=/var/lib/hinteros/terms-accepted.json; [ -e $f ] || echo '{\"version\": 1, \"accepted\": {}}' > $f; "
            "jq '.accepted.steam = [{\"version\": \"v1\", \"accepted_at\": \"2026-10-13T00:00:00Z\", \"by\": \"hinteros-guest\"}, "
            "{\"version\": \"v1\", \"accepted_at\": \"2026-10-13T00:00:00Z\", \"by\": \"hinteros-p1\", \"profile\": \"p1\"}]' "
            "$f > $f.new && mv $f.new $f && chmod 0600 $f && chown hinteros-system:hinteros $f"
        )
        machine.succeed("systemctl start hinteros-usage.service")
        assert "guest" in json.loads(machine.succeed("cat /var/lib/hinteros/usage.json"))["data"], machine.succeed("cat /var/lib/hinteros/usage.json")
        machine.succeed("runuser -u hinteros-guest -- sh -c 'echo x > /tmp/guest-left && echo x > /dev/shm/guest-shm'")
        machine.succeed("echo keep > /tmp/root-keeps")
        # Only the guest may end the guest session.
        sys_err("hinteros-p1", "guest.end", {}, 3002)
        assert sess_ok("hinteros-guest", "session.end_guest") == {}
        machine.wait_until_fails("pgrep -u hinteros-guest -f '/bin/cage '", timeout=90)
        picker_up()
        machine.wait_until_fails("pgrep -u hinteros-guest", timeout=30)
        job = None
        for _ in range(120):
            jobs = [j for j in sys_ok("hinteros-p1", "jobs.list")["jobs"] if j["kind"] == "guest_end"]
            if jobs and jobs[-1]["state"] != "running":
                job = jobs[-1]
                break
            machine.sleep(1)
        assert job is not None and job["state"] == "succeeded", job
        assert machine.succeed(f"stat -c '%a %U' {HOME}").strip() == "700 hinteros-guest"
        assert machine.succeed(f"ls -A {HOME}").strip() == "", machine.succeed(f"ls -lA {HOME}")
        assert machine.succeed(f"readlink -f {LINK}").strip() == starter
        machine.fail("test -e /tmp/guest-left")
        machine.fail("test -e /dev/shm/guest-shm")
        assert machine.succeed("cat /tmp/root-keeps") == "keep\n"
        terms = json.loads(machine.succeed("cat /var/lib/hinteros/terms-accepted.json"))["accepted"]
        assert [r["by"] for r in terms.get("steam", [])] == ["hinteros-p1"], terms
        assert "guest" not in json.loads(machine.succeed("cat /var/lib/hinteros/usage.json"))["data"]
        machine.fail("test -e /run/hinteros/guest-ending")
        assert public()["guest"]["enabled"] is True, public()
        assert greeter_call("greeter.list")["result"]["guest"], greeter_call("greeter.list")
        # The guest-only apps are garbage now, without a reboot.
        jobs_idle("hinteros-p1")
        machine.succeed("nix-store --gc")
        machine.fail(f"test -e {guest_env}")
        machine.fail(f"test -e {moonlight}")
        machine.succeed(f"test -e {starter}")
        # The next guest starts as new.
        g = greeter("guest")
        assert g["outcomes"][-1]["ok"] is True, g
        session_of("hinteros-guest")
        ids = {a["id"] for a in sess_ok("hinteros-guest", "apps.list")["apps"]}
        assert "moonlight" not in ids and {"firefox", "youtube"} <= ids, ids
        machine.succeed("runuser -u hinteros-guest -- sh -c 'echo again > ~/again.txt'")

    with subtest("the safety net: a reboot empties the home too"):
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("hinteros-system.service")
        assert machine.succeed(f"stat -c '%a %U' {HOME}").strip() == "700 hinteros-guest"
        assert machine.succeed(f"ls -A {HOME}").strip() == "", machine.succeed(f"ls -lA {HOME}")
        # The link is gone with /run; the service gives the starter env again.
        machine.wait_until_succeeds(f"test -L {LINK}", timeout=120)
        assert machine.succeed(f"readlink -f {LINK}").strip() == starter
        picker_up()
        g = greeter("guest")
        assert g["outcomes"][-1]["ok"] is True, g
        session_of("hinteros-guest")
  '';
}
