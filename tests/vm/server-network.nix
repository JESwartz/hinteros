# Plex, Tailscale and Cloudflare Tunnel (M10) on a built box with SSH on:
#   - firewall from the entries' `ports`: Plex's 32400/tcp and Tailscale's 41641/udp open to all
#     sources (a LAN node reaches 32400 also from 198.51.100.0/24, outside allowFrom), Plex's GDM
#     ports (32410, 32412-32414/udp) to the local networks only, and on tailscale0 the `lan`
#     ports plus SSH; SSH itself still only from the local networks;
#   - plex in render, video and hinteros-media; tailscaled runs with its socket; `tailscale` is on
#     the PATH of hinteros-system and hinteros-job@;
#   - hinteros-system may use IP to loopback only (a process in its cgroup reaches Plex on
#     127.0.0.1, not the LAN node);
#   - hinteros-cloudflared does not start without a token; with a (well-formed, dummy) token it
#     starts, loads its nftables table and serves metrics on 127.0.0.1:20241 (no internet here,
#     so it never connects); from its cgroup the box's own addresses are reachable on the
#     servers' ports only (Plex yes, sshd on the LAN address or loopback no) and other hosts
#     still are (the LAN node's sshd); the table survives a firewall reload.
# Plex Media Server is unfree and downloads from plex.tv, and VM tests refuse a nixpkgs config:
# the plex package is a stub that answers HTTP on 32400 and the allowlist is emptied. The real
# package and its allowlisting are checked by the server-eval test.
{ self, pkgs }:
let
  inherit (pkgs) lib;

  adminHash = pkgs.runCommand "admin-pw" { nativeBuildInputs = [ pkgs.mkpasswd ]; } ''
    echo -n "$(mkpasswd -m sha-512 -S saltsaltsalt hunter2)" > $out
  '';

  plexReply = pkgs.writeShellScript "plex-reply" ''
    printf 'HTTP/1.0 200 OK\r\nContent-Length: 4\r\n\r\nplex'
  '';
  plexStub = pkgs.writeShellScriptBin "plexmediaserver" ''
    exec ${lib.getExe pkgs.socat} TCP-LISTEN:32400,reuseaddr,fork EXEC:${plexReply}
  '';
in
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-server-network";
  meta.timeout = 1800;

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
          settings.ssh.enable = true;
          profiles = [ { id = "p1"; } ];
          requirements = [ ];
          services = [ ];
        };
        profiles.greeter.enable = false;
        catalog.services = [
          "plex-media-server"
          "tailscale"
          "cloudflare-tunnel"
        ];
        admin = {
          enable = true;
          hashedPasswordFile = "${adminHash}";
        };
        unfreeAllowlist = lib.mkForce [ ];
      };
      services.plex.package = lib.mkForce plexStub;
      environment.systemPackages = [ pkgs.jq ];
      virtualisation.memorySize = lib.mkForce 2048;
    };
    client = {
      services.openssh.enable = true;
    };
  };

  testScript =
    { nodes, ... }:
    ''
      import base64, json

      MACHINE = "${nodes.machine.networking.primaryIPAddress}"
      CLIENT = "${nodes.client.networking.primaryIPAddress}"
      # The set_token job's root copy is what the unit loads (the service's own file is not).
      TOKEN_FILE = "/var/lib/hinteros-root/cloudflare-tunnel-token"

      start_all()
      machine.wait_for_unit("multi-user.target")
      client.wait_for_unit("sshd.service")
      machine.wait_for_unit("sshd.service")
      machine.wait_for_unit("plex.service")
      machine.wait_for_open_port(32400)
      machine.succeed("ip addr add 198.51.100.1/24 dev eth1")
      client.succeed("ip addr add 198.51.100.2/24 dev eth1")
      client.succeed("ping -c1 -W5 198.51.100.1")

      def tcp_open(node, host, port):
          return node.execute(f"timeout 5 bash -c 'exec 3<>/dev/tcp/{host}/{port}'")[0] == 0

      with subtest("firewall from ports"):
          rules = machine.succeed("nft list ruleset")
          print(rules)
          lan = [l.strip() for l in rules.splitlines() if 'comment "hinteros-server"' in l]
          assert len(lan) == 2, lan
          for l in lan:
              assert "udp dport { 32410, 32412-32414 }" in l or "udp dport { 32410, 32412, 32413, 32414 }" in l, l
          # nft prints set elements sorted.
          assert lan[0].startswith("ip saddr { 10.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 }"), lan
          assert lan[1].startswith("ip6 saddr { fc00::/7, fe80::/10 }"), lan
          ts = [l.strip() for l in rules.splitlines() if 'iifname "tailscale0"' in l]
          print(ts)
          assert any("tcp dport 22 " in l for l in ts), ts
          assert any("32410" in l for l in ts), ts
          assert not any("32400" in l for l in ts), ts
          # Plex: all sources; SSH: local networks only.
          assert client.succeed(f"curl -fsS -m 10 http://{MACHINE}:32400/").strip() == "plex"
          assert client.succeed("curl -fsS -m 10 http://198.51.100.1:32400/").strip() == "plex"
          assert tcp_open(client, MACHINE, 22)
          assert not tcp_open(client, "198.51.100.1", 22)

      with subtest("plex and tailscale"):
          groups = machine.succeed("id -nG plex").split()
          for g in ("render", "video", "hinteros-media"):
              assert g in groups, groups
          machine.wait_for_unit("tailscaled.service")
          machine.wait_until_succeeds("test -S /run/tailscale/tailscaled.sock")
          for unit in ("hinteros-system.service", "hinteros-job@test.service"):
              env = machine.succeed(f"systemctl show {unit} -p Environment")
              assert "tailscale" in env, (unit, env)
          machine.succeed("tailscale status --json | jq -e .BackendState")

      with subtest("hinteros-system: loopback only"):
          show = machine.succeed("systemctl show hinteros-system.service -p RestrictAddressFamilies -p IPAddressDeny -p IPAddressAllow")
          print(show)
          families = [l for l in show.splitlines() if l.startswith("RestrictAddressFamilies=")][0]
          assert set(families.split("=", 1)[1].split()) == {"AF_INET", "AF_INET6", "AF_UNIX"}, show
          assert "IPAddressDeny=0.0.0.0/0 ::/0" in show, show
          assert "127.0.0.0/8" in show and "::1/128" in show, show
          cg = "/sys/fs/cgroup/system.slice/hinteros-system.service/cgroup.procs"
          machine.succeed(f"sh -c 'echo $$ > {cg}; exec curl -fsS -m 5 http://127.0.0.1:32400/'")
          machine.fail(f"sh -c 'echo $$ > {cg}; exec timeout 5 bash -c \"exec 3<>/dev/tcp/{CLIENT}/22\"'")
          assert tcp_open(machine, CLIENT, 22)
          machine.fail(f"sh -c 'echo $$ > {cg}; exec curl -fsS -m 5 http://{MACHINE}:32400/'")

      with subtest("cloudflared: no token, no tunnel"):
          machine.succeed("systemctl start hinteros-cloudflared.service")
          assert machine.succeed("systemctl show -p ConditionResult --value hinteros-cloudflared.service").strip() == "no"
          machine.fail("systemctl is-active hinteros-cloudflared.service")
          machine.fail("nft list table inet hinteros_cloudflared")

      with subtest("cloudflared: with a token"):
          secret = base64.b64encode(b"s" * 32).decode()
          token = base64.b64encode(json.dumps({
              "a": "0123456789abcdef0123456789abcdef",
              "t": "5c7f3a3e-1a2b-4c5d-8e9f-0a1b2c3d4e5f",
              "s": secret,
          }).encode()).decode()
          got = machine.succeed("stat -c '%a %U %G' /var/lib/hinteros/services/cloudflare-tunnel").strip()
          assert got == "700 hinteros-system hinteros", got
          machine.succeed(f"(umask 077; printf %s '{token}' > {TOKEN_FILE})")
          machine.succeed("systemctl start hinteros-cloudflared.service")
          machine.wait_until_succeeds("systemctl is-active hinteros-cloudflared.service")
          table = machine.succeed("nft list table inet hinteros_cloudflared")
          print(table)
          assert 'socket cgroupv2 level 2 "system.slice/hinteros-cloudflared.service" jump cloudflared' in table, table
          assert "fib daddr type local tcp dport 32400 accept" in table, table
          assert "fib daddr type local drop" in table, table
          # Metrics answer (the replies leave its cgroup): not ready, it has no internet.
          machine.wait_until_succeeds("curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:20241/ready | grep -qE '^(200|503)$'", timeout=60)
          print(machine.succeed("journalctl -u hinteros-cloudflared.service --no-pager | tail -20"))

      with subtest("cloudflared: egress filter"):
          cg = "/sys/fs/cgroup/system.slice/hinteros-cloudflared.service/cgroup.procs"
          def from_tunnel(host, port):
              return f"sh -c 'echo $$ > {cg} && exec timeout 5 bash -c \"exec 3<>/dev/tcp/{host}/{port}\"'"
          # The unit may be between restarts (no cgroup): retry until the probe really ran.
          machine.wait_until_succeeds(from_tunnel(MACHINE, 32400), timeout=60)
          machine.wait_until_succeeds(from_tunnel("127.0.0.1", 32400), timeout=60)
          machine.wait_until_succeeds(from_tunnel(CLIENT, 22), timeout=60)
          for host in (MACHINE, "127.0.0.1"):
              status, out = machine.execute(f"sh -c 'echo $$ > {cg} && echo joined && exec timeout 5 bash -c \"exec 3<>/dev/tcp/{host}/22\"'")
              assert "joined" in out and status != 0, (host, status, out)
          # Outside the tunnel's cgroup the box's sshd is still reachable.
          assert tcp_open(machine, MACHINE, 22)
          # A firewall reload keeps the table.
          machine.succeed("systemctl restart nftables.service")
          machine.succeed("nft list table inet hinteros_cloudflared")

      with subtest("cloudflared: token removed"):
          machine.succeed(f"systemctl stop hinteros-cloudflared.service; rm {TOKEN_FILE}")
          machine.succeed("systemctl start hinteros-cloudflared.service")
          machine.fail("systemctl is-active hinteros-cloudflared.service")
    '';
}
