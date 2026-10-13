# The guest (profiles.md "Guest", apps.md "Where it lives"; build plan step 9, VM `guest`).
# Greeter mode; p1 = `hinteros` (James, admin, unlocked); the starter set is Firefox + YouTube.
#   - The guest starts with the starter env (its link under /run points straight at it), enters
#     from the picker without a PIN, has no PIN, is never admin, and cannot do admin actions
#     without the admin PIN.
#   - It installs Moonlight (an env only it has, in the store but in no system closure) and
#     writes files in its home.
#   - End guest session goes back to the picker.
#   - After a reboot its home is empty (the boot's tmpfiles `D!`), the link no longer names its
#     env (it starts from the starter set again), and a GC removes the guest-only env and
#     Moonlight while the starter env stays.
# TODO(guest.end): the immediate wipe when the guest session ends (DECISIONS D19: today only at the
# next boot). Once hinteros-system has `guest.end`, assert in "End guest session" below: the home
# is empty right away, /run/hinteros/apps/hinteros-guest points at the starter env again, and a
# GC then removes the guest-only paths without a reboot.
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
  appProfiles.hinteros = "starter";
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

    with subtest("End guest session: back to the picker"):
        assert sess_ok("hinteros-guest", "session.end_guest") == {}
        machine.wait_until_fails("pgrep -u hinteros-guest -f '/bin/cage '", timeout=90)
        picker_up()
        machine.wait_until_fails("pgrep -u hinteros-guest", timeout=30)
        # TODO(guest.end): with the immediate wipe, also assert here (see the header):
        #   machine.succeed(f"test -z \"$(ls -A {HOME})\"")
        #   assert machine.succeed(f"readlink -f {LINK}").strip() == starter

    with subtest("after a reboot: an empty home, the starter set again, and the GC frees the guest's apps"):
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("hinteros-system.service")
        assert machine.succeed(f"stat -c '%a %U' {HOME}").strip() == "700 hinteros-guest"
        assert machine.succeed(f"ls -A {HOME}").strip() == "", machine.succeed(f"ls -lA {HOME}")
        # The link is gone with /run; the service gives the starter env again.
        machine.wait_until_succeeds(f"test -L {LINK}", timeout=120)
        assert machine.succeed(f"readlink -f {LINK}").strip() == starter
        jobs_idle("hinteros")
        machine.succeed("nix-store --gc")
        machine.fail(f"test -e {guest_env}")
        machine.fail(f"test -e {moonlight}")
        machine.succeed(f"test -e {starter}")
        # The guest enters as new.
        picker_up()
        g = greeter("guest")
        assert g["outcomes"][-1]["ok"] is True, g
        session_of("hinteros-guest")
        ids = {a["id"] for a in sess_ok("hinteros-guest", "apps.list")["apps"]}
        assert "moonlight" not in ids and {"firefox", "youtube"} <= ids, ids
  '';
}
