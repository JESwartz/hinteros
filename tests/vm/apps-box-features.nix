# Box features follow the apps that need them (apps.md "Box requirements"; build plan step 6, VM
# `apps-box-features`). Greeter mode; p1 = `hinteros` (James, admin, unlocked) and p2 =
# `hinteros-p2` (Sam, unlocked), both without apps; state.json `requirements: []`. Steam is the
# catalog's entry (box = [graphics32, steam-devices], vendor terms) with the fake Steam as its
# package.
#   - p1 installs Steam (terms accepted): the job's `box` stage turns both features on with
#     exactly one rebuild (state.json `requirements`, 32-bit graphics drivers, Valve's udev rules),
#     then p1's env has Steam.
#   - p2 installs Steam too: no rebuild (the features are on), same system generation.
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
    hinteros = "empty";
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
        on32 = machine.execute("grep -Rqs opengl-driver-32 /etc/tmpfiles.d/")[0] == 0
        udev = machine.execute("grep -Rqs 28de /etc/udev/rules.d/")[0] == 0
        return on32, udev

    def install_steam(user):
        mine = sys_ok(user, "apps.list")
        e = sys_err(user, "apps.install", {"ids": ["steam"], "revision": mine["revision"]}, 3014)
        assert e["data"]["id"] == "steam", e
        version = e["data"]["version"]
        j = sys_ok(user, "apps.install", {"ids": ["steam"], "revision": mine["revision"], "accepted_terms": {"steam": version}})["job_id"]
        done = wait_job(user, j)
        assert done["state"] == "succeeded" and done["kind"] == "apps_install", done
        return version

    def remove_steam(user):
        mine = sys_ok(user, "apps.list")
        j = sys_ok(user, "apps.remove", {"ids": ["steam"], "revision": mine["revision"]})["job_id"]
        done = wait_job(user, j)
        assert done["state"] == "succeeded" and done["kind"] == "apps_remove", done

    enter("p1", "hinteros")
    jobs_idle("hinteros")
    gens0 = system_generations()

    with subtest("before: no features"):
        assert state_json()["requirements"] == []
        assert features_on() == (False, False), features_on()
        assert sys_ok("hinteros", "apps.list")["box"] == []

    with subtest("p1 installs Steam: the box stage turns the features on with one rebuild"):
        stub_build(systems["box"])
        version = install_steam("hinteros")
        assert state_json()["requirements"] == FEATURES, state_json()
        assert current_system() == systems["box"]
        assert system_generations() == gens0 + 1
        assert len(builds()) == 1, builds()
        assert features_on() == (True, True), features_on()
        assert machine.succeed("readlink -f /nix/var/nix/profiles/hinteros/apps/hinteros").strip() == env_path("steam")
        m = json.loads(machine.succeed("cat /run/hinteros/apps/hinteros/share/hinteros/apps.json"))
        assert m["box"] == FEATURES and m["steam"] is not None, m
        assert sys_ok("hinteros", "apps.list")["box"] == FEATURES
        terms = json.loads(machine.succeed("cat /var/lib/hinteros/terms-accepted.json"))
        assert "steam" in json.dumps(terms) and version in json.dumps(terms), terms

    with subtest("p2 installs Steam too: no rebuild"):
        switch("hinteros", "p2", "hinteros-p2")
        install_steam("hinteros-p2")
        assert len(builds()) == 1, builds()
        assert system_generations() == gens0 + 1
        assert current_system() == systems["box"]
        assert machine.succeed("readlink -f /nix/var/nix/profiles/hinteros/apps/hinteros-p2").strip() == env_path("steam")

    with subtest("removing Steam everywhere leaves the features on until a rebuild"):
        remove_steam("hinteros-p2")
        assert state_json()["requirements"] == FEATURES
        switch("hinteros-p2", "p1", "hinteros")
        remove_steam("hinteros")
        assert machine.succeed("readlink -f /nix/var/nix/profiles/hinteros/apps/hinteros").strip() == env_path("empty")
        assert state_json()["requirements"] == FEATURES, state_json()
        assert len(builds()) == 1, builds()
        assert system_generations() == gens0 + 1
        assert features_on() == (True, True)

    with subtest("the next system job that rebuilds anyway drops them"):
        stub_build(systems[""])
        j = sys_ok("hinteros", "rebuild")["job_id"]
        done = wait_job("hinteros", j)
        assert done["state"] == "succeeded", done
        assert state_json()["requirements"] == [], state_json()
        assert current_system() == systems[""]
        assert features_on() == (False, False), features_on()
  '';
}
