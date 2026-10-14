# A box from the old (schema-1) installer gets the M7 system (profiles.md "Migration from
# today's single user", DECISIONS D11, I2; VM `profiles-migration`). Its state.json is what that
# installer wrote: `apps` (Firefox, YouTube) and `profiles: []`, autologin of `hinteros` with the
# static device groups, and a Steam library in its home.
#   - At once (before the migration job is done): profiles.json names p1 "Profile 1", the admin
#     profile, unlocked, without a PIN; on schema 1
#     profiles.list reports p1's PIN as set and set_pin is `unavailable {reason: schema1}`.
#   - The migration job moves state.json to schema 2 ({id, user} profiles, no `apps`) and switches:
#     same uid, home and Steam files (same inodes), the static groups (video, input, uinput) gone,
#     p1's apps and the starter env are the box's old apps; the public view lists "Profile 1"
#     and is not in first-boot mode.
#   - The next greeter (greetd restarted, as at the next boot) shows the picker with "Profile 1";
#     it enters without a PIN, and its session asks for one ("Set your PIN": pin_set false, not
#     first-boot mode); the first PIN needs no current PIN, every later change does.
# STUBBED (as in apps-migration): the env evaluation/build and the system build, which prints the
# `migrated` specialisation (this system with the schema-2 state the migration writes).
{ self, pkgs }:
let
  profiles = import ./system/profiles.nix { inherit self pkgs; };
  ids = [
    "firefox"
    "youtube"
  ];
in
profiles.mkTest {
  name = "profiles-migration";
  timeout = 2400;
  state = {
    schemaVersion = 1;
    base = "unstable";
    settings.ssh.enable = false;
    apps = ids;
    profiles = [ ];
  };
  overrides.youtube.kiosk.url = "file:///etc/hinteros-pages/youtube.html";
  envs.box.ids = ids;
  specialisations.migrated = profiles.mkState {
    accounts = [ "p1" ];
    guest = true;
  };
  extraModule = {
    # The migration's system build waits until the test has seen the box before it.
    systemd.services.stub-toplevel = {
      wantedBy = [ "hinteros-system.service" ];
      before = [ "hinteros-system.service" ];
      after = [ "hinteros-test-setup.service" ];
      serviceConfig.Type = "oneshot";
      script = ''
        mkdir -p /run/stub
        touch /run/stub/hold
        if [ -e /run/current-system/specialisation/migrated ]; then
          readlink -f /run/current-system/specialisation/migrated > /run/stub/toplevel
        fi
      '';
    };
  };

  testScript = ''
    systems = boot_box()
    STEAM = "/home/hinteros/.local/share/Steam"
    env = env_path("box")

    with subtest("before: schema 1, autologin with static groups; p1 is named at once"):
        machine.wait_until_succeeds(f"test -S {sock('hinteros')}", timeout=180)
        st = state_json()
        assert st["schemaVersion"] == 1 and st["profiles"] == [] and st["apps"] == ["firefox", "youtube"], st
        u = uid("hinteros")
        groups = set(machine.succeed("id -nG hinteros").split())
        assert {"video", "input", "uinput"} <= groups, groups
        machine.succeed(
            f"runuser -u hinteros -- sh -c 'mkdir -p {STEAM}/steamapps/common/Game {STEAM}/config && "
            f"echo acf > {STEAM}/steamapps/appmanifest_620.acf && echo bin > {STEAM}/steamapps/common/Game/game && "
            f"echo login > {STEAM}/config/loginusers.vdf'"
        )
        inodes = machine.succeed(f"find {STEAM} -type f -printf '%i %p\\n' | sort")
        machine.wait_until_succeeds("test -e /var/lib/hinteros/profiles.json", timeout=60)
        p1 = profiles_file()["profiles"]["p1"]
        assert p1["name"] == "Profile 1" and p1["admin"] is True and p1["locked"] is False, p1
        machine.fail("test -e /var/lib/hinteros/pins/p1")
        # (The public view is not republished when profiles.json is created here, only by the
        # migration job: a daemon gap without effect on a schema-1 box, which has no greeter;
        # it is checked after the migration below.)
        print(public())
        listed = sys_ok("hinteros", "profiles.list")
        assert [(p["id"], p["pin_set"]) for p in listed["profiles"]] == [("p1", True)], listed
        r = sysrpc("hinteros", "profiles.set_pin", {"pin": "2468"})
        assert r["error"]["code"] == 4001 and r["error"]["data"]["reason"] == "schema1", r
        assert current_system() == systems[""]
        machine.succeed("rm /run/stub/hold")

    with subtest("the migration: schema 2, same user, home and Steam files, no static groups"):
        machine.wait_until_succeeds("grep -Eq '\"schemaVersion\": *2' /etc/hinteros/state.json", timeout=600)
        machine.wait_until_succeeds(f"test \"$(readlink -f /run/current-system)\" = {systems['migrated']}", timeout=600)
        st = state_json()
        assert "apps" not in st and st["profiles"] == [{"id": "p1", "user": "hinteros"}], st
        assert uid("hinteros") == u
        groups = set(machine.succeed("id -nG hinteros").split())
        assert not groups & {"video", "input", "uinput", "inputplumber", "wheel"}, groups
        assert "hinteros" in groups, groups
        assert machine.succeed("stat -c '%a %U' /home/hinteros").strip() == "700 hinteros"
        assert machine.succeed(f"find {STEAM} -type f -printf '%i %p\\n' | sort") == inodes
        assert machine.succeed(f"cat {STEAM}/config/loginusers.vdf") == "login\n"
        assert machine.succeed("readlink -f /nix/var/nix/profiles/hinteros/apps/hinteros").strip() == env
        assert machine.succeed("readlink -f /nix/var/nix/profiles/hinteros/starter").strip() == env
        assert profiles_file()["profiles"]["p1"]["name"] == "Profile 1"
        listed = sys_ok("hinteros", "profiles.list")
        assert [(p["id"], p["name"], p["admin"], p["pin_set"]) for p in listed["profiles"]] == [("p1", "Profile 1", True, False)], listed
        assert listed["first_boot"] is False, listed
        pub = public()
        assert [(p["id"], p["name"], p["admin"], p["locked"]) for p in pub["profiles"]] == [("p1", "Profile 1", True, False)], pub
        assert pub["first_boot"] is False and pub["spare"] is None, pub

    with subtest("the picker shows Profile 1; it enters without a PIN and is asked for one"):
        # The switch kept the autologin session (greetd is not restarted by a switch); a new
        # greetd is what the next boot runs.
        machine.succeed("systemctl restart greetd.service")
        picker_up()
        listed = greeter_call("greeter.list")["result"]
        assert [(p["id"], p["name"], p["admin"], p["locked"]) for p in listed["profiles"]] == [("p1", "Profile 1", True, False)], listed
        assert listed["first_boot"] is False, listed
        g = greeter("p1")
        assert len(g["outcomes"]) == 1 and g["outcomes"][0]["ok"] is True, g
        session_of("hinteros")
        cur = sess_ok("hinteros", "profile.current")
        assert cur["id"] == "p1" and cur["name"] == "Profile 1" and cur["admin"], cur
        assert cur["pin_set"] is False and cur["setup_required"] is False, cur
        # "Set your PIN": no current PIN the first time...
        assert sess_ok("hinteros", "system.profiles.set_pin", {"pin": "2468"}) == {}
        assert sess_ok("hinteros", "profile.current")["pin_set"] is True
        assert machine.succeed("stat -c '%a %U' /var/lib/hinteros/pins/p1").strip() == "600 root"
        # ...and from then on it is needed.
        r = sess("hinteros", "system.profiles.set_pin", {"pin": "1111"})
        assert r["error"]["code"] == 3016 and r["error"]["data"] == {"pin": "self"}, r
        assert sess_ok("hinteros", "system.profiles.set_pin", {"pin": "1111", "current_pin": "2468"}) == {}
        # Still unlocked: the picker does not ask (the PIN guards changes, not the entry).
        machine.succeed("env PAM_USER=hinteros hinteros-system pin unlocked")
  '';
}
