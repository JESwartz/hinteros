# M4 TV apps under cage (no network in the sandbox): the Firefox kiosk wrapper with a
# per-app profile, the User-Agent override that only the YouTube profile gets, the app
# registry as the daemon reports it (apps.list over the session socket, API 0.18) and launching
# apps through apps.launch (also the Store-only streaming apps Netflix and Spotify). The YouTube,
# Crunchyroll and Netflix URLs point at local pages. Firefox runs
# on Xwayland (MOZ_ENABLE_WAYLAND=0), as under gamescope.
{ self, pkgs }:
let
  ytUserAgent = "Mozilla/5.0 (PlayStation; PlayStation 5/2.26) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0 Safari/605.1.15";
  page = title: ''
    <!doctype html><meta charset=utf-8><title>${title}</title>
    <body style="background:#fff;color:#000;font:bold 44px sans-serif;margin:30px">
    <p>${title}</p><p id=ua></p>
    <script>document.getElementById('ua').textContent = 'UA ' + navigator.userAgent;</script>
  '';
in
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-tv-apps";
  enableOCR = true;

  nodes.machine =
    { lib, pkgs, ... }:
    {
      imports = [
        self.nixosModules.session
        self.nixosModules.daemon
        self.nixosModules.apps
        ../../nixos/vm
      ];

      hinteros.apps = {
        youtube.kiosk.url = "file:///etc/hinteros-test/youtube.html";
        # Store-only: installed from the Store, not on the ISO.
        crunchyroll.enable = true;
        crunchyroll.kiosk.url = "file:///etc/hinteros-test/crunchyroll.html";
        firefox.kiosk.url = "file:///etc/hinteros-test/firefox.html";
        # Store-only streaming apps, as if installed from the Store.
        netflix = {
          enable = true;
          kiosk.url = "file:///etc/hinteros-test/netflix.html";
        };
        spotify.enable = true;
      };
      environment.etc = {
        "hinteros-test/youtube.html".text = page "YOUTUBE TEST PAGE";
        "hinteros-test/crunchyroll.html".text = page "CRUNCHYROLL TEST PAGE";
        "hinteros-test/firefox.html".text = page "PLAIN FIREFOX PAGE";
        "hinteros-test/netflix.html".text = page "NETFLIX TEST PAGE";
      };

      environment.systemPackages = [ pkgs.socat ];
      virtualisation.memorySize = lib.mkForce 4096;
    };

  testScript = ''
    import json
    import shlex
    from datetime import timedelta

    YT_UA = ${builtins.toJSON ytUserAgent}

    machine.wait_for_unit("multi-user.target")
    machine.wait_until_succeeds("pgrep -u hinteros-p1 -f '/bin/cage '")
    machine.wait_for_unit("hinteros-session.service", "hinteros-p1")
    uid = machine.succeed("id -u hinteros-p1").strip()
    sock = f"/run/user/{uid}/hinteros/session.sock"
    machine.wait_until_succeeds(f"test -S {sock}")
    home = "/home/hinteros-p1"
    # Apps run in the sandbox (design/sandbox.md): the profile path Firefox gets is under $HOME,
    # which is the app's sandbox home on disk.
    def on_disk(app, path):
        return f"{home}/.local/share/hinteros/sandbox/{app}" + path.removeprefix(home)

    # The session user may use uinput (keyboard-driven apps).
    machine.succeed("id -nG hinteros-p1 | tr ' ' '\\n' | grep -qx uinput")
    machine.succeed("test -e /dev/uinput")

    def rpc(*msgs, wait=2):
        hello = {"jsonrpc": "2.0", "id": 0, "method": "hello",
                 "params": {"api_version": "0.21", "client": {"name": "tv-apps-test", "version": "0"}}}
        payload = "".join(json.dumps(m) + "\n" for m in (hello, *msgs))
        cmd = f"(printf %s {shlex.quote(payload)}; sleep {wait}) | socat -t{wait} - UNIX-CONNECT:{sock}"
        out = machine.succeed(f"runuser -u hinteros-p1 -- sh -c {shlex.quote(cmd)}")
        replies = [json.loads(line) for line in out.splitlines() if line.strip()]
        assert "error" not in replies[0], replies[0]
        return replies

    def ok(method, params=None, wait=2):
        reply = next(r for r in rpc({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}, wait=wait) if r.get("id") == 1)
        assert "error" not in reply, reply
        return reply["result"]

    # Registry: the three ISO apps and Crunchyroll (a Store app, enabled above), Plex absent.
    apps = ok("apps.list")["apps"]
    ids = [a["id"] for a in apps]
    print(ids)
    for want in ("jellyfin", "youtube", "crunchyroll", "firefox"):
        assert want in ids, ids
    assert "plex" not in ids, ids
    by_id = {a["id"]: a for a in apps}
    assert by_id["youtube"]["kind"] == "web" and by_id["jellyfin"]["kind"] == "native", by_id
    assert by_id["youtube"]["name"] == "YouTube", by_id["youtube"]
    # Store-only streaming apps that were installed show up like the other web apps.
    for want in ("netflix", "spotify"):
        assert want in ids, ids
        assert by_id[want]["kind"] == "web", by_id[want]
    assert by_id["netflix"]["name"] == "Netflix", by_id["netflix"]
    assert "disney-plus" not in ids, ids
    # Icons are found by the daemon at runtime (no network here): session.toml carries the catalog's fields.
    toml = machine.succeed("cat $(ps -u hinteros-p1 -o args= | grep -o '/nix/store/[^ ]*hinteros-session.toml' | head -n1)")
    for want in ("desktop_id = \"org.jellyfin.JellyfinDesktop\"", "firefox_profile = ", "site_url = "):
        assert want in toml, toml

    # YouTube: apps.launch starts the kiosk wrapper with its own profile and the TV UA.
    ok("apps.launch", {"id": "youtube"})
    machine.wait_until_succeeds("pgrep -u hinteros-p1 -f -- '--kiosk'", timeout=60)
    ytprofile = f"{home}/.local/share/hinteros/firefox/youtube"
    machine.wait_until_succeeds(f"pgrep -u hinteros-p1 -af firefox | grep -F -- '--profile {ytprofile}'")
    machine.wait_until_succeeds(f"grep -F 'general.useragent.override' {on_disk('youtube', ytprofile)}/user.js")
    machine.wait_for_text("YOUTUBE", timeout=timedelta(seconds=180))
    machine.wait_for_text("PlayStation", timeout=timedelta(seconds=60))
    machine.screenshot("youtube-ua")
    # Policies reached the profile: no first-run or welcome page.
    screen = machine.get_screen_text().lower()
    for bad in ("welcome to firefox", "get started", "import"):
        assert bad not in screen, screen

    ok("apps.close", {"id": "youtube"})
    machine.wait_until_fails(f"pgrep -u hinteros-p1 -af firefox | grep -F -- '--profile {ytprofile}'", timeout=60)

    # Crunchyroll: its own profile, no UA override, no first-run screen.
    ok("apps.launch", {"id": "crunchyroll"})
    crprofile = f"{home}/.local/share/hinteros/firefox/crunchyroll"
    machine.wait_until_succeeds(f"pgrep -u hinteros-p1 -af firefox | grep -F -- '--profile {crprofile}' | grep -F -- '--kiosk'", timeout=60)
    machine.wait_for_text("CRUNCHYROLL", timeout=timedelta(seconds=180))
    machine.wait_for_text("Mozilla", timeout=timedelta(seconds=60))
    screen = machine.get_screen_text().lower()
    assert "playstation" not in screen, screen
    for bad in ("welcome to firefox", "get started", "import"):
        assert bad not in screen, screen
    machine.screenshot("crunchyroll")
    machine.succeed(f"! grep -q useragent {on_disk('crunchyroll', crprofile)}/user.js")
    # Separate profile directories, each in its app's sandbox home.
    machine.succeed(f"test -d {on_disk('youtube', ytprofile)} && test -d {on_disk('crunchyroll', crprofile)}")
    machine.succeed(f"test ! -e {ytprofile}")
    ok("apps.close", {"id": "crunchyroll"})

    # Netflix (a Store-only streaming app): its own profile, no UA override, no first-run screen.
    ok("apps.launch", {"id": "netflix"})
    nfprofile = f"{home}/.local/share/hinteros/firefox/netflix"
    machine.wait_until_succeeds(f"pgrep -u hinteros-p1 -af firefox | grep -F -- '--profile {nfprofile}' | grep -F -- '--kiosk'", timeout=60)
    machine.wait_for_text("NETFLIX", timeout=timedelta(seconds=180))
    screen = machine.get_screen_text().lower()
    assert "playstation" not in screen, screen
    for bad in ("welcome to firefox", "get started", "import"):
        assert bad not in screen, screen
    machine.succeed(f"! grep -q useragent {on_disk('netflix', nfprofile)}/user.js")
    machine.succeed(f"test -d {on_disk('netflix', nfprofile)}")
    ok("apps.close", {"id": "netflix"})

    # Jellyfin: the desktop client starts and stays up (no server to log in to here).
    ok("apps.launch", {"id": "jellyfin"})
    machine.wait_until_succeeds("pgrep -u hinteros-p1 -f jellyfin-desktop", timeout=60)
    machine.sleep(duration=timedelta(seconds=10))
    machine.succeed("pgrep -u hinteros-p1 -f jellyfin-desktop")
    machine.screenshot("jellyfin")
  '';
}
