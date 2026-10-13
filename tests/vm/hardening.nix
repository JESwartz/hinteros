# Hardening baseline on built systems (threat-model.md). Non-dev boxes: the session user is not
# in wheel, cannot sudo, cannot talk to the nix daemon; the admin account's sudo always asks for
# its password; with SSH on (state.json) the admin logs in with username + password while the
# session user and root cannot; with SSH off nothing listens. Dev box: the separate key-based
# deploy user has passwordless sudo and nix, the session user still nothing.
#
# Profiles (profiles.md "One Unix user per profile", "Device access per seat"; DECISIONS D4, S2):
# on a schema-2 box in greeter mode (started after the others), every account (p1, p2, the guest)
# and the greeter are in no device group, wheel or systemd-journal, the accounts have homes 0700,
# no sudo, no nix daemon and no password; root-held state (profiles.json, PINs) is 0600/0700
# root; app profiles and the published links are root's; the sockets and the public view have
# the modes the design states; the guest's home is emptied at boot; logind kills a session's
# processes at once; device ACLs (uinput, DRM) name only the active profile, none at the picker;
# lingering is denied.
{ self, pkgs }:
let
  inherit (pkgs) lib;
  profiles = import ./system/profiles.nix { inherit self pkgs; };
  keys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;

  adminHash = pkgs.runCommand "admin-pw" { nativeBuildInputs = [ pkgs.mkpasswd ]; } ''
    echo -n "$(mkpasswd -m sha-512 -S saltsaltsalt hunter2)" > $out
  '';

  stateFor = ssh: {
    schemaVersion = 1;
    settings.ssh.enable = ssh;
    profiles = [
      {
        id = "p1";
        name = "T";
        user = "hinteros";
      }
    ];
  };

  box = extra: {
    imports = [
      ../../nixos/modules # everything but the overlay (the test pkgs already have it)
      self.nixosModules.catalog
      ../../nixos/vm
      extra
    ];
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
        hinteros = "empty";
        hinteros-p2 = "empty";
      };
    };
  };

  testScript =
    { nodes, ... }:
    profiles.python
    + ''
      MACHINE = "${nodes.machine.networking.primaryIPAddress}"
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

      # ---- non-dev: the session user ---------------------------------------------------------
      for m in (machine, quiet):
          assert "wheel" not in m.succeed("id -nG hinteros").split(), "session user in wheel"
          m.fail("runuser -u hinteros -- sudo -n true")
          m.fail("runuser -u hinteros -- sudo -S true < /dev/null")
          # No nix daemon access at all (allowed-users = root).
          m.fail(f"runuser -u hinteros -- {NIX}")
          m.fail(f"runuser -u hinteros -- {NIX} --option substituters http://203.0.113.9")
          m.fail("runuser -u hinteros -- nix-store --query --hash /run/current-system")
          m.succeed("grep -E '^trusted-users = root( root)*$' /etc/nix/nix.conf")
          m.succeed("grep -E '^allowed-users = root$' /etc/nix/nix.conf")
          m.fail("id deploy")
          # Persistent journal the session user cannot read; polkit admin identities.
          m.succeed("test -d /var/log/journal")
          m.fail("runuser -u hinteros -- journalctl -b --system -n1 | grep -q systemd")
          m.succeed("grep -R 'unix-user:0' /etc/polkit-1/rules.d/")
          # Enabling SSH is a polkit action that wants the admin password.
          pk = m.succeed("pkaction --action-id org.hinteros.system.ssh --verbose")
          assert "implicit active:" in pk and "auth_admin" in pk, pk
          assert "implicit any:" in pk

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
      assert "allowusers hinteros\n" not in sshd
      machine.succeed("test -f /etc/ssh/ssh_host_ed25519_key")
      machine.succeed("! readlink -f /etc/ssh/ssh_host_ed25519_key | grep -q /nix/store")

      lan.succeed(pw("hinteros-admin", MACHINE, "true"))
      lan.fail(pw("hinteros-admin", MACHINE, "true", "wrong"))
      lan.fail(pw("hinteros", MACHINE, "true"))
      lan.fail(pw("root", MACHINE, "true"))
      lan.fail(f"{KEY} hinteros@{MACHINE} true")
      # Still unprivileged until sudo with the password.
      lan.fail(pw("hinteros-admin", MACHINE, "sudo -n true"))
      lan.succeed(pw("hinteros-admin", MACHINE, "'echo hunter2 | sudo -S -k true'"))

      # ---- SSH off: nothing listens ----------------------------------------------------------------
      quiet.fail("systemctl is-active sshd.service")
      quiet.fail("ss -tln | grep -q ':22 '")
      lan.fail(f"nc -z -w3 {QUIET} 22")

      # ---- dev box -------------------------------------------------------------------------------------
      dev.succeed("runuser -u deploy -- sudo -n true")
      dev.succeed(f"runuser -u deploy -- {NIX}")
      assert "wheel" in dev.succeed("id -nG deploy").split()
      assert "wheel" not in dev.succeed("id -nG hinteros").split()
      dev.fail("runuser -u hinteros -- sudo -n true")
      dev.fail(f"runuser -u hinteros -- {NIX}")
      lan.succeed(f"{KEY} deploy@{DEV} sudo -n true")
      lan.fail(f"{KEY} root@{DEV} true")
      lan.fail(f"{KEY} hinteros@{DEV} true")

      # ---- profiles (profiles.md "One Unix user per profile", "Device access per seat"): a
      # schema-2 box in greeter mode, after the others are down -----------------------------------
      for m in (machine, quiet, dev, lan):
          m.shutdown()
      machine = profilebox
      boot_box()
      picker_up()
      ACCOUNTS = ["hinteros", "hinteros-p2", "hinteros-guest"]

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

      with subtest("profiles: root-held state, app profiles and published files"):
          assert mode("/var/lib/hinteros") == "700 root:root"
          assert mode("/var/lib/hinteros/pins") == "700 root:root"
          assert mode("/var/lib/hinteros/pins/p1") == "600 root:root"
          assert mode("/var/lib/hinteros/profiles.json") == "600 root:root"
          assert mode("/nix/var/nix/profiles/hinteros") == "755 root:root"
          assert mode("/nix/var/nix/profiles/hinteros/apps") == "755 root:root"
          for u in ["hinteros", "hinteros-p2"]:
              assert link_owner(f"/nix/var/nix/profiles/hinteros/apps/{u}") == "root", u
          assert mode("/run/hinteros") == "755 root:root"
          machine.wait_until_succeeds("test -L /run/hinteros/apps/hinteros-p2")
          assert mode("/run/hinteros/apps") == "755 root:root"
          for u in ["hinteros", "hinteros-p2"]:
              assert link_owner(f"/run/hinteros/apps/{u}") == "root", u
          assert mode("/run/hinteros/profiles-public.json") == "644 root:root"
          assert mode("/run/hinteros/system.sock") == "660 root:hinteros"
          assert mode("/run/hinteros/greeter.sock") == "660 root:hinteros-greeter"
          for u in ACCOUNTS:
              machine.fail(f"runuser -u {u} -- cat /var/lib/hinteros/profiles.json")
              machine.fail(f"runuser -u {u} -- touch /run/hinteros/apps/x")
              machine.fail(f"runuser -u {u} -- touch /nix/var/nix/profiles/hinteros/apps/x")
          # The guest's home is emptied at boot (never following symlinks).
          machine.succeed("grep -Rq '^D! /home/hinteros-guest 0700 hinteros-guest users' /etc/tmpfiles.d/")
          logind = machine.succeed("systemd-analyze cat-config systemd/logind.conf")
          assert "KillUserProcesses=yes" in logind and "UserStopDelaySec=0" in logind, logind

      with subtest("profiles: device ACLs and runtime dirs follow the active session"):
          # At the picker no profile holds the devices.
          acl = machine.succeed("getfacl -p /dev/uinput")
          assert "user:hinteros:" not in acl and "user:hinteros-p2:" not in acl, acl
          enter("p1", "hinteros", "2468")
          for dev in ["/dev/uinput"] + machine.succeed("ls /dev/dri/card* /dev/dri/renderD* 2>/dev/null || true").split():
              acl = machine.succeed(f"getfacl -p {dev}")
              assert "user:hinteros:" in acl and "user:hinteros-p2:" not in acl, (dev, acl)
          assert mode(f"/run/user/{uid('hinteros')}") == "700 hinteros:users"
          cage = machine.succeed("pgrep -u hinteros -o -f '/bin/cage '").strip()
          machine.fail(f"pkcheck --action-id org.freedesktop.login1.set-self-linger --process {cage}")
          machine.fail("runuser -u hinteros-p2 -- cat /dev/uinput")
    '';
}
