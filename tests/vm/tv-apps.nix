# M4 TV apps under cage (no network in the sandbox): the Firefox kiosk wrapper with a
# per-app profile, the User-Agent override that only the YouTube profile gets, the app
# registry as the daemon reports it (apps.list over the session socket, API 0.6) and launching
# apps through apps.launch. The YouTube and Crunchyroll URLs point at local pages. Firefox runs
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
        crunchyroll.kiosk.url = "file:///etc/hinteros-test/crunchyroll.html";
        firefox.kiosk.url = "file:///etc/hinteros-test/firefox.html";
      };
      environment.etc = {
        "hinteros-test/youtube.html".text = page "YOUTUBE TEST PAGE";
        "hinteros-test/crunchyroll.html".text = page "CRUNCHYROLL TEST PAGE";
        "hinteros-test/firefox.html".text = page "PLAIN FIREFOX PAGE";
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
    machine.wait_until_succeeds("pgrep -u hinteros -f '/bin/cage '")
    machine.wait_for_unit("hinteros-session.service", "hinteros")
    uid = machine.succeed("id -u hinteros").strip()
    sock = f"/run/user/{uid}/hinteros/session.sock"
    machine.wait_until_succeeds(f"test -S {sock}")
    home = "/home/hinteros"

    # The session user may use uinput (keyboard-driven apps).
    machine.succeed("id -nG hinteros | tr ' ' '\\n' | grep -qx uinput")
    machine.succeed("test -e /dev/uinput")

    def rpc(*msgs, wait=2):
        hello = {"jsonrpc": "2.0", "id": 0, "method": "hello",
                 "params": {"api_version": "0.6", "client": {"name": "tv-apps-test", "version": "0"}}}
        payload = "".join(json.dumps(m) + "\n" for m in (hello, *msgs))
        cmd = f"(printf %s {shlex.quote(payload)}; sleep {wait}) | socat -t{wait} - UNIX-CONNECT:{sock}"
        out = machine.succeed(f"runuser -u hinteros -- sh -c {shlex.quote(cmd)}")
        replies = [json.loads(line) for line in out.splitlines() if line.strip()]
        assert "error" not in replies[0], replies[0]
        return replies

    def ok(method, params=None, wait=2):
        reply = next(r for r in rpc({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}, wait=wait) if r.get("id") == 1)
        assert "error" not in reply, reply
        return reply["result"]

    # Registry: the four default apps, Plex absent (not a default app).
    apps = ok("apps.list")["apps"]
    ids = [a["id"] for a in apps]
    print(ids)
    for want in ("jellyfin", "youtube", "crunchyroll", "firefox"):
        assert want in ids, ids
    assert "plex" not in ids, ids
    by_id = {a["id"]: a for a in apps}
    assert by_id["youtube"]["kind"] == "web" and by_id["jellyfin"]["kind"] == "native", by_id
    assert by_id["youtube"]["name"] == "YouTube", by_id["youtube"]
    machine.succeed("test -s " + shlex.quote(by_id["youtube"]["icon"]))

    # YouTube: apps.launch starts the kiosk wrapper with its own profile and the TV UA.
    ok("apps.launch", {"id": "youtube"})
    machine.wait_until_succeeds("pgrep -u hinteros -f -- '--kiosk'", timeout=60)
    ytprofile = f"{home}/.local/share/hinteros/firefox/youtube"
    machine.wait_until_succeeds(f"pgrep -u hinteros -af firefox | grep -F -- '--profile {ytprofile}'")
    machine.wait_until_succeeds(f"grep -F 'general.useragent.override' {ytprofile}/user.js")
    machine.wait_for_text("YOUTUBE", timeout=timedelta(seconds=180))
    machine.wait_for_text("PlayStation", timeout=timedelta(seconds=60))
    machine.screenshot("youtube-ua")
    # Policies reached the profile: no first-run or welcome page.
    screen = machine.get_screen_text().lower()
    for bad in ("welcome to firefox", "get started", "import"):
        assert bad not in screen, screen

    ok("apps.close", {"id": "youtube"})
    machine.wait_until_fails(f"pgrep -u hinteros -af firefox | grep -F -- '--profile {ytprofile}'", timeout=60)

    # Crunchyroll: its own profile, no UA override, no first-run screen.
    ok("apps.launch", {"id": "crunchyroll"})
    crprofile = f"{home}/.local/share/hinteros/firefox/crunchyroll"
    machine.wait_until_succeeds(f"pgrep -u hinteros -af firefox | grep -F -- '--profile {crprofile}' | grep -F -- '--kiosk'", timeout=60)
    machine.wait_for_text("CRUNCHYROLL", timeout=timedelta(seconds=180))
    machine.wait_for_text("Mozilla", timeout=timedelta(seconds=60))
    screen = machine.get_screen_text().lower()
    assert "playstation" not in screen, screen
    for bad in ("welcome to firefox", "get started", "import"):
        assert bad not in screen, screen
    machine.screenshot("crunchyroll")
    machine.succeed(f"! grep -q useragent {crprofile}/user.js")
    # Separate profile directories.
    machine.succeed(f"test -d {ytprofile} && test -d {crprofile}")
    ok("apps.close", {"id": "crunchyroll"})

    # Jellyfin: the desktop client starts and stays up (no server to log in to here).
    ok("apps.launch", {"id": "jellyfin"})
    machine.wait_until_succeeds("pgrep -u hinteros -f jellyfin-desktop", timeout=60)
    machine.sleep(duration=timedelta(seconds=10))
    machine.succeed("pgrep -u hinteros -f jellyfin-desktop")
    machine.screenshot("jellyfin")
  '';
}
