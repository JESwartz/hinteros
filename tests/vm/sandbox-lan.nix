# The `lan` permission (design/sandbox.md): a sandboxed app without it reaches neither the home
# network nor this box's own services, only DNS and the internet. Three nodes:
#   - router: the home router (192.168.1.3, 2001:db8:1::3), the box's gateway and nameserver
#     (dnsmasq: inet.test is 203.0.113.2), with a web server on 8080, forwarding to ...
#   - inet: "the internet" (203.0.113.2, a documentation address behind the router), web server
#     on 8080.
#   - machine: the box, with a "Jellyfin server" on 127.0.0.1:8096 and [::1]:8096.
# A probe app records from inside its sandbox what it reaches. Without `lan`: no TCP to the
# router (IPv4, its on-link IPv6 address, its link-local address) or to loopback, no UDP to the
# router, to multicast or to broadcast; DNS to the router (UDP and TCP) and the internet work.
# With `lan` everything works; denying it (apps.set_permission) applies at the next start.
# The filter survives a session daemon restart (a new cgroup) and fails closed: without the
# system service no app without `lan` starts, an app with it does; it starts once the service is
# back.
{ self, pkgs }:
let
  # Writes one `<check>=yes|no` line per check to $HOME/probe.txt, then waits to be closed.
  # $HOME/targets (written by the test) has the router's link-local address.
  probe = pkgs.writeShellApplication {
    name = "hinteros-lan-probe";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.dnsutils
      pkgs.socat
    ];
    text = ''
      check() {
        local name="$1"
        shift
        if "$@" >/dev/null 2>&1; then echo "$name=yes"; else echo "$name=no"; fi
      }
      get() {
        curl -sf -m 5 -o /dev/null "$@"
      }
      send() {
        echo x | timeout 5 socat -u - "$1"
      }
      dns() {
        test "$(dig +short +time=3 +tries=1 "$@" inet.test)" = 203.0.113.2
      }
      # shellcheck disable=SC1091
      . "$HOME/targets"
      {
        check lan_http get http://192.168.1.3:8080/
        check lan6_http get "http://[2001:db8:1::3]:8080/"
        check ll6_http get "http://[''${ROUTER_LL}%eth1]:8080/"
        check loop_http get http://127.0.0.1:8096/
        check loop6_http get "http://[::1]:8096/"
        check udp_lan send UDP-SENDTO:192.168.1.3:9999
        check mcast send UDP-SENDTO:224.0.0.251:5353
        check bcast send UDP-SENDTO:255.255.255.255:9999,broadcast
        check dns dns
        check dns_tcp dns +tcp
        check inet_http get http://203.0.113.2:8080/
        check inet_name get http://inet.test:8080/
      } > "$HOME/probe.tmp"
      mv "$HOME/probe.tmp" "$HOME/probe.txt"
      exec sleep infinity
    '';
  };
  web = port: {
    description = "test web server";
    wantedBy = [ "multi-user.target" ];
    # Both families (a dual-stack socket).
    serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server --bind :: --directory /etc ${toString port}";
  };
in
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-sandbox-lan";

  nodes = {
    router = {
      virtualisation.vlans = [
        1
        2
      ];
      networking = {
        firewall.enable = false;
        interfaces.eth2.ipv4.addresses = pkgs.lib.mkForce [
          {
            address = "203.0.113.1";
            prefixLength = 24;
          }
        ];
      };
      boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
      services.dnsmasq = {
        enable = true;
        resolveLocalQueries = false;
        settings = {
          address = "/inet.test/203.0.113.2";
          no-resolv = true;
          interface = "eth1";
        };
      };
      systemd.services.web = web 8080;
    };

    inet = {
      virtualisation.vlans = [ 2 ];
      networking = {
        firewall.enable = false;
        interfaces.eth1.ipv4 = {
          addresses = pkgs.lib.mkForce [
            {
              address = "203.0.113.2";
              prefixLength = 24;
            }
          ];
          routes = [
            {
              address = "192.168.1.0";
              prefixLength = 24;
              via = "203.0.113.1";
            }
          ];
        };
      };
      systemd.services.web = web 8080;
    };

    machine = _: {
      imports = [
        self.nixosModules.session
        self.nixosModules.daemon
        self.nixosModules.apps
        ../../nixos/vm
      ];

      networking = {
        defaultGateway = "192.168.1.3";
        nameservers = [ "192.168.1.3" ];
      };

      # "Jellyfin" on this box: loopback only.
      systemd.services.local-web = {
        description = "a server on this box";
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = pkgs.writeShellScript "local-web" ''
          ${pkgs.python3}/bin/python3 -m http.server --bind 127.0.0.1 --directory /etc 8096 &
          exec ${pkgs.python3}/bin/python3 -m http.server --bind ::1 --directory /etc 8096
        '';
      };

      hinteros.apps = {
        jellyfin.enable = false;
        youtube.enable = false;
        firefox.enable = false;
        nolan = {
          enable = true;
          name = "No LAN";
          package = probe;
        };
        withlan = {
          enable = true;
          name = "With LAN";
          package = probe;
          permissions.lan = "optional";
        };
      };

      environment.systemPackages = [
        pkgs.socat
        pkgs.curl
        pkgs.nftables
      ];
    };
  };

  testScript = ''
    import json
    import shlex

    start_all()
    router.wait_for_unit("dnsmasq.service")
    router.wait_for_unit("web.service")
    inet.wait_for_unit("web.service")
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("local-web.service")
    machine.wait_until_succeeds("pgrep -u hinteros -f '/bin/cage '")
    machine.wait_for_unit("hinteros-session.service", "hinteros")
    uid = machine.succeed("id -u hinteros").strip()
    sock = f"/run/user/{uid}/hinteros/session.sock"
    machine.wait_until_succeeds(f"test -S {sock}")
    home = "/home/hinteros"
    sandboxes = f"{home}/.local/share/hinteros/sandbox"
    unit_cg = f"/sys/fs/cgroup/user.slice/user-{uid}.slice/user@{uid}.service/app.slice/hinteros-session.service"
    user = f"runuser -u hinteros -- env XDG_RUNTIME_DIR=/run/user/{uid}"

    # Outside any sandbox the box reaches all of them.
    machine.succeed("curl -sf -m 5 -o /dev/null http://192.168.1.3:8080/")
    machine.succeed("curl -sf -m 5 -o /dev/null http://203.0.113.2:8080/")
    machine.succeed("curl -sf -m 5 -o /dev/null http://127.0.0.1:8096/")
    router_ll = router.succeed(
        "ip -6 -o addr show dev eth1 scope link | awk '{print $4}' | cut -d/ -f1"
    ).strip()
    machine.wait_until_succeeds(f"curl -sf -m 5 -o /dev/null 'http://[{router_ll}%eth1]:8080/'")
    machine.wait_until_succeeds("curl -sf -m 5 -o /dev/null 'http://[2001:db8:1::3]:8080/'")

    def rpc(*msgs, wait=2):
        hello = {"jsonrpc": "2.0", "id": 0, "method": "hello",
                 "params": {"api_version": "0.18", "client": {"name": "lan-test", "version": "0"}}}
        payload = "".join(json.dumps(m) + "\n" for m in (hello, *msgs))
        cmd = f"(printf %s {shlex.quote(payload)}; sleep {wait}) | socat -t{wait} - UNIX-CONNECT:{sock}"
        out = machine.succeed(f"runuser -u hinteros -- sh -c {shlex.quote(cmd)}")
        replies = [json.loads(line) for line in out.splitlines() if line.strip()]
        assert "error" not in replies[0], replies[0]
        return replies

    def call(method, params=None):
        return next(r for r in rpc({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}) if r.get("id") == 1)

    def ok(method, params=None):
        reply = call(method, params)
        assert "error" not in reply, reply
        return reply["result"]

    def run(app):
        """Launch `app`, return its probe results, close it."""
        out = f"{sandboxes}/{app}/probe.txt"
        machine.succeed(
            f"runuser -u hinteros -- mkdir -p {sandboxes}/{app} && "
            f"echo ROUTER_LL={router_ll} | runuser -u hinteros -- tee {sandboxes}/{app}/targets && "
            f"rm -f {out}"
        )
        ok("apps.launch", {"id": app})
        machine.wait_until_succeeds(f"test -s {out}", timeout=90)
        res = dict(line.split("=", 1) for line in machine.succeed(f"cat {out}").split())
        print(app, res)
        ok("apps.close", {"id": app})
        machine.wait_until_fails("pgrep -u hinteros -f [h]interos-lan-probe", timeout=30)
        return res

    local = ["lan_http", "lan6_http", "ll6_http", "loop_http", "loop6_http", "udp_lan", "mcast", "bcast"]
    open_ = ["dns", "dns_tcp", "inet_http", "inet_name"]

    def expect(res, lan):
        for k in local:
            assert res[k] == ("yes" if lan else "no"), (k, res)
        for k in open_:
            assert res[k] == "yes", (k, res)

    def table():
        return machine.succeed("nft list table inet hinteros_lan")

    with subtest("the daemon's cgroups and the filter"):
        # The daemon in its leaf, nolan beside it.
        pid = machine.succeed(f"{user} systemctl --user show -p MainPID --value hinteros-session.service").strip()
        machine.succeed(f"grep -qx {pid} {unit_cg}/daemon/cgroup.procs")
        machine.succeed(f"test ! -s {unit_cg}/cgroup.procs")
        machine.succeed(f"test -d {unit_cg}/nolan")
        machine.wait_until_succeeds("nft list table inet hinteros_lan | grep -q 'uid " + uid + "'", timeout=60)
        t = table()
        assert f'"user.slice/user-{uid}.slice/user@{uid}.service/app.slice/hinteros-session.service/nolan"' in t, t
        assert "192.168.1.3" in t, t  # the nameserver
        assert "2001:db8:1::/64" in t, t  # on-link
        state = json.loads(machine.succeed("cat /run/hinteros/lan-filter.json"))
        assert state["cgroups"] == {uid: f"user.slice/user-{uid}.slice/user@{uid}.service/app.slice/hinteros-session.service/nolan"}, state

    with subtest("lan is listed only where an app declares it"):
        by_id = {a["id"]: a for a in ok("apps.list")["apps"]}
        assert by_id["nolan"]["permissions"] == [], by_id["nolan"]
        assert by_id["withlan"]["permissions"] == [{"name": "lan", "required": False, "granted": True}], by_id["withlan"]

    with subtest("without lan: no home network, no local services; DNS and the internet work"):
        expect(run("nolan"), lan=False)
        # The app ran in nolan.
        machine.succeed(f"test -f {sandboxes}/nolan/probe.txt")

    with subtest("with lan: everything"):
        expect(run("withlan"), lan=True)

    with subtest("lan denied: applies at the next start"):
        ok("apps.set_permission", {"id": "withlan", "permission": "lan", "granted": False})
        expect(run("withlan"), lan=False)
        ok("apps.set_permission", {"id": "withlan", "permission": "lan", "granted": True})

    with subtest("a session daemon restart: a new cgroup, filtered again"):
        old = machine.succeed(f"stat -c %i {unit_cg}/nolan").strip()
        machine.succeed(f"{user} systemctl --user restart hinteros-session.service")
        machine.wait_until_succeeds(f"test -S {sock}")
        machine.wait_until_succeeds(f"test -d {unit_cg}/nolan")
        new = machine.succeed(f"stat -c %i {unit_cg}/nolan").strip()
        assert new != old, (old, new)
        machine.wait_until_succeeds("journalctl -b -u hinteros-system | grep -c 'local network filter set' | grep -qx 2", timeout=60)
        expect(run("nolan"), lan=False)
        expect(run("withlan"), lan=True)

    with subtest("the nameservers change: the table follows"):
        machine.succeed("cp /etc/resolv.conf /tmp/resolv.conf.bak")
        machine.succeed("echo 'nameserver 192.168.1.53' > /etc/resolv.conf")
        machine.wait_until_succeeds("nft list set inet hinteros_lan dns4 | grep -q 192.168.1.53", timeout=30)
        machine.succeed("cat /tmp/resolv.conf.bak > /etc/resolv.conf")
        machine.wait_until_succeeds("nft list set inet hinteros_lan dns4 | grep -q 192.168.1.3", timeout=30)

    with subtest("fail closed: without the filter no app without lan starts"):
        machine.succeed("systemctl stop hinteros-system.service")
        machine.succeed(f"{user} systemctl --user restart hinteros-session.service")
        machine.wait_until_succeeds(f"test -S {sock}")
        machine.succeed("nft delete table inet hinteros_lan")
        err = call("apps.launch", {"id": "nolan"})
        assert err["error"]["code"] == 2002, err  # app_launch_failed
        assert "no local network filter" in err["error"]["message"], err
        machine.fail("pgrep -u hinteros -f [h]interos-lan-probe")
        # An app with lan does not need the filter.
        expect(run("withlan"), lan=True)
        # The service is back: the next launch asks again, then it starts.
        machine.succeed("systemctl start hinteros-system.service")
        # A launch asks again at once (it fails while the table is not loaded yet).
        call("apps.launch", {"id": "nolan"})
        machine.wait_until_succeeds("nft list table inet hinteros_lan | grep -q 'uid " + uid + "'", timeout=60)
        call("apps.close", {"id": "nolan"})
        machine.wait_until_fails("pgrep -u hinteros -f [h]interos-lan-probe", timeout=30)
        expect(run("nolan"), lan=False)

    with subtest("the session ends: the filter is cleared"):
        machine.succeed(f"{user} systemctl --user stop hinteros-session.service")
        machine.wait_until_succeeds("! nft list table inet hinteros_lan", timeout=30)
        state = json.loads(machine.succeed("cat /run/hinteros/lan-filter.json"))
        assert state["cgroups"] == {}, state
  '';
}
