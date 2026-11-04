# Box features follow the apps that need them (apps.md "Box requirements"; build plan step 6, VM
# `apps-box-features`). Greeter mode; p1 = `hinteros-p1` (James, admin, unlocked) and p2 =
# `hinteros-p2` (Sam, unlocked), both without apps; state.json `requirements: []`. Steam is the
# catalog's entry (box = [graphics32, steam-devices], vendor terms) with the fake Steam as its
# package.
#   - p1 installs Steam (terms accepted): the job's `box` stage turns both features on with
#     exactly one rebuild (state.json `requirements`, 32-bit graphics drivers, Valve's udev rules),
#     then p1's env has Steam.
#   - p2 installs Steam too: no rebuild (the features are on), same system generation.
#   - A rollback (admin PIN) to the generation before the features turns them back on in a
#     `box` stage (generations.list `readds_features`, job result `features_readded`).
#   - Both remove Steam: the features stay on (no rebuild only to drop them).
#   - The next system job that rebuilds anyway (`rebuild`) drops them: requirements [] and the
#     32-bit drivers and udev rules gone.
# STUBBED: the env builds (prebuilt) and the system builds (the `box` specialisation, then this
# system again); the switches, state.json, the app profiles and the registry are real.
{ self, pkgs }:
let
  profiles = import ./system/profiles.nix { inherit self pkgs; };
  st =
    requirements:
    profiles.mkState {
      accounts = [
        "p1"
        "p2"
      ];
      inherit requirements;
      guest = false;
    };
in
profiles.mkTest {
  name = "apps-box-features";
  timeout = 2400;
  state = st [ ];
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
  # The fake Steam stands in for the real client (the node's pkgs carry the overlay).
  extraModule =
    { pkgs, ... }:
    {
      hinteros.appEnv.overrides.steam.package = pkgs.hinteros-fake-steam;
    };
  envs = {
    empty.ids = [ ];
    steam.ids = [ "steam" ];
  };
  appProfiles = {
    hinteros-p1 = "empty";
    hinteros-p2 = "empty";
  };
  specialisations.box = st [
    "graphics32"
    "steam-devices"
  ];

  testScript = ''
    systems = boot_box()
    FEATURES = ["graphics32", "steam-devices"]

    def builds():
        # The stub's system builds (env builds name a .drv).
        log = machine.succeed("cat /run/stub/nix.log 2>/dev/null || true")
        return [l for l in log.splitlines() if "system.build.toplevel" in l]

    def features_on():
        # The 32-bit driver link as the running generation declares it (a stale /run link stays
        # until a reboot), and Valve's udev rules (vendor 28de).
        # (without the feature NixOS has an `r` rule for the same path)
        on32 = machine.execute("grep -RqsF \"'L+' '/run/opengl-driver-32'\" /etc/tmpfiles.d/")[0] == 0
        udev = machine.execute("grep -Rqs 28de /etc/udev/rules.d/")[0] == 0
        return on32, udev

    def install_steam(user):
        mine = sys_ok(user, "apps.list")
        e = sys_err(user, "apps.install", {"ids": ["steam"], "revision": mine["revision"]}, 3014)
        assert e["data"]["id"] == "steam", e
        version = e["data"]["version"]
        j = start_job(user, "apps.install", {"ids": ["steam"], "revision": mine["revision"], "accepted_terms": {"steam": version}})
        done = wait_job(user, j)
        assert done["state"] == "succeeded" and done["kind"] == "apps_install", done
        return version

    def remove_steam(user):
        mine = sys_ok(user, "apps.list")
        j = start_job(user, "apps.remove", {"ids": ["steam"], "revision": mine["revision"], "delete_data": False})
        done = wait_job(user, j)
        assert done["state"] == "succeeded" and done["kind"] == "apps_remove", done

    enter("p1", "hinteros-p1")
    jobs_idle("hinteros-p1")
    gens0 = system_generations()

    with subtest("before: no features"):
        assert state_json()["requirements"] == []
        assert features_on() == (False, False), features_on()
        assert sys_ok("hinteros-p1", "apps.list")["box"] == []

    with subtest("p1 installs Steam: the box stage turns the features on with one rebuild"):
        stub_build(systems["box"])
        version = install_steam("hinteros-p1")
        assert state_json()["requirements"] == FEATURES, state_json()
        assert current_system() == systems["box"]
        assert system_generations() == gens0 + 1
        assert len(builds()) == 1, builds()
        assert features_on() == (True, True), features_on()
        assert machine.succeed("readlink -f /nix/var/nix/profiles/hinteros/apps/hinteros-p1").strip() == env_path("steam")
        m = json.loads(machine.succeed("cat /run/hinteros/apps/hinteros-p1/share/hinteros/apps.json"))
        assert m["box"] == FEATURES and m["steam"] is not None, m
        assert sys_ok("hinteros-p1", "apps.list")["box"] == FEATURES
        terms = json.loads(machine.succeed("cat /var/lib/hinteros/terms-accepted.json"))["accepted"]
        assert "steam" in json.dumps(terms) and version in json.dumps(terms), terms

    with subtest("p2 installs Steam too: no rebuild"):
        switch("hinteros-p1", "p2", "hinteros-p2")
        install_steam("hinteros-p2")
        assert len(builds()) == 1, builds()
        assert system_generations() == gens0 + 1
        assert current_system() == systems["box"]
        assert machine.succeed("readlink -f /nix/var/nix/profiles/hinteros/apps/hinteros-p2").strip() == env_path("steam")

    with subtest("a rollback to before the features turns them back on (box stage)"):
        gens = sys_ok("hinteros-p2", "generations.list")["generations"]
        old = [g for g in gens if not g["current"]]
        assert len(old) == 1, gens
        assert old[0].get("readds_features") == FEATURES, gens
        # A box-wide action: the admin PIN.
        e = sys_err("hinteros-p2", "rollback", {"generation": old[0]["generation"]}, 3016)
        assert e["data"] == {"pin": "admin"}, e
        stub_build(systems["box"])
        j = start_job("hinteros-p2", "rollback", {"generation": old[0]["generation"], "admin_pin": "2468"})
        done = wait_job("hinteros-p2", j)
        assert done["state"] == "succeeded" and done["kind"] == "rollback", done
        assert done["result"]["features_readded"] == FEATURES, done
        assert current_system() == systems["box"]
        assert state_json()["requirements"] == FEATURES, state_json()
        assert features_on() == (True, True), features_on()
        assert len(builds()) == 2, builds()
        # The box stage's system is the newest generation's (nix-env reuses it, no new one).
        assert system_generations() == gens0 + 1, machine.succeed("nix-env -p /nix/var/nix/profiles/system --list-generations")

    with subtest("removing Steam everywhere leaves the features on until a rebuild"):
        remove_steam("hinteros-p2")
        assert state_json()["requirements"] == FEATURES
        switch("hinteros-p2", "p1", "hinteros-p1")
        remove_steam("hinteros-p1")
        assert machine.succeed("readlink -f /nix/var/nix/profiles/hinteros/apps/hinteros-p1").strip() == env_path("empty")
        assert state_json()["requirements"] == FEATURES, state_json()
        assert len(builds()) == 2, builds()
        assert system_generations() == gens0 + 1
        assert features_on() == (True, True)

    with subtest("the next system job that rebuilds anyway drops them"):
        stub_build(systems[""])
        j = start_job("hinteros-p1", "rebuild")
        done = wait_job("hinteros-p1", j)
        assert done["state"] == "succeeded", done
        assert state_json()["requirements"] == [], state_json()
        assert current_system() == systems[""]
        assert features_on() == (False, False), features_on()
  '';
}
