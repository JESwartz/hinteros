# The Jellyfin app signs in to the box's own Jellyfin server by itself (design/server.md, spike S1
# "seed page"). Greeter mode, `jellyfin-server` on from boot, p1 (`hinteros-p1`, admin) has the
# Jellyfin app (jellyfin-desktop, Qt WebEngine, in the app sandbox, software rendering), p2 has
# none.
#   - Jellyfin serves the seed page /web/hinteros/signin.html (+ signin.js) from the web
#     directory bound over its own, and the rest of jellyfin-web still;
#   - apps.launch jellyfin-desktop from p1's session: the session daemon gets p1's token
#     (system.jellyfin.client_token) and writes the client's settings in the app's sandbox home
#     (profiles.json, profiles/<id>/jellyfin-desktop.conf version 7: the seed URL, the server,
#     the TV layout; 0600); the client opens the seed page, which stores jellyfin-web's login;
#   - pass: within 90 s Jellyfin's /Sessions (admin API key) has a session of device
#     `hinteros-p1` for p1's Jellyfin user that reports what it plays (the web client's; the
#     token's own sign-in has none), and there is no `jellyfin-desktop.conf.broken`;
#   - the token is not in the journal; p2 cannot read p1's app settings;
#   - started again (the app wrote its settings back in between), only our keys change and the
#     app signs in again.
# STUBBED: nothing; no system builds (no jobs).
{ self, pkgs }:
let
  profiles = import ./system/profiles.nix { inherit self pkgs; };
in
profiles.mkTest {
  name = "server-jellyfin-signin";
  timeout = 3600;
  state = profiles.mkState {
    services = [ "jellyfin-server" ];
  };
  profiles = {
    p1 = {
      name = "James";
      admin = true;
      pin = "2468";
    };
    p2 = {
      name = "Sam";
      pin = "1357";
    };
  };
  envs.jf.ids = [ "jellyfin-desktop" ];
  appProfiles.hinteros-p1 = "jf";
  extraModule =
    { lib, ... }:
    {
      environment.systemPackages = [ pkgs.curl ];
      virtualisation = {
        memorySize = lib.mkOverride 40 6144;
        cores = lib.mkForce 4;
      };
    };

  testScript = ''
    import shlex

    ENV = "HINTEROS_SESSION_API=1.0 HINTEROS_SYSTEM_API=1.0 PYTHONPATH=/etc/hinteros-test"
    API = "http://127.0.0.1:8096"
    S = "/var/lib/hinteros/services/jellyfin-server"
    # The setup's files are root's (the service is not root).
    R = "/var/lib/hinteros-root/jellyfin-server"
    BASE = "/home/hinteros-p1/.local/share/hinteros/sandbox/jellyfin-desktop/.local/share/jellyfin-desktop"

    boot_box()
    machine.wait_for_unit("jellyfin.service", timeout=900)
    machine.wait_until_succeeds(f"curl -fsS {API}/System/Info/Public | jq -e .Id", timeout=600)
    key = machine.succeed(f"cat {R}/api-key").strip()

    def jf_get(path):
        return json.loads(machine.succeed(f"curl -fsS -H 'Authorization: MediaBrowser Token=\"{key}\"' '{API}{path}'"))

    with subtest("the seed page is served next to jellyfin-web"):
        page = machine.succeed(f"curl -fsS {API}/web/hinteros/signin.html")
        assert 'src="signin.js"' in page, page
        js = machine.succeed(f"curl -fsS {API}/web/hinteros/signin.js")
        assert "jellyfin_credentials" in js and "_deviceId2" in js, js
        machine.succeed(f"curl -fsS {API}/web/index.html | grep -q '<html'")

    enter("p1", "hinteros-p1")
    jobs_idle("hinteros-p1")

    def conf_path():
        prof = json.loads(machine.succeed(f"cat {BASE}/profiles.json"))["defaultProfile"]
        return f"{BASE}/profiles/{prof}/jellyfin-desktop.conf"

    def signed_in(user_id, timeout=90):
        end = time.time() + timeout
        while time.time() < end:
            sessions = jf_get("/Sessions?activeWithinSeconds=60")
            # hinteros-system's own sign-in (the token) makes a session of this device too, with
            # nothing in it: the web client's session reports what it can play.
            mine = [s for s in sessions if s.get("DeviceId") == "hinteros-p1" and s.get("UserId") == user_id
                    and s.get("PlayableMediaTypes")]
            if mine:
                return mine
            time.sleep(3)
        machine.screenshot("jellyfin-not-signed-in")
        print(machine.succeed("journalctl _SYSTEMD_USER_UNIT=hinteros-session.service -o cat | tail -80 || true"))
        raise AssertionError(f"no session for hinteros-p1: {jf_get('/Sessions')}")

    with subtest("launch: the app signs in by itself"):
        r = sess_ok("hinteros-p1", "apps.launch", {"id": "jellyfin-desktop"})
        assert r["app"]["id"] == "jellyfin-desktop", r
        machine.wait_until_succeeds("pgrep -u hinteros-p1 -f '[j]ellyfin-desktop'", timeout=60)
        conf = conf_path()
        c = json.loads(machine.succeed(f"cat {shlex.quote(conf)}"))
        print(c)
        assert c["version"] == 7, c
        url = c["sections"]["path"]["startupurl_desktop"]
        assert url.startswith(f"{API}/web/hinteros/signin.html#s="), url
        assert "&d=hinteros-p1&AccessToken=" in url, url
        assert c["sections"]["main"]["userWebClient"] == API, c
        assert c["sections"]["main"]["layout"] == "tv", c
        for f in (conf, f"{BASE}/profiles.json"):
            assert machine.succeed(f"stat -c '%a %U' {shlex.quote(f)}").strip() == "600 hinteros-p1", f
        users = json.loads(machine.succeed(f"cat {S}/users.json"))
        print({p: u["name"] for p, u in users["users"].items()})
        user_id = users["users"]["p1"]["jellyfin_user_id"]
        token = users["users"]["p1"]["access_token"]
        assert url.endswith("AccessToken=" + token), "the conf carries p1's token"
        mine = signed_in(user_id)
        print(mine)
        machine.sleep(5)
        machine.screenshot("jellyfin-signed-in")
        machine.fail(f"ls {BASE}/profiles/*/jellyfin-desktop.conf.broken")
        machine.fail(f"journalctl --no-pager | grep -qF -- '{token}'")

    with subtest("other profiles cannot read the app's settings"):
        machine.fail(f"runuser -u hinteros-p2 -- cat {shlex.quote(conf)}")

    with subtest("started again: only our keys change, signed in again"):
        sess_ok("hinteros-p1", "apps.close", {"id": "jellyfin-desktop"})
        machine.wait_until_fails("pgrep -u hinteros-p1 -f '[j]ellyfin-desktop'", timeout=60)
        before = json.loads(machine.succeed(f"cat {shlex.quote(conf)}"))
        print(before)
        sess_ok("hinteros-p1", "apps.launch", {"id": "jellyfin-desktop"})
        machine.wait_until_succeeds("pgrep -u hinteros-p1 -f '[j]ellyfin-desktop'", timeout=60)
        after = json.loads(machine.succeed(f"cat {shlex.quote(conf)}"))
        assert after["version"] == before["version"], (before, after)
        for name, keys in before["sections"].items():
            for k, v in keys.items():
                if (name, k) not in (("path", "startupurl_desktop"), ("main", "userWebClient"), ("main", "layout")):
                    assert after["sections"][name][k] == v, (name, k, before, after)
        signed_in(user_id)
        machine.fail(f"ls {BASE}/profiles/*/jellyfin-desktop.conf.broken")
        sess_ok("hinteros-p1", "apps.close", {"id": "jellyfin-desktop"})
  '';
}
