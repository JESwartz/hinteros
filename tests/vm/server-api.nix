# The Server section through the real chain (design/server.md, M10 build step 3; system API 0.11,
# session API 0.19): the launcher's calls on p1's session daemon -> the relay -> hinteros-system
# (seat0 owner, polkit `org.hinteros.system.services`, the admin PIN) -> job units -> the services.
# Greeter mode; p1 = `hinteros-p1` (James, admin, PIN 2468), p2 = `hinteros-p2` (Sam, PIN 1357),
# the guest on.
#   - services.enable jellyfin-server: a wrong PIN is refused, the right one starts a job that
#     switches to the system with Jellyfin and waits for its setup; services.list then shows it
#     enabled, active, set up, with one Jellyfin user per profile;
#   - media.folders lists /srv/media's folders (not hidden ones, not symlinks) and refuses `..`
#     and a symlink out, also as a library folder;
#   - jellyfin.libraries.add: the library is in services.list and in Jellyfin (API key) with
#     its folder; a second one with the same name is refused; jellyfin.libraries.remove;
#   - jellyfin.users.reveal (admin PIN only): each password signs in to Jellyfin;
#   - jellyfin.client_token: each profile gets a token for its own user only (device
#     hinteros-<id>), the guest and root are refused;
#   - profiles.create while Jellyfin is on: the new profile's Jellyfin user appears;
#   - services.disable with delete_data: /var/lib/jellyfin, /var/cache/jellyfin and HinterOS's
#     Jellyfin files (users.json) are gone, and the firewall rule;
#   - Plex, Tailscale, Cloudflare Tunnel in one enable (Plex's terms needed): Plex's detail
#     reads Preferences.xml (claimed false, then true with a token in it), a malformed claim code
#     is refused (a real claim needs plex.tv); Tailscale's state comes from tailscaled's socket
#     (needs_login); tailscale.login has no internet here: tailscaled never gets a sign-in URL,
#     so the job fails cleanly (timeout) when the CLI's timeout (30 s here) runs out;
#     cloudflare.set_token refuses a malformed token, writes a well-formed one 0600 and starts
#     the unit, and the job fails with `not_connected` (no internet); clear_token stops the unit
#     and deletes the file.
# Also checked on the way, what hinteros-system and its jobs need from the system (daemon README,
# "What the system repo must provide (0.11)"): loopback HTTP from the service and the jobs, the
# box's address from /proc/net (the url), /srv/media, /var/lib/hinteros/services, tailscaled's
# socket, Plex's Preferences.xml, the job's D-Bus restart of hinteros-cloudflared, deletes under
# /var/lib and /var/cache.
# STUBBED: the system builds (the specialisations), and Plex Media Server (unfree, downloads from
# plex.tv; VM tests refuse a nixpkgs config): a stub that answers HTTP on 32400, as in
# server-network.
{ self, pkgs }:
let
  inherit (pkgs) lib;
  profiles = import ./system/profiles.nix { inherit self pkgs; };
  st =
    accounts: services:
    profiles.mkState {
      inherit accounts services;
    };
  two = [
    "p1"
    "p2"
  ];
  three = two ++ [ "p3" ];
  net = [
    "cloudflare-tunnel"
    "tailscale"
    "plex-media-server"
  ];

  plexReply = pkgs.writeShellScript "plex-reply" ''
    printf 'HTTP/1.0 200 OK\r\nContent-Length: 4\r\n\r\nplex'
  '';
  plexStub = pkgs.writeShellScriptBin "plexmediaserver" ''
    exec ${lib.getExe pkgs.socat} TCP-LISTEN:32400,reuseaddr,fork EXEC:${plexReply}
  '';
  # The same server under another version, as an update would bring (the job reads the version
  # from jellyfin.service's command).
  jellyfinNext = pkgs.symlinkJoin {
    name = "jellyfin-99.0";
    paths = [ pkgs.jellyfin ];
    meta.mainProgram = "jellyfin";
  };
in
profiles.mkTest {
  name = "server-api";
  timeout = 3600;
  state = st two [ ];
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
  specialisations = {
    jf = st two [ "jellyfin-server" ];
    jf-next = {
      state = st two [ "jellyfin-server" ];
      module.services.jellyfin.package = jellyfinNext;
    };
    jf-p3 = st three [ "jellyfin-server" ];
    p3 = st three [ ];
    net = st three net;
  };
  extraModule =
    { config, lib, ... }:
    {
      hinteros.unfreeAllowlist = lib.mkForce [ ];
      services.plex.package = lib.mkForce plexStub;
      # As profiles.nix, and Tailscale's sign-in gives up after 30 s (no internet here).
      systemd.services.hinteros-system.serviceConfig.ExecStart =
        lib.mkOverride 40 "${lib.getExe config.hinteros.daemon.system.package} --freeze-inactive --min-memory-bytes 268435456 --min-disk-bytes 1048576 --rate-burst 100 --rate-per-minute 6000 --tailscale-login-timeout-s 30";
      environment.systemPackages = [ pkgs.curl ];
      virtualisation.memorySize = lib.mkOverride 40 4096;
    };

  testScript = ''
    import base64

    ENV = "HINTEROS_SESSION_API=1.0 HINTEROS_SYSTEM_API=1.0 PYTHONPATH=/etc/hinteros-test"
    API = "http://127.0.0.1:8096"
    S = "/var/lib/hinteros/services"
    PIN = "2468"
    CLIENT_HDR = "Authorization: MediaBrowser Client=\"test\", Device=\"test\", DeviceId=\"test\", Version=\"1\""

    systems = boot_box()
    # The box's address in the default route's subnet (here the user-mode network's eth0).
    MACHINE = machine.succeed("ip -4 -o addr show dev $(ip -4 route show default | awk '{print $5; exit}') | awk '{print $4}' | cut -d/ -f1").strip()

    def rev():
        return sys_ok("hinteros-p1", "settings.get")["revision"]

    def services():
        # A switch restarts hinteros-system when its unit changes (loopback for the servers):
        # the session daemon's relay reconnects within seconds (system_unavailable until then).
        for _ in range(30):
            r = sess("hinteros-p1", "system.services.list")
            if r.get("error", {}).get("code") != 3001:
                break
            time.sleep(1)
        assert "result" in r, r
        return {s["id"]: s for s in r["result"]["services"]}

    def job(method, params, timeout=600, state="succeeded"):
        for _ in range(5):
            r = sess("hinteros-p1", method, params)
            if r.get("error", {}).get("code") != 3005:
                break
            jobs_idle("hinteros-p1")
        assert "result" in r and r["result"]["job_id"], (method, r)
        done = wait_job("hinteros-p1", r["result"]["job_id"], timeout)
        assert done["state"] == state, (method, done)
        return done

    def api_key():
        return machine.succeed(f"cat {S}/jellyfin-server/api-key").strip()

    def jf_get(path, token=None):
        hdr = f"Authorization: MediaBrowser Token=\"{token or api_key()}\""
        return json.loads(machine.succeed(f"curl -fsS -H '{hdr}' {API}{path}"))

    def jf_login(name, password):
        body = json.dumps({"Username": name, "Pw": password})
        return machine.succeed(
            f"printf %s '{body}' | curl -fsS -X POST -H 'Content-Type: application/json' -H '{CLIENT_HDR}' "
            f"--data-binary @- {API}/Users/AuthenticateByName | jq -er .User.Id").strip()

    enter("p1", "hinteros-p1")
    jobs_idle("hinteros-p1")

    with subtest("services.list before: the catalog's services, all off"):
        s = services()
        assert {"jellyfin-server", "plex-media-server", "tailscale", "cloudflare-tunnel"} <= set(s), list(s)
        for i in ("jellyfin-server", "plex-media-server", "tailscale", "cloudflare-tunnel"):
            assert s[i]["enabled"] is False and s[i]["available"] is True and s[i]["detail"] is None, s[i]
        assert s["jellyfin-server"]["setup"] == "jellyfin-server" and s["tailscale"]["setup"] == "tailscale", s
        assert s["plex-media-server"]["terms"]["version"] == "2025-10-30", s

    with subtest("services.enable jellyfin-server: the admin PIN, a job, the setup"):
        for pin in ("0000", "1357"):
            r = sess("hinteros-p1", "system.services.enable", {"ids": ["jellyfin-server"], "pin": pin, "revision": rev()})
            assert r["error"]["code"] == 3016 and r["error"]["data"]["pin"] == "admin", r
        r = sess("hinteros-p1", "system.services.enable", {"ids": ["jellyfin-server"], "pin": PIN, "revision": "0" * 64})
        assert r["error"]["code"] == 3007, r
        r = sess("hinteros-p1", "system.services.enable", {"ids": ["jellyfin-desktop"], "pin": PIN, "revision": rev()})
        assert r["error"]["code"] == -32602 and r["error"]["data"]["reason"] == "not_a_service", r
        stub_build(systems["jf"])
        done = job("system.services.enable", {"ids": ["jellyfin-server"], "pin": PIN, "revision": rev()}, timeout=900)
        assert done["kind"] == "services_enable", done
        assert current_system() == systems["jf"]
        assert state_json()["services"] == ["jellyfin-server"], state_json()
        machine.succeed(f"test -e {S}/jellyfin-server/setup-done")

    with subtest("services.list: enabled, running, set up, one user per profile"):
        j = services()["jellyfin-server"]
        print(j)
        assert j["enabled"] is True and j["status"] == "active", j
        d = j["detail"]
        assert d["setup_done"] is True and d["libraries"] == [], d
        assert d["url"] == f"http://{MACHINE}:8096", d
        users = {u["profile_id"]: u["jellyfin_user"] for u in d["users"]}
        assert users == {"p1": "James", "p2": "Sam"}, users
        names = {u["Name"]: u for u in jf_get("/Users")}
        assert {"admin", "James", "Sam"} <= set(names), list(names)
        assert not names["James"]["Policy"]["IsAdministrator"], names["James"]
        assert machine.succeed(f"stat -c '%a %U' {S}/jellyfin-server/users.json").strip() == "600 root"
        # A second enable is nothing to do.
        r = sess_ok("hinteros-p1", "system.services.enable", {"ids": ["jellyfin-server"], "pin": PIN, "revision": rev()})
        assert r == {"job_id": None}, r

    with subtest("media.folders: /srv/media's folders, no hidden ones, no way out"):
        machine.succeed(
            "mkdir -p /srv/media/Movies/HD /srv/media/Shows /srv/media/.hidden /root/secret && "
            "ln -s /root/secret /srv/media/Escape && ln -s /etc /srv/media/Movies/etc && "
            "echo film > /srv/media/Movies/a.mkv && chgrp -R hinteros-media /srv/media"
        )
        r = sess_ok("hinteros-p1", "system.media.folders")
        print(r)
        ids = [f["id"] for f in r["folders"]]
        assert ids == ["Movies", "Shows"], r
        r = sess_ok("hinteros-p1", "system.media.folders", {"folder_id": "Movies"})
        assert [f["id"] for f in r["folders"]] == ["Movies/HD"], r
        for bad in ("..", "../etc", "Movies/..", "/etc", ".hidden"):
            r = sess("hinteros-p1", "system.media.folders", {"folder_id": bad})
            assert r["error"]["code"] == -32602, (bad, r)
        for out in ("Escape", "Movies/etc", "Nope"):
            r = sess("hinteros-p1", "system.media.folders", {"folder_id": out})
            assert r["error"]["code"] == 3010, (out, r)
            r = sess("hinteros-p1", "system.jellyfin.libraries.add", {"pin": PIN, "name": "X", "kind": "movies", "folder": out})
            assert r["error"]["code"] == 3010, (out, r)
        r = sess("hinteros-p1", "system.jellyfin.libraries.add", {"pin": PIN, "name": "X", "kind": "movies", "folder": "../etc"})
        assert r["error"]["code"] == -32602, r

    with subtest("jellyfin.libraries.add and remove"):
        r = sess("hinteros-p1", "system.jellyfin.libraries.add", {"pin": "1357", "name": "Films", "kind": "movies", "folder": "Movies"})
        assert r["error"]["code"] == 3016, r
        done = job("system.jellyfin.libraries.add", {"pin": PIN, "name": "Films", "kind": "movies", "folder": "Movies"})
        assert done["kind"] == "jellyfin_library_add", done
        libs = services()["jellyfin-server"]["detail"]["libraries"]
        assert len(libs) == 1 and libs[0]["name"] == "Films" and libs[0]["kind"] == "movies" and libs[0]["folder"] == "Movies", libs
        vf = {f["Name"]: f for f in jf_get("/Library/VirtualFolders")}
        assert vf["Films"]["Locations"] == ["/srv/media/Movies"] and vf["Films"]["CollectionType"] == "movies", vf
        assert vf["Films"]["ItemId"] == libs[0]["id"], (vf, libs)
        r = sess("hinteros-p1", "system.jellyfin.libraries.add", {"pin": PIN, "name": "films", "kind": "shows", "folder": "Shows"})
        assert r["error"]["code"] == -32602 and r["error"]["data"]["reason"] == "exists", r
        r = sess("hinteros-p1", "system.jellyfin.libraries.remove", {"pin": PIN, "library_id": "0" * 32})
        assert r["error"]["code"] == 3010, r
        job("system.jellyfin.libraries.remove", {"pin": PIN, "library_id": libs[0]["id"]})
        assert services()["jellyfin-server"]["detail"]["libraries"] == []
        assert "Films" not in [f["Name"] for f in jf_get("/Library/VirtualFolders")]
        machine.succeed("test -f /srv/media/Movies/a.mkv")

    with subtest("jellyfin.users.reveal: admin PIN only, the passwords sign in"):
        r = sess("hinteros-p1", "system.jellyfin.users.reveal", {"pin": "0000"})
        assert r["error"]["code"] == 3016, r
        r = sess_ok("hinteros-p1", "system.jellyfin.users.reveal", {"pin": PIN})
        assert r["admin"]["name"] == "admin", r["admin"]["name"]
        jf_login("admin", r["admin"]["password"])
        accounts = {u["profile_id"]: u for u in r["users"]}
        assert set(accounts) == {"p1", "p2"}, list(accounts)
        ids = {}
        for p, u in accounts.items():
            ids[p] = jf_login(u["name"], u["password"])
        empty = json.dumps({"Username": "Sam", "Pw": ""})
        machine.fail(f"printf %s '{empty}' | curl -fsS -X POST -H 'Content-Type: application/json' -H '{CLIENT_HDR}' --data-binary @- {API}/Users/AuthenticateByName")
        # Never in the journal.
        for u in r["users"]:
            machine.fail(f"journalctl --no-pager | grep -qF -- '{u['password']}'")

    with subtest("jellyfin.client_token: the caller's own user only"):
        tokens = {}
        for p, user in (("p1", "hinteros-p1"), ("p2", "hinteros-p2")):
            t = sys_ok(user, "jellyfin.client_token")
            assert t["user_id"] == ids[p] and t["device_id"] == f"hinteros-{p}", (p, t)
            assert t["server_id"] == jf_get("/System/Info")["Id"], t
            me = jf_get("/Users/Me", t["access_token"])
            assert me["Id"] == ids[p], (p, me)
            tokens[p] = t
        assert tokens["p1"]["access_token"] != tokens["p2"]["access_token"]
        # Through the relay too; the same live token (one per device).
        t = sess_ok("hinteros-p1", "system.jellyfin.client_token")
        assert t["user_id"] == ids["p1"], t
        jf_get("/Users/Me", t["access_token"])
        devices = [d["Id"] for d in jf_get("/Devices")["Items"]]
        assert "hinteros-p1" in devices and "hinteros-p2" in devices, devices
        for user in ("hinteros-guest", "root"):
            e = sys_err(user, "jellyfin.client_token", {}, 3002)
            assert e["data"]["reason"] == "profile", (user, e)
        r = sysrpc("hinteros-p1", "jellyfin.client_token", {"profile_id": "p2"})
        assert r["error"]["code"] == -32602, r
        machine.fail(f"journalctl --no-pager | grep -qF -- '{tokens['p1']['access_token']}'")

    B = f"{S}/jellyfin-server/backup"

    with subtest("an update to another Jellyfin version backs up its data first"):
        machine.fail(f"test -e {B}")
        machine.succeed("echo one > /var/lib/jellyfin/data/hinteros-marker && chown jellyfin:jellyfin /var/lib/jellyfin/data/hinteros-marker")
        stub_build(systems["jf-next"])
        done = job("system.rebuild", {})
        assert current_system() == systems["jf-next"]
        assert machine.succeed(f"cat {B}/hinteros-marker").strip() == "one"
        assert machine.succeed(f"stat -c '%U %G' {B}/hinteros-marker").strip() == "jellyfin jellyfin"
        assert machine.succeed(f"stat -c '%a %U' {S}/jellyfin-server").strip() == "700 root"
        machine.succeed("journalctl -u 'hinteros-job@*' | grep -q 'Jellyfin changes version'")
        machine.wait_for_unit("jellyfin.service")
        machine.wait_until_succeeds(f"curl -fsS {API}/System/Info/Public | jq -e .Id", timeout=300)
        assert "jellyfin-99.0" in machine.succeed("systemctl show -p ExecStart jellyfin.service")
        # The same version again: no backup made.
        machine.succeed(f"touch {B}/kept")
        machine.succeed("echo two > /var/lib/jellyfin/data/hinteros-marker")
        job("system.rebuild", {})
        machine.succeed(f"test -e {B}/kept")

    with subtest("a new profile gets its Jellyfin user"):
        stub_build(systems["jf-p3"])
        # Back to 12.1 on the way: the backup is replaced.
        r = sess_ok("hinteros-p1", "system.profiles.create", {"name": "Alex", "pin": "4444", "locked": False, "revision": rev()})
        done = wait_job("hinteros-p1", r["job_id"])
        assert done["state"] == "succeeded", done
        machine.wait_until_succeeds(f"curl -fsS -H 'Authorization: MediaBrowser Token=\"{api_key()}\"' {API}/Users | jq -e 'map(.Name) | index(\"Alex\")'", timeout=60)
        users = {u["profile_id"]: u["jellyfin_user"] for u in services()["jellyfin-server"]["detail"]["users"]}
        assert users == {"p1": "James", "p2": "Sam", "p3": "Alex"}, users
        machine.fail(f"test -e {B}/kept")
        assert machine.succeed(f"cat {B}/hinteros-marker").strip() == "two"
        t = sys_ok("hinteros-p3", "jellyfin.client_token")
        assert jf_get("/Users/Me", t["access_token"])["Name"] == "Alex"

    with subtest("services.disable with delete_data: Jellyfin's data and the firewall rule are gone"):
        machine.succeed("test -d /var/lib/jellyfin/data && test -d /var/cache/jellyfin")
        assert "tcp dport 8096 accept" in machine.succeed("nft list ruleset")
        r = sess("hinteros-p1", "system.services.disable", {"ids": ["jellyfin-server"], "pin": "1357", "revision": rev(), "delete_data": True})
        assert r["error"]["code"] == 3016, r
        stub_build(systems["p3"])
        done = job("system.services.disable", {"ids": ["jellyfin-server"], "pin": PIN, "revision": rev(), "delete_data": True})
        assert done["kind"] == "services_disable", done
        assert current_system() == systems["p3"]
        machine.fail("systemctl is-active jellyfin.service")
        for p in ("/var/lib/jellyfin", "/var/cache/jellyfin", f"{S}/jellyfin-server"):
            machine.fail(f"test -e {p}")
        assert "8096" not in machine.succeed("nft list ruleset")
        j = services()["jellyfin-server"]
        assert j["enabled"] is False and j["detail"] is None, j
        assert state_json()["services"] == [], state_json()
        machine.succeed("test -f /srv/media/Movies/a.mkv")
        r = sess("hinteros-p1", "system.jellyfin.users.reveal", {"pin": PIN})
        assert r["error"]["code"] == 4001 and r["error"]["data"] == {"service": "jellyfin", "reason": "off"}, r

    with subtest("Plex, Tailscale, Cloudflare Tunnel: one enable, Plex's terms"):
        net = ["cloudflare-tunnel", "tailscale", "plex-media-server"]
        p = {"ids": net, "pin": PIN, "revision": rev()}
        r = sess("hinteros-p1", "system.services.enable", p)
        assert r["error"]["code"] == 3014 and r["error"]["data"] == {"id": "plex-media-server", "version": "2025-10-30"}, r
        stub_build(systems["net"])
        job("system.services.enable", {**p, "accepted_terms": {"plex-media-server": "2025-10-30"}})
        assert current_system() == systems["net"]
        machine.wait_for_unit("plex.service")
        machine.wait_for_unit("tailscaled.service")
        s = services()
        print({i: s[i] for i in net})
        assert all(s[i]["enabled"] for i in net), s
        assert s["plex-media-server"]["status"] == "active", s["plex-media-server"]
        assert s["plex-media-server"]["detail"]["claimed"] is False, s["plex-media-server"]
        assert s["plex-media-server"]["detail"]["url"] == f"http://{MACHINE}:32400", s["plex-media-server"]
        assert s["tailscale"]["detail"]["state"] == "needs_login", s["tailscale"]
        c = s["cloudflare-tunnel"]["detail"]
        assert c == {"token_set": False, "connected": False, "local_ip": MACHINE}, c
        rec = json.loads(machine.succeed("cat /var/lib/hinteros/terms-accepted.json"))["accepted"]
        assert rec["plex-media-server"][0]["profile"] == "p1", rec

    with subtest("Plex: Preferences.xml, the claim code's format"):
        for code in ("claim-short", "nope-AbCdEfGhIjKlMnOpQrSt", "claim-AbCdEfGhIjKlMnOpQr;t"):
            r = sess("hinteros-p1", "system.plex.claim", {"pin": PIN, "code": code})
            assert r["error"]["code"] == -32602, (code, r)
        prefs = "/var/lib/plex/Plex Media Server/Preferences.xml"
        machine.succeed(
            f"mkdir -p \"$(dirname '{prefs}')\" && printf '%s' '<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            "<Preferences ProcessedMachineIdentifier=\"abc\" FriendlyName=\"Box\" PlexOnlineToken=\"secret-plex-token\"/>' "
            f"> '{prefs}' && chown -R plex:plex /var/lib/plex"
        )
        d = services()["plex-media-server"]["detail"]
        assert d["claimed"] is True and d["server_name"] == "Box", d
        assert "secret-plex-token" not in json.dumps(services())
        # Linked already: nothing to do.
        assert sess_ok("hinteros-p1", "system.plex.claim", {"pin": PIN, "code": "claim-AbCdEfGhIjKlMnOpQrSt"}) == {"job_id": None}

    with subtest("Cloudflare: token checked, written 0600, the unit started; cleared"):
        tok = "/var/lib/hinteros/services/cloudflare-tunnel/token"
        secret = base64.b64encode(b"s" * 32).decode()
        good = base64.b64encode(json.dumps({
            "a": "0123456789abcdef0123456789abcdef",
            "t": "5c7f3a3e-1a2b-4c5d-8e9f-0a1b2c3d4e5f",
            "s": secret,
        }).encode()).decode()
        bad = [
            "x",
            base64.b64encode(b'{"a": "0", "t": "x", "s": "y"}').decode(),
            base64.b64encode(json.dumps({"a": "0123456789abcdef0123456789abcdef", "t": "5c7f3a3e-1a2b-4c5d-8e9f-0a1b2c3d4e5f", "s": secret, "x": 1}).encode()).decode(),
            good + "\n",
        ]
        for t in bad:
            r = sess("hinteros-p1", "system.cloudflare.set_token", {"pin": PIN, "token": t})
            assert r["error"]["code"] == -32602, (t, r)
        machine.fail(f"test -e {tok}")
        # No internet: cloudflared runs but never connects; the job says so.
        done = job("system.cloudflare.set_token", {"pin": PIN, "token": good}, state="failed")
        assert done["error"]["data"]["reason"] == "not_connected", done
        # hinteros-system's group (hinteros) on a 0600 file: root only.
        assert machine.succeed(f"stat -c '%a %U' {tok}").strip() == "600 root"
        assert machine.succeed(f"cat {tok}") == good
        machine.wait_until_succeeds("systemctl is-active hinteros-cloudflared.service", timeout=60)
        d = services()["cloudflare-tunnel"]["detail"]
        assert d["token_set"] is True and d["connected"] is False, d
        machine.fail(f"journalctl --no-pager | grep -qF -- '{secret}'")
        job("system.cloudflare.clear_token", {"pin": PIN})
        machine.fail(f"test -e {tok}")
        machine.fail("systemctl is-active hinteros-cloudflared.service")
        assert services()["cloudflare-tunnel"]["detail"]["token_set"] is False
        assert sess_ok("hinteros-p1", "system.cloudflare.clear_token", {"pin": PIN}) == {"job_id": None}

    with subtest("Tailscale: sign-in without internet fails cleanly"):
        r = sess_ok("hinteros-p1", "system.tailscale.login", {"pin": PIN})
        jid = r["job_id"]
        seen = set()
        urls = set()
        for _ in range(120):
            jj = sys_ok("hinteros-p1", "jobs.get", {"job_id": jid})["job"]
            seen.add(jj["stage"])
            if jj.get("detail") and jj["detail"].get("auth_url"):
                urls.add(jj["detail"]["auth_url"])
            if jj["state"] != "running":
                break
            time.sleep(1)
        print(jj, seen, urls)
        assert jj["state"] == "failed", jj
        assert jj["error"]["data"]["reason"] == "timeout", jj
        assert not urls, urls
        assert services()["tailscale"]["detail"]["state"] == "needs_login"
        machine.fail("pgrep -x tailscale")
        # Signed out already: nothing to do.
        assert sess_ok("hinteros-p1", "system.tailscale.logout", {"pin": PIN}) == {"job_id": None}
  '';
}
