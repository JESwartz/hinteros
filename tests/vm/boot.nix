# Boots the HinterOS test system and checks that the console session is up: the launcher
# is on screen and both daemons answer the socket API handshake.
# The test pkgs are read-only, so the overlay is applied to them here rather than
# through the overlay module.
{ self, pkgs }:
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-boot";
  enableOCR = true;

  nodes.machine = {
    imports = [
      self.nixosModules.session
      self.nixosModules.daemon
      ../../nixos/vm
    ];
    environment.systemPackages = [ pkgs.socat ];
  };

  testScript = ''
    import json
    import shlex
    from datetime import timedelta

    def hello_msg(version):
        return {"jsonrpc": "2.0", "id": 1, "method": "hello",
                "params": {"api_version": version, "client": {"name": "boot-test", "version": "0"}}}
    PING = {"jsonrpc": "2.0", "id": 2, "method": "ping", "params": {"nonce": "boot"}}

    def rpc(sock, version, as_user=None):
        """Send hello + ping on a unix socket, return the two decoded responses."""
        payload = "".join(json.dumps(m) + "\n" for m in (hello_msg(version), PING))
        cmd = f"(printf %s {shlex.quote(payload)}; sleep 1) | socat -t2 - UNIX-CONNECT:{sock}"
        if as_user:
            cmd = f"runuser -u {as_user} -- sh -c {shlex.quote(cmd)}"
        out = machine.succeed(cmd)
        replies = [json.loads(line) for line in out.splitlines() if line.strip()]
        assert len(replies) == 2, f"expected 2 replies, got {out!r}"
        hello, ping = replies
        assert "error" not in hello and hello["result"]["api_version"] == version, hello
        assert ping.get("result") == {"nonce": "boot"}, ping
        return hello["result"]["server"]["name"]

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("greetd.service")

    # Autologin: a login session for the session user exists.
    machine.wait_until_succeeds("loginctl list-sessions --no-legend | grep -w hinteros-p1")

    # The compositor (cage in the VM, see nixos/vm/default.nix) runs as that user
    # and the launcher is up inside it.
    machine.wait_until_succeeds("pgrep -u hinteros-p1 -f '/bin/cage '")
    machine.wait_until_succeeds("pgrep -u hinteros-p1 -f hinteros-launcher")

    # Still up a few seconds later, i.e. not crash-looping.
    machine.sleep(duration=timedelta(seconds=5))
    machine.succeed("pgrep -u hinteros-p1 -f '/bin/cage '")
    machine.succeed("pgrep -u hinteros-p1 -f hinteros-launcher")

    # The launcher draws its title; OCR must see it (retried until the timeout).
    machine.screenshot("session")
    machine.wait_for_text("HinterOS", timeout=timedelta(seconds=120))
    machine.screenshot("launcher")

    # The real launcher reached the real daemon: the home screen shows the Games row
    # (not the connecting, unreachable or version-mismatch notices), and the
    # daemon logged a successful 0.18 handshake from the launcher.
    machine.wait_for_text("Games", timeout=timedelta(seconds=60))
    screen = machine.get_screen_text()
    for bad in ("Can't reach", "versions don't match", "Connecting to the"):
        assert bad.lower() not in screen.lower(), f"launcher shows a connection notice ({bad}): {screen}"
    machine.wait_until_succeeds(
        "journalctl _SYSTEMD_USER_UNIT=hinteros-session.service --no-pager "
        "| grep -E 'handshake done client=hinteros-launcher .*api_version=0.21'"
    )

    # System service: socket in /run/hinteros, root:hinteros 0660, answers the API.
    machine.wait_for_unit("hinteros-system.service")
    machine.wait_until_succeeds("test -S /run/hinteros/system.sock")
    assert machine.succeed("stat -c '%a %U:%G' /run/hinteros/system.sock").strip() == "660 root:hinteros"
    machine.succeed("id -nG hinteros-p1 | tr ' ' '\\n' | grep -qx hinteros")
    assert rpc("/run/hinteros/system.sock", "0.12", as_user="hinteros-p1") == "hinteros-system"

    # Session daemon: user service of the session user, socket in its runtime dir, mode 0600.
    uid = machine.succeed("id -u hinteros-p1").strip()
    sock = f"/run/user/{uid}/hinteros/session.sock"
    machine.wait_until_succeeds(f"test -S {sock}")
    assert machine.succeed(f"stat -c '%a %U' {sock}").strip() == "600 hinteros-p1"
    assert rpc(sock, "0.21", as_user="hinteros-p1") == "hinteros-session"

    # Steam is not installed in this VM: the daemon lists no built-in Steam tile.
    apps_call = {"jsonrpc": "2.0", "id": 3, "method": "apps.list", "params": {}}
    payload = "".join(json.dumps(m) + "\n" for m in (hello_msg("0.21"), apps_call))
    out = machine.succeed(f"runuser -u hinteros-p1 -- sh -c {shlex.quote(f'(printf %s {shlex.quote(payload)}; sleep 1) | socat -t2 - UNIX-CONNECT:{sock}')}")
    listed = next(r for r in map(json.loads, out.splitlines()) if r.get("id") == 3)
    assert "steam" not in [a["id"] for a in listed["result"]["apps"]], listed
  '';
}
