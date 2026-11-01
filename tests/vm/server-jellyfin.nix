# Jellyfin server (design/server.md, M10 step 2) on a built box with `jellyfin-server` enabled:
#   - hinteros-jellyfin-setup ran before jellyfin.service: `setup-done`, `admin-password` and
#     `api-key` are 0600 root in a 0700 root directory, no `setup-started` left;
#   - the wizard is complete (System/Info/Public, the server name is the hostname) and closed
#     (/Startup/User wants authentication); `admin` logs in with the stored password, not with
#     another; the API key works, no key gets 401;
#   - 8096 answers a LAN node from an address in hinteros.ssh.allowFrom, not from one outside it
#     (198.51.100.0/24 on the same link); the nft rule is there;
#   - /srv/media: 2775 root:hinteros-media with the default ACL; the admin account writes there,
#     jellyfin reads what it copied in;
#   - Jellyfin's data deleted (`setup-done` kept): the setup starts again; interrupted while its
#     Jellyfin runs, the next start begins from scratch (new password, old data gone). A probe in
#     the host's network namespace (and one on the LAN node) never sees the wizard open during
#     either run;
#   - a set-up Jellyfin without our markers (set up by hand) is never deleted: the setup fails,
#     jellyfin.service does not start, nothing listens on 8096.
{ self, pkgs }:
let
  inherit (pkgs) lib;

  adminHash = pkgs.runCommand "admin-pw" { nativeBuildInputs = [ pkgs.mkpasswd ]; } ''
    echo -n "$(mkpasswd -m sha-512 -S saltsaltsalt hunter2)" > $out
  '';
in
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-server-jellyfin";
  meta.timeout = 3600;

  nodes = {
    machine = {
      imports = [
        ../../nixos/modules
        self.nixosModules.catalog
        ../../nixos/vm
      ];
      hinteros = {
        state = {
          schemaVersion = 2;
          base = "unstable";
          stateVersion = "25.11";
          profiles = [ { id = "p1"; } ];
          requirements = [ ];
          services = [ ];
        };
        profiles.greeter.enable = false;
        catalog.services = [ "jellyfin-server" ];
        admin = {
          enable = true;
          hashedPasswordFile = "${adminHash}";
        };
      };
      environment.systemPackages = [
        pkgs.jq
        pkgs.acl
      ];
      virtualisation = {
        memorySize = lib.mkForce 2560;
        # Jellyfin refuses to start with less than 2 GiB free in its data directory.
        diskSize = 4096;
      };
    };
    client = {
      environment.systemPackages = [ pkgs.jq ];
    };
  };

  testScript =
    { nodes, ... }:
    ''
      import json

      MACHINE = "${nodes.machine.networking.primaryIPAddress}"
      S = "/var/lib/hinteros/services/jellyfin-server"
      API = "http://127.0.0.1:8096"
      CLIENT_HDR = "Authorization: MediaBrowser Client=\"test\", Device=\"test\", DeviceId=\"test\", Version=\"1\""

      start_all()
      machine.wait_for_unit("multi-user.target")
      client.wait_for_unit("multi-user.target")

      def wait_jellyfin():
          try:
              machine.wait_for_unit("jellyfin.service", timeout=600)
              machine.wait_until_succeeds(f"curl -fsS {API}/System/Info/Public | jq -e .Id", timeout=600)
          except Exception:
              print(machine.execute("systemctl status hinteros-jellyfin-setup jellyfin --no-pager; "
                                    "journalctl -u hinteros-jellyfin-setup --no-pager | grep -v '^ *at ' | tail -60")[1])
              raise

      def login(password_file):
          return (f"jq -n --rawfile pw {password_file} '{{Username: \"admin\", Pw: $pw}}' | "
                  f"curl -fsS -X POST -H 'Content-Type: application/json' -H '{CLIENT_HDR}' "
                  f"--data-binary @- {API}/Users/AuthenticateByName | jq -er .AccessToken")

      def check_files():
          machine.succeed(f"test -e {S}/setup-done")
          machine.fail(f"test -e {S}/setup-started")
          for d in (S, "/var/lib/hinteros/services"):
              got = machine.succeed(f"stat -c '%a %U %G' {d}").strip()
              assert got == "700 root root", (d, got)
          for f in ("admin-password", "api-key"):
              got = machine.succeed(f"stat -c '%a %U %G' {S}/{f}").strip()
              assert got == "600 root root", (f, got)
              machine.succeed(f"test -s {S}/{f}")

      wait_jellyfin()

      with subtest("setup files"):
          check_files()
          machine.succeed("systemctl is-active hinteros-jellyfin-setup.service")

      with subtest("wizard complete and closed"):
          info = json.loads(machine.succeed(f"curl -fsS {API}/System/Info/Public"))
          print(info)
          assert info["StartupWizardCompleted"] is True, info
          assert info["ServerName"] == machine.succeed("hostname").strip(), info
          code = machine.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' {API}/Startup/User").strip()
          assert code in ("401", "403"), code
          code = machine.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' -X POST -H 'Content-Type: application/json' -d '{{\"Name\":\"x\",\"Password\":\"y\"}}' {API}/Startup/User").strip()
          assert code in ("401", "403"), code
          machine.succeed("grep -q '<IsStartupWizardCompleted>true</IsStartupWizardCompleted>' /var/lib/jellyfin/config/system.xml")

      with subtest("admin login and API key"):
          machine.succeed(login(f"{S}/admin-password"))
          machine.succeed("printf wrong > /tmp/wrong")
          machine.fail(login("/tmp/wrong"))
          users = json.loads(machine.succeed(
              f"curl -fsS -H \"Authorization: MediaBrowser Token=\\\"$(cat {S}/api-key)\\\"\" {API}/Users"))
          admins = [u["Name"] for u in users if u["Policy"]["IsAdministrator"]]
          assert admins == ["admin"], users
          machine.succeed(f"curl -fsS -H \"Authorization: MediaBrowser Token=\\\"$(cat {S}/api-key)\\\"\" {API}/System/Info | jq -e .Id")
          code = machine.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' {API}/System/Info").strip()
          assert code == "401", code

      with subtest("LAN only"):
          machine.succeed("ip addr add 198.51.100.1/24 dev eth1")
          client.succeed("ip addr add 198.51.100.2/24 dev eth1")
          client.succeed("ping -c1 -W5 198.51.100.1")
          client.succeed(f"curl -fsS -m 10 http://{MACHINE}:8096/System/Info/Public | jq -e .Id")
          client.fail("curl -fsS -m 5 http://198.51.100.1:8096/System/Info/Public")
          rules = machine.succeed("nft list ruleset")
          assert 'tcp dport 8096 accept comment "hinteros-server"' in rules, rules
          assert 'udp dport 7359 accept comment "hinteros-server"' in rules, rules

      with subtest("/srv/media"):
          assert machine.succeed("stat -c '%a %U %G' /srv/media").strip() == "2775 root hinteros-media"
          acl = machine.succeed("getfacl -p /srv/media")
          print(acl)
          assert "default:group:hinteros-media:r-x" in acl, acl
          for u in ("jellyfin", "hinteros-admin"):
              assert "hinteros-media" in machine.succeed(f"id -nG {u}").split(), u
          assert "render" in machine.succeed("id -nG jellyfin").split()
          machine.succeed("runuser -u hinteros-admin -- mkdir /srv/media/Movies")
          machine.succeed("runuser -u hinteros-admin -- sh -c 'umask 077; echo film > /srv/media/Movies/a.mkv'")
          assert machine.succeed("stat -c %G /srv/media/Movies/a.mkv").strip() == "hinteros-media"
          assert machine.succeed("runuser -u jellyfin -- cat /srv/media/Movies/a.mkv").strip() == "film"
          machine.fail("runuser -u hinteros-p1 -- touch /srv/media/c")

      def start_probes():
          # Every 0.3 s: what the host namespace and the LAN see on 8096.
          probe = ("while true; do curl -s -m 2 {u}/System/Info/Public; echo; "
                   "curl -s -m 2 -o /dev/null -w '%{{http_code}}\\n' {u}/Startup/User; sleep 0.3; done")
          machine.succeed("rm -f /tmp/probe.log; systemd-run --unit probe -p StandardOutput=file:/tmp/probe.log "
                          f"sh -c \"{probe.format(u=API)}\"")
          client.succeed("rm -f /tmp/probe.log; systemd-run --unit probe -p StandardOutput=file:/tmp/probe.log "
                         f"sh -c \"{probe.format(u='http://' + MACHINE + ':8096')}\"")

      def stop_probes():
          for m in (machine, client):
              m.succeed("systemctl stop probe")
              log = m.succeed("cat /tmp/probe.log")
              lines = log.splitlines()
              assert len(lines) > 10, log
              assert '"StartupWizardCompleted":false' not in log, log
              assert "200" not in [l.strip() for l in lines if len(l.strip()) == 3], log
              assert "204" not in [l.strip() for l in lines if len(l.strip()) == 3], log

      with subtest("data deleted, setup interrupted: starts from scratch, wizard never reachable"):
          old = machine.succeed(f"cat {S}/admin-password")
          machine.succeed("systemctl stop jellyfin.service hinteros-jellyfin-setup.service")
          machine.succeed("find /var/lib/jellyfin -mindepth 1 -delete")
          start_probes()
          machine.succeed("systemctl start --no-block hinteros-jellyfin-setup.service")
          machine.wait_until_succeeds(f"test -e {S}/setup-started", timeout=120)
          machine.fail(f"test -e {S}/setup-done")
          machine.wait_until_succeeds("pgrep -u jellyfin", timeout=120)
          machine.wait_until_succeeds("test -e /var/lib/jellyfin/config/system.xml", timeout=600)
          machine.succeed("systemctl stop hinteros-jellyfin-setup.service")
          machine.wait_until_fails("pgrep -u jellyfin", timeout=30)
          machine.succeed(f"test -e {S}/setup-started")
          machine.succeed("touch /var/lib/jellyfin/leftover")
          machine.succeed("systemctl start --no-block jellyfin.service")
          wait_jellyfin()
          stop_probes()
          check_files()
          machine.fail("test -e /var/lib/jellyfin/leftover")
          assert machine.succeed(f"cat {S}/admin-password") != old
          machine.succeed(login(f"{S}/admin-password"))
          machine.fail(f"echo -n '{old}' > /tmp/old; " + login("/tmp/old"))

      with subtest("a Jellyfin set up by hand is kept and stays off"):
          machine.succeed("systemctl stop jellyfin.service hinteros-jellyfin-setup.service")
          machine.succeed(f"mv {S}/setup-done /tmp/setup-done")
          machine.fail("systemctl start jellyfin.service")
          machine.succeed("systemctl is-failed hinteros-jellyfin-setup.service")
          machine.fail("systemctl is-active jellyfin.service")
          machine.fail(f"curl -s -m 5 {API}/System/Info/Public")
          client.fail(f"curl -s -m 5 http://{MACHINE}:8096/System/Info/Public")
          machine.succeed("test -e /var/lib/jellyfin/config/system.xml")
          machine.succeed("journalctl -u hinteros-jellyfin-setup.service | grep -q 'HinterOS did not set up'")
          # With its marker back it starts again, data intact.
          machine.succeed(f"mv /tmp/setup-done {S}/setup-done")
          machine.succeed("systemctl reset-failed hinteros-jellyfin-setup.service")
          machine.succeed("systemctl start jellyfin.service")
          wait_jellyfin()
          machine.succeed(login(f"{S}/admin-password"))
    '';
}
