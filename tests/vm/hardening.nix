# Hardening baseline on built systems. Non-dev boxes: the session user is not
# in wheel, cannot sudo, cannot talk to the nix daemon; the admin account's sudo always asks for
# its password; with SSH on (state.json) the admin logs in with username + password, from the
# local networks only (a global IPv6 source is refused), while the session user and root cannot;
# with SSH off nothing listens. Dev box: the separate key-based deploy user has passwordless sudo
# and nix, the session user still nothing. Kernel sysctls (kptr, dmesg, perf, BPF, io_uring,
# ptrace, protected files) have their hardened values; the session user cannot read dmesg.
#
# Profiles (one Unix user per profile, device access per seat):
# on a box in greeter mode (started after the others), every account (p1, p2, the guest)
# and the greeter are in no device group, wheel or systemd-journal, the accounts have homes 0700,
# no sudo, no nix daemon and no password; root-held state (profiles.json, PINs) is 0600/0700
# root; app profiles and the published links are root's; the sockets and the public view have
# the modes the design states; the guest's home is emptied at boot; logind kills a session's
# processes at once; device ACLs (uinput, DRM) name only the active profile, none at the picker;
# no profile has an ACL on a keyboard, can read one or can write to keyboard.sock (only the
# hinteros-keyboard unit reads keyboards); lingering is denied. A profile whose session is not in
# front (`chvt 2`) is frozen: a process of it that holds /dev/uinput from before the switch makes
# no progress, also across a restart of hinteros-system; back on its VT it is thawed.
{ self, pkgs }:
let
  inherit (pkgs) lib;
  profiles = import ./system/profiles.nix { inherit self pkgs; };
  keys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;

  adminHash = pkgs.runCommand "admin-pw" { nativeBuildInputs = [ pkgs.mkpasswd ]; } ''
    echo -n "$(mkpasswd -m sha-512 -S saltsaltsalt hunter2)" > $out
  '';

  stateFor = ssh: {
    schemaVersion = 2;
    base = "unstable";
    stateVersion = "25.11";
    settings.ssh.enable = ssh;
    profiles = [ { id = "p1"; } ];
    requirements = [ ];
    services = [ ];
  };

  box = extra: {
    imports = [
      ../../nixos/modules # everything but the overlay (the test pkgs already have it)
      self.nixosModules.catalog
      ../../nixos/vm
      extra
    ];
    # Autologin of p1 (greeter mode: the `greeter` node).
    hinteros.profiles.greeter.enable = false;
    virtualisation.memorySize = lib.mkForce 1536;
  };

  admin = {
    hinteros.admin = {
      enable = true;
      hashedPasswordFile = "${adminHash}";
    };
  };
in
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-hardening";

  nodes = {
    # Non-dev, SSH on, admin present.
    machine = box {
      imports = [ admin ];
      hinteros.state = stateFor true;
    };
    # Non-dev, SSH off, no admin.
    quiet = box { hinteros.state = stateFor false; };
    dev = box {
      hinteros.state = stateFor false;
      hinteros.dev = {
        enable = true;
        deployKeys = [ keys.snakeOilPublicKey ];
      };
    };
    lan = {
      environment = {
        etc."snakeoil".source = keys.snakeOilPrivateKey;
        systemPackages = [ pkgs.sshpass ];
      };
    };
    # Started only after the others are down.
    profilebox = profiles.node {
      state = profiles.mkState {
        accounts = [
          "p1"
          "p2"
        ];
        guest = true;
      };
      profiles = {
        p1 = {
          name = "James";
          admin = true;
          locked = true;
          pin = "2468";
        };
        p2 = {
          name = "Sam";
          pin = "1357";
        };
      };
      envs.empty.ids = [ ];
      appProfiles = {
        hinteros-p1 = "empty";
        hinteros-p2 = "empty";
      };
    };
  };

  testScript =
    { nodes, ... }:
    profiles.python
    + ''
      MACHINE = "${nodes.machine.networking.primaryIPAddress}"
      MACHINE6 = "${nodes.machine.networking.primaryIPv6Address}"
      DEV = "${nodes.dev.networking.primaryIPAddress}"
      QUIET = "${nodes.quiet.networking.primaryIPAddress}"
      for m in (machine, quiet, dev, lan):
          m.start()
      for m in (machine, quiet, dev):
          m.wait_for_unit("multi-user.target")
      machine.wait_for_unit("sshd.service")
      dev.wait_for_unit("sshd.service")
      lan.wait_for_unit("multi-user.target")
      lan.succeed("install -m 600 /etc/snakeoil /root/key")

      OPTS = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=6"
      KEY = f"ssh -i /root/key {OPTS} -o BatchMode=yes"
      PASSWD = "-o PreferredAuthentications=password -o PubkeyAuthentication=no"

      def pw(user, host, cmd, password="hunter2"):
          return f"sshpass -p {password} ssh {OPTS} {PASSWD} {user}@{host} {cmd}"

      NIX = "nix --extra-experimental-features nix-command store ping --store daemon"

      KERNEL_SYSCTLS = {
          "kernel.kptr_restrict": "2",
          "kernel.dmesg_restrict": "1",
          "kernel.perf_event_paranoid": "3",
          "kernel.unprivileged_bpf_disabled": "1",
          "net.core.bpf_jit_harden": "2",
          "kernel.io_uring_disabled": "2",
          "kernel.yama.ptrace_scope": "1",
          "fs.protected_hardlinks": "1",
          "fs.protected_symlinks": "1",
          "fs.protected_fifos": "2",
          "fs.protected_regular": "2",
      }

      # ---- non-dev: the session user ---------------------------------------------------------
      for m in (machine, quiet):
          assert "wheel" not in m.succeed("id -nG hinteros-p1").split(), "session user in wheel"
          m.fail("runuser -u hinteros-p1 -- sudo -n true")
          m.fail("runuser -u hinteros-p1 -- sudo -S true < /dev/null")
          # No nix daemon access at all (allowed-users = root).
          m.fail(f"runuser -u hinteros-p1 -- {NIX}")
          m.fail(f"runuser -u hinteros-p1 -- {NIX} --option substituters http://203.0.113.9")
          m.fail("runuser -u hinteros-p1 -- nix-store --query --hash /run/current-system")
          m.succeed("grep -E '^trusted-users = root( root)*$' /etc/nix/nix.conf")
          m.succeed("grep -E '^allowed-users = root$' /etc/nix/nix.conf")
          m.fail("id deploy")
          # Persistent journal the session user cannot read; polkit admin identities.
          m.succeed("test -d /var/log/journal")
          m.fail("runuser -u hinteros-p1 -- journalctl -b --system -n1 | grep -q systemd")
          m.succeed("grep -R 'unix-user:0' /etc/polkit-1/rules.d/")
          # Enabling SSH is a polkit action that wants the admin password.
          pk = m.succeed("pkaction --action-id org.hinteros.system.ssh --verbose")
          assert "implicit active:" in pk and "auth_admin" in pk, pk
          assert "implicit any:" in pk
          # Kernel sysctls: what the kernel really has after boot.
          for key, want in KERNEL_SYSCTLS.items():
              got = m.succeed(f"sysctl -n {key}").strip()
              assert got == want, (key, got, want)
          m.fail("runuser -u hinteros-p1 -- dmesg")
          # kptr_restrict 2: no kernel addresses, also for root.
          m.fail("grep -qv '^0000000000000000 ' /proc/kallsyms")

      # ---- admin account (machine) --------------------------------------------------------------
      assert "wheel" in machine.succeed("id -nG hinteros-admin").split()
      assert "unix-user:hinteros-admin" in machine.succeed("grep -R unix-user /etc/polkit-1/rules.d/")
      machine.fail("runuser -u hinteros-admin -- sudo -n true")
      machine.succeed("printf 'hunter2\\n' | runuser -u hinteros-admin -- sudo -S -k true")
      machine.fail("printf 'wrong\\n' | runuser -u hinteros-admin -- sudo -S -k true")
      machine.fail(f"runuser -u hinteros-admin -- {NIX}")
      quiet.fail("id hinteros-admin")

      # ---- SSH on: password login for the admin only ------------------------------------------
      sshd = machine.succeed("sshd -T").lower()
      for want in ("passwordauthentication yes", "permitrootlogin no", "allowusers hinteros-admin"):
          assert want in sshd, want
      assert "allowusers hinteros-p1\n" not in sshd
      machine.succeed("test -f /etc/ssh/ssh_host_ed25519_key")
      machine.succeed("! readlink -f /etc/ssh/ssh_host_ed25519_key | grep -q /nix/store")

      lan.succeed(pw("hinteros-admin", MACHINE, "true"))
      lan.fail(pw("hinteros-admin", MACHINE, "true", "wrong"))
      lan.fail(pw("hinteros-p1", MACHINE, "true"))
      lan.fail(pw("root", MACHINE, "true"))
      lan.fail(f"{KEY} hinteros-p1@{MACHINE} true")
      # Still unprivileged until sudo with the password.
      # sshd's per-source penalties (after the failed logins above) can refuse a connection for
      # a few seconds (ssh exits 255): retry those, but never count them as sudo's answer.
      def admin_ssh(cmd):
          for _ in range(30):
              rc, out = lan.execute(pw("hinteros-admin", MACHINE, cmd))
              if rc != 255:
                  return rc
              lan.sleep(2)
          raise AssertionError(f"no SSH connection for {cmd!r}")

      assert admin_ssh("sudo -n true") != 0
      assert admin_ssh("'echo hunter2 | sudo -S -k true'") == 0

      # ---- SSH only from the local networks --------------------------------------------------------
      # Port 22 is open only to RFC 1918, link-local and ULA sources: the test network's IPv4
      # (192.168.1.0/24) logs in above, its IPv6 (2001:db8::/32, global) is refused.
      # The firewall is nftables (table inet nixos-fw).
      rules = machine.succeed("nft list table inet nixos-fw")
      ssh_rules = [l for l in rules.splitlines() if "dport 22 " in l]
      assert ssh_rules and all("saddr" in l for l in ssh_rules), rules
      local_nets = ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "fc00::/7", "fe80::/10")
      for net in local_nets:
          assert any(net in l for l in ssh_rules), (net, rules)
      lan.succeed(f"ping -6 -c1 -W3 {MACHINE6}")
      lan.succeed(f"nc -z -w3 {MACHINE} 22")
      lan.fail(f"nc -z -w3 {MACHINE6} 22")

      # ---- SSH off: nothing listens ----------------------------------------------------------------
      quiet.fail("systemctl is-active sshd.service")
      quiet.fail("ss -tln | grep -q ':22 '")
      lan.fail(f"nc -z -w3 {QUIET} 22")

      # ---- dev box -------------------------------------------------------------------------------------
      dev.succeed("runuser -u deploy -- sudo -n true")
      dev.succeed(f"runuser -u deploy -- {NIX}")
      assert "wheel" in dev.succeed("id -nG deploy").split()
      assert "wheel" not in dev.succeed("id -nG hinteros-p1").split()
      dev.fail("runuser -u hinteros-p1 -- sudo -n true")
      dev.fail(f"runuser -u hinteros-p1 -- {NIX}")
      lan.succeed(f"{KEY} deploy@{DEV} sudo -n true")
      lan.fail(f"{KEY} root@{DEV} true")
      lan.fail(f"{KEY} hinteros-p1@{DEV} true")

      # ---- profiles (one Unix user per profile, device access per seat): a box in greeter
      # mode, after the others are down -----------------------------------------------------------
      for m in (machine, quiet, dev, lan):
          m.shutdown()
      machine = profilebox
      boot_box()
      picker_up()
      ACCOUNTS = ["hinteros-p1", "hinteros-p2", "hinteros-guest"]

      def mode(path):
          return machine.succeed(f"stat -c '%a %U:%G' {path}").strip()

      def link_owner(path):
          return machine.succeed(f"stat -c '%U' {path}").strip()

      with subtest("profiles: accounts are plain members of `hinteros`, nothing more"):
          for u in ACCOUNTS + ["hinteros-greeter"]:
              groups = set(machine.succeed(f"id -nG {u}").split())
              assert not groups & {"video", "input", "uinput", "inputplumber", "wheel", "systemd-journal"}, (u, groups)
          assert "hinteros" not in machine.succeed("id -nG hinteros-greeter").split()
          for u in ACCOUNTS:
              assert "hinteros" in machine.succeed(f"id -nG {u}").split(), u
              assert mode(f"/home/{u}") == f"700 {u}:users", (u, mode(f"/home/{u}"))
              machine.fail(f"runuser -u {u} -- sudo -n true")
              machine.fail(f"runuser -u {u} -- {NIX}")
              # No password, no login shell use over SSH (sshd is off here; the hash is locked).
              assert machine.succeed(f"getent shadow {u} | cut -d: -f2").strip() in ("!", "*", "!*", ""), u
          assert machine.succeed("id -u hinteros-p2").strip() == "20002"
          assert machine.succeed("id -u hinteros-guest").strip() == "20000"

      with subtest("profiles: the service's state, app profiles and published files"):
          # hinteros-system is not root: its state is its own account's, private to it; root's own
          # (the admin password hash, the jobs' staging) is apart, and only root may list it.
          assert mode("/var/lib/hinteros").startswith("700 hinteros-system:"), mode("/var/lib/hinteros")
          assert mode("/var/lib/hinteros-root") == "710 root:hinteros-system", mode("/var/lib/hinteros-root")
          assert mode("/var/lib/hinteros/pins").startswith("700 hinteros-system:"), mode("/var/lib/hinteros/pins")
          assert mode("/var/lib/hinteros/pins/p1").startswith("600 hinteros-system:"), mode("/var/lib/hinteros/pins/p1")
          assert mode("/var/lib/hinteros/profiles.json").startswith("600 hinteros-system:"), mode("/var/lib/hinteros/profiles.json")
          assert mode("/nix/var/nix/profiles/hinteros").startswith("755 root:"), mode("/nix/var/nix/profiles/hinteros")
          assert mode("/nix/var/nix/profiles/hinteros/apps").startswith("755 root:"), mode("/nix/var/nix/profiles/hinteros/apps")
          for u in ["hinteros-p1", "hinteros-p2"]:
              assert link_owner(f"/nix/var/nix/profiles/hinteros/apps/{u}") == "root", u
          assert mode("/run/hinteros").startswith("755 hinteros-system:"), mode("/run/hinteros")
          machine.wait_until_succeeds("test -L /run/hinteros/apps/hinteros-p2")
          # D4 says 0755; the service makes it 0750 hinteros-system:hinteros, which every account (all in
          # `hinteros`) can still traverse.
          assert mode("/run/hinteros/apps") == "750 hinteros-system:hinteros", mode("/run/hinteros/apps")
          for u in ["hinteros-p1", "hinteros-p2"]:
              assert link_owner(f"/run/hinteros/apps/{u}") in ("root", "hinteros-system"), u
          assert mode("/run/hinteros/profiles-public.json").startswith("644 hinteros-system:"), mode("/run/hinteros/profiles-public.json")
          assert mode("/run/hinteros/system.sock") == "660 hinteros-system:hinteros", mode("/run/hinteros/system.sock")
          assert mode("/run/hinteros/greeter.sock") == "660 hinteros-system:hinteros-greeter", mode("/run/hinteros/greeter.sock")
          for u in ACCOUNTS:
              machine.fail(f"runuser -u {u} -- cat /var/lib/hinteros/profiles.json")
              machine.fail(f"runuser -u {u} -- ls /var/lib/hinteros-root")
              machine.fail(f"runuser -u {u} -- touch /run/hinteros/apps/x")
              machine.fail(f"runuser -u {u} -- touch /nix/var/nix/profiles/hinteros/apps/x")
          # The guest's home is emptied at boot (never following symlinks).
          machine.succeed("grep -Rq '^D! /home/hinteros-guest 0700 hinteros-guest users' /etc/tmpfiles.d/")
          logind = machine.succeed("systemd-analyze cat-config systemd/logind.conf")
          assert ("KillUserProcesses=yes" in logind or "KillUserProcesses=true" in logind), logind
          assert "UserStopDelaySec=0" in logind, logind

      with subtest("profiles: device ACLs and runtime dirs follow the active session"):
          # At the picker no profile holds the devices.
          acl = machine.succeed("getfacl -p /dev/uinput")
          assert "user:hinteros-p1:" not in acl and "user:hinteros-p2:" not in acl, acl
          enter("p1", "hinteros-p1", "2468")
          for dev in ["/dev/uinput"] + machine.succeed("ls /dev/dri/card* /dev/dri/renderD* 2>/dev/null || true").split():
              acl = machine.succeed(f"getfacl -p {dev}")
              assert "user:hinteros-p1:" in acl and "user:hinteros-p2:" not in acl, (dev, acl)
          assert mode(f"/run/user/{uid('hinteros-p1')}") == "700 hinteros-p1:users"
          cage = machine.succeed("pgrep -u hinteros-p1 -o -f '/bin/cage '").strip()
          machine.fail(f"pkcheck --action-id org.freedesktop.login1.set-self-linger --process {cage}")
          machine.fail("runuser -u hinteros-p2 -- cat /dev/uinput")

          # Keyboards: no profile has an ACL on one or can read it; only hinteros-keyboard does
          # (Ctrl+Super+D), through keyboard.sock, which no profile can write to.
          keyboards = machine.succeed(
              "for d in /dev/input/event*; do udevadm info -q property $d | grep -qx ID_INPUT_KEYBOARD=1 && echo $d; done; true"
          ).split()
          assert keyboards, machine.succeed("ls -l /dev/input")
          for dev in keyboards:
              acl = machine.succeed(f"getfacl -p {dev}")
              assert "user:hinteros" not in acl, (dev, acl)
              for u in ACCOUNTS:
                  machine.fail(f"runuser -u {u} -- test -r {dev}")
          machine.wait_until_succeeds("journalctl -b -u hinteros-keyboard | grep -q 'keyboard found'", timeout=30)
          assert mode("/run/hinteros/keyboard.sock") == "660 hinteros-system:hinteros-keyboard", mode("/run/hinteros/keyboard.sock")
          for u in ACCOUNTS:
              machine.fail(f"runuser -u {u} -- test -w /run/hinteros/keyboard.sock")

      with subtest("profiles: a session not in front is frozen, and thawed when it is again"):
          u1 = uid("hinteros-p1")
          slice = f"user-{u1}.slice"
          user_env = f"XDG_RUNTIME_DIR=/run/user/{u1} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{u1}/bus"
          # A process of p1 (in its slice) that opens /dev/uinput while p1 is in front and then
          # counts, like a game that would type into the admin console after a switch.
          machine.succeed(
              f"runuser -u hinteros-p1 -- env {user_env} systemd-run --user --unit=uinput-holder python3 -c "
              "'import time; f = open(\"/dev/uinput\", \"wb\"); n = 0\n"
              "while True:\n n += 1; open(\"/home/hinteros-p1/ticks\", \"w\").write(str(n)); time.sleep(0.1)'"
          )
          holder = machine.wait_until_succeeds("pgrep -u hinteros-p1 -f 'dev/uinput'", timeout=30).split()[0]
          machine.wait_until_succeeds("test -s /home/hinteros-p1/ticks")

          def ticks():
              return int(machine.succeed("cat /home/hinteros-p1/ticks").strip() or 0)

          def freezer():
              return machine.succeed(f"systemctl show -p FreezerState --value {slice}").strip()

          def still(what):
              a = ticks()
              machine.sleep(2)
              assert ticks() == a, f"p1 ran {what}"

          assert freezer() == "running", freezer()
          machine.succeed("chvt 2")
          machine.wait_until_succeeds(f"systemctl show -p FreezerState --value {slice} | grep -qx frozen", timeout=10)
          machine.succeed(f"grep -qx 'frozen 1' /sys/fs/cgroup/user.slice/{slice}/cgroup.events")
          # The fd outlives the switch (logind cannot revoke it); frozen, it is of no use.
          machine.succeed(f"ls -l /proc/{holder}/fd | grep -q /dev/uinput")
          still("while frozen")
          machine.wait_until_succeeds("journalctl -b -u hinteros-system | grep -q 'frozen: its session is not the active one'")
          # A restart of the service thaws on the way out and freezes again at start.
          machine.succeed("systemctl restart hinteros-system")
          machine.wait_until_succeeds(f"systemctl show -p FreezerState --value {slice} | grep -qx frozen", timeout=10)
          still("after a restart of hinteros-system")

          machine.succeed("chvt 1")
          machine.wait_until_succeeds(f"systemctl show -p FreezerState --value {slice} | grep -qx running", timeout=10)
          a = ticks()
          machine.wait_until_succeeds(f"test \"$(cat /home/hinteros-p1/ticks)\" -gt {a}", timeout=10)
          machine.succeed("pgrep -u hinteros-p1 -f '/bin/cage '")
          sess_ok("hinteros-p1", "profile.current")
          machine.succeed(f"runuser -u hinteros-p1 -- env {user_env} systemctl --user stop uinput-holder")
    '';
}
