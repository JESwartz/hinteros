# The admin password flow, end to end with the real components: the launcher's side (a client of
# the session daemon's socket that says hello as `hinteros-launcher`) calls `system.ssh.set`, the
# session daemon relays it, hinteros-system asks polkitd for `org.hinteros.system.ssh`
# (auth_admin) with interaction allowed, polkit finds the session daemon's registered
# authentication agent, which sends `authentication_requested` to the launcher, takes the password
# from `auth.respond` and checks it with polkit's socket-activated helper (the session unit keeps
# NoNewPrivileges, so the setuid helper cannot work) and PAM against the real admin account.
# A wrong password lowers attempts_left, three fail the request, auth.cancel gives
# authentication_required, a client not named hinteros-launcher can neither see nor answer the
# prompt, and the right password starts the job that turns sshd on.
#
# STUBBED: evaluating and building the new system (see stub-nix.nix); the "new system" is a
# specialisation of the VM with `hinteros.ssh.enable`. The switch to it is real.
{ self, pkgs }:
let
  adminPassword = "correct horse battery";
  wrongPassword = "not the password";
  adminHash = pkgs.runCommand "admin-hash" { nativeBuildInputs = [ pkgs.mkpasswd ]; } ''
    mkpasswd -m sha-512 -S saltsaltsalt ${pkgs.lib.escapeShellArg adminPassword} > $out
  '';
in
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-polkit-agent";
  meta.timeout = 1800;

  nodes.machine =
    { config, lib, ... }:
    {
      imports = [ (import ./system/node.nix { inherit self pkgs; }) ];

      hinteros.admin = {
        enable = true;
        hashedPasswordFile = "${adminHash}";
      };
      systemd.services."hinteros-job@".path = lib.mkBefore [
        (import ./system/stub-nix.nix {
          inherit pkgs;
          nix = config.nix.package;
        })
      ];
      boot.loader.grub.enable = lib.mkForce false;

      specialisation.ssh-on.configuration.hinteros.ssh.enable = true;
    };

  testScript = ''
    import json

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("hinteros-system.service")
    machine.wait_for_unit("greetd.service")
    machine.wait_until_succeeds("loginctl list-sessions --no-legend | grep -w hinteros-p1")
    machine.wait_until_succeeds("test -S /run/hinteros/system.sock")
    uid = machine.succeed("id -u hinteros-p1").strip()
    machine.wait_until_succeeds(f"test -S /run/user/{uid}/hinteros/session.sock")

    def rpc(method, params=None):
        out = machine.succeed(f"runuser -u hinteros-p1 -- python3 /etc/hinteros-test/rpc.py {method} '{json.dumps(params or {})}'")
        return json.loads(out)["response"]

    # The launcher may start a job of its own at startup (an update check); let it finish.
    for _ in range(60):
        if not [j for j in rpc("jobs.list")["result"]["jobs"] if j["state"] == "running"]:
            break
        machine.sleep(1)
    machine.sleep(3)

    with subtest("polkit's agent helper socket is on, the session unit keeps NoNewPrivileges"):
        machine.succeed("systemctl is-active polkit-agent-helper.socket")
        machine.succeed("test -S /run/polkit/agent-helper.socket")
        assert machine.succeed(f"runuser -u hinteros-p1 -- env XDG_RUNTIME_DIR=/run/user/{uid} systemctl --user show -p NoNewPrivileges --value hinteros-session.service").strip() == "yes"
        machine.succeed("pkaction --action-id org.hinteros.system.apps --verbose | grep -q 'implicit active:.*no'")
        assert "remote login (SSH)" in machine.succeed("pkaction --action-id org.hinteros.system.ssh --verbose")
        machine.fail("systemctl is-active sshd.service")
        # The daemon registered its agent: polkitd logs it, and the daemon logs no failure.
        machine.succeed("journalctl _SYSTEMD_USER_UNIT=hinteros-session.service --no-pager | grep 'registered the polkit authentication agent'")

    machine.succeed("mkdir -p /run/stub")
    spec = machine.succeed("readlink -f /run/current-system/specialisation/ssh-on").strip()
    orig = machine.succeed("readlink -f /run/current-system").strip()
    machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {orig}")
    machine.succeed(f"echo {spec} > /run/stub/toplevel")

    with subtest("without a launcher the system service says authentication_required"):
        # The system socket directly, as hinteros-p1: no agent is involved, polkit has none for it.
        r = rpc("ssh.set", {"enabled": True})
        print(r)
        assert r["error"]["code"] == 3012, r

    with subtest("wrong passwords, a client that is not the launcher, cancel, then the right password"):
        out = machine.succeed("runuser -u hinteros-p1 -- python3 /etc/hinteros-test/polkit_agent.py '${adminPassword}' '${wrongPassword}' 2>&1")
        print(out)
        job = out.strip().splitlines()[-1]

    with subtest("sshd is on, state.json has it, the audit trail has the password-authorized change"):
        machine.wait_until_succeeds("systemctl is-active sshd.service")
        state = json.loads(machine.succeed("cat /etc/hinteros/state.json"))
        assert state["settings"]["ssh"]["enable"] is True, state
        assert rpc("settings.get")["result"]["settings"]["ssh"] == {"enabled": True}
        j = rpc("jobs.get", {"job_id": job})["result"]["job"]
        assert j["state"] == "succeeded", j
        machine.fail("journalctl --no-pager | grep -F '${adminPassword}'")
        machine.fail("journalctl --no-pager | grep -F '${wrongPassword}'")
        out = machine.succeed("journalctl -o json --no-pager HINTEROS_AUDIT=1")
        entries = [json.loads(l) for l in out.splitlines() if l.strip()]
        print([(e.get("HINTEROS_ACTION"), e.get("HINTEROS_DECISION"), e.get("HINTEROS_OUTCOME")) for e in entries][-8:])
        assert any(e.get("HINTEROS_ACTION") == "org.hinteros.system.ssh" and e.get("HINTEROS_DECISION") == "allowed" for e in entries), entries[-3:]
  '';
}
