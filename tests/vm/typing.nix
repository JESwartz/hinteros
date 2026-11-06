# End-to-end typing under cage (no network, loopback only): the session daemon's uinput
# keyboard types into a real Firefox kiosk, the way the on-screen keyboard and the launcher's
# text entry will. Spike 5's test page (a text and a password field that POST every input to a
# local server) is served from loopback; over the session socket at API 0.18 the test calls
# keys.type "https://example.com/a?b=1", keys.action tab, keys.type "P@ss-w0rd!" and
# keys.action enter, then checks that the page received exactly those values. Also checks that
# the daemon started the on-screen keyboard process (hinteros-osk, a second launcher
# entrypoint), that osk.show / osk.hide answer, and that the OSK Firefox extension is active in
# the kiosk profile and a focused text field makes the daemon show the keyboard (osk_changed).
# Not covered here (the daemon's own tests do): keyboard-profile arrow keys from a fake
# InputPlumber, gamescope's input method, the overlay (cage has neither).
{ self, pkgs }:
let
  page = pkgs.writeText "typing-page.html" ''
    <!doctype html><meta charset=utf-8><title>HinterOS typing test</title>
    <style>body{font:48px sans-serif;margin:40px;background:#fff;color:#000}input{font-size:48px;width:90%}</style>
    <h1>HinterOS typing test</h1>
    <form id=f><p>Text: <input id=t type=text autofocus autocomplete=off></p>
    <p>Password: <input id=p type=password autocomplete=off></p>
    <input type=submit value=Go style="display:none"></form>
    <p>TEXT=<span id=et></span></p><p>PW=<span id=ep></span></p>
    <script>
    function post(id,v){fetch('/log',{method:'POST',body:JSON.stringify({id:id,value:v})});}
    for (const [i,e] of [['t','et'],['p','ep']]) {
      const el=document.getElementById(i);
      el.addEventListener('input',()=>{document.getElementById(e).textContent=el.value;post(i,el.value);});
      el.addEventListener('focus',()=>post('focus',i));
    }
    document.getElementById('f').addEventListener('submit',(ev)=>{ev.preventDefault();post('submit','1');});
    post('loaded','1');
    </script>
  '';

  # Threading server: Firefox opens speculative idle connections that block a single-threaded one.
  server = pkgs.writeText "typing-server.py" ''
    import http.server
    PAGE = open("${page}", "rb").read()
    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers(); self.wfile.write(PAGE)
        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
            with open("/tmp/posted.log", "a") as f: f.write(body + "\n")
            self.send_response(204); self.end_headers()
        def log_message(self, *a): pass
    http.server.ThreadingHTTPServer(("127.0.0.1", 8000), H).serve_forever()
  '';
in
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-typing";
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

      # Only Firefox: it is the keyboard-profile app whose window the typing goes to.
      hinteros.apps = {
        jellyfin-desktop.enable = false;
        youtube.enable = false;
        crunchyroll.enable = false;
        firefox.kiosk.url = "http://127.0.0.1:8000/";
      };

      # The test checks the automatic keyboard (extension -> osk.sock): auto_show is off by default.
      hinteros.daemon.osk.autoShow = true;

      systemd.services.typing-page = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${lib.getExe pkgs.python3} ${server}";
      };

      environment.systemPackages = [
        pkgs.socat
        pkgs.jq
      ];
      virtualisation.memorySize = lib.mkForce 4096;
    };

  testScript = ''
    import json
    import shlex
    from datetime import timedelta

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("typing-page.service")
    machine.wait_until_succeeds("pgrep -u hinteros-p1 -f '/bin/cage '")
    machine.wait_for_unit("hinteros-session.service", "hinteros-p1")
    uid = machine.succeed("id -u hinteros-p1").strip()
    sock = f"/run/user/{uid}/hinteros/session.sock"
    machine.wait_until_succeeds(f"test -S {sock}")

    def rpc(*msgs, wait=2):
        hello = {"jsonrpc": "2.0", "id": 0, "method": "hello",
                 "params": {"api_version": "1.0", "client": {"name": "typing-test", "version": "0"}}}
        payload = "".join(json.dumps(m) + "\n" for m in (hello, *msgs))
        cmd = f"(printf %s {shlex.quote(payload)}; sleep {wait}) | socat -t{wait} - UNIX-CONNECT:{sock}"
        out = machine.succeed(f"runuser -u hinteros-p1 -- sh -c {shlex.quote(cmd)}")
        replies = [json.loads(line) for line in out.splitlines() if line.strip()]
        assert "error" not in replies[0], replies[0]
        return replies

    def call(method, params=None, wait=2):
        reply = next(r for r in rpc({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}, wait=wait) if r.get("id") == 1)
        assert "error" not in reply, reply
        return reply["result"]

    def posted():
        return [json.loads(l) for l in machine.succeed("cat /tmp/posted.log 2>/dev/null || true").splitlines() if l.strip()]

    # The daemon started the on-screen keyboard (a second entrypoint of the launcher).
    # Its argv is the launcher binary with --osk, its process name hinteros-osk.
    machine.wait_until_succeeds("pgrep -u hinteros-p1 -x hinteros-osk || pgrep -u hinteros-p1 -f -- ' --osk'", timeout=60)
    machine.wait_until_succeeds(
        "journalctl _SYSTEMD_USER_UNIT=hinteros-session.service --no-pager "
        "| grep -E 'handshake done client=hinteros-osk .*api_version=1.0'",
        timeout=120,
    )
    # It is summoned over the API (the controller chord needs a pad). cage has no overlay, so
    # this is the daemon's bookkeeping only.
    assert call("osk.show") == {"visible": True}
    assert call("osk.hide") == {"visible": False}

    # A subscriber for osk_changed, to see the automatic keyboard (Firefox extension -> native
    # host -> osk.sock -> daemon; Firefox ESR with the extension force-installed by policy).
    sub = [
        {"jsonrpc": "2.0", "id": 0, "method": "hello",
         "params": {"api_version": "1.0", "client": {"name": "typing-test-events", "version": "0"}}},
        {"jsonrpc": "2.0", "id": 1, "method": "subscribe", "params": {"events": ["osk_changed"]}},
    ]
    sub_payload = "".join(json.dumps(m) + "\n" for m in sub)
    machine.succeed(
        f"runuser -u hinteros-p1 -- sh -c {shlex.quote(f'(printf %s {shlex.quote(sub_payload)}; sleep 3000) | socat - UNIX-CONNECT:{sock} > /tmp/osk-events.log 2>&1 &')}"
        " ; sleep 1"
    )

    # Firefox on the test page (the firefox app: kiosk profile, fullscreen by the compositor), text field focused.
    call("apps.launch", {"id": "firefox"})
    machine.wait_until_succeeds("pgrep -u hinteros-p1 -f -- '--profile'", timeout=60)
    machine.wait_for_text("typing test", timeout=timedelta(seconds=180))
    machine.wait_until_succeeds("grep -F '\"focus\"' /tmp/posted.log | grep -F '\"t\"'", timeout=60)
    machine.screenshot("typing-before")

    # The extension is installed and active in the kiosk profile (policy force-install on ESR),
    # which is in the app's sandbox home...
    machine.wait_until_succeeds(
        "jq -e '.addons[] | select(.id == \"hinteros-osk@hinteros\" and .active == true)' "
        "/home/hinteros-p1/.local/share/hinteros/sandbox/firefox/.local/share/hinteros/firefox/firefox/extensions.json",
        timeout=120,
    )
    # ...and the text field's focus reached the daemon, which showed the keyboard by itself.
    machine.wait_until_succeeds("grep -F '\"visible\":true' /tmp/osk-events.log", timeout=120)

    # Type a URL, Tab to the password field, type a password with symbols, press Enter.
    URL = "https://example.com/a?b=1"
    PW = "P@ss-w0rd!"
    assert call("keys.type", {"text": URL}).get("untypeable", []) == []
    machine.wait_until_succeeds(f"grep -F {shlex.quote(json.dumps(URL))} /tmp/posted.log", timeout=60)
    call("keys.action", {"action": "tab"})
    call("keys.type", {"text": PW})
    call("keys.action", {"action": "enter"})
    machine.wait_until_succeeds("grep -F '\"submit\"' /tmp/posted.log", timeout=60)
    machine.screenshot("typing-after")

    events = posted()
    print(events)
    last = {}
    for e in events:
        last[e["id"]] = e["value"]
    assert last["t"] == URL, last
    assert last["p"] == PW, last
    # Order: the text field was focused first, Tab moved to the password field, Enter submitted.
    ids = [(e["id"], e["value"]) for e in events if e["id"] in ("focus", "submit")]
    assert ids == [("focus", "t"), ("focus", "p"), ("submit", "1")], ids
    # Nothing else was typed into the text field after the Tab (no leaked characters).
    assert [e["value"] for e in events if e["id"] == "t"][-1] == URL
    machine.wait_for_text("example.com", timeout=timedelta(seconds=30))
  '';
}
