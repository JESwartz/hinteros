# Hardening baseline on built systems (threat-model.md). Non-dev boxes: the session user is not
# in wheel, cannot sudo, cannot talk to the nix daemon; the admin account's sudo always asks for
# its password; with SSH on (state.json) the admin logs in with username + password while the
# session user and root cannot; with SSH off nothing listens. Dev box: the separate key-based
# deploy user has passwordless sudo and nix, the session user still nothing.
{ self, pkgs }:
let
  inherit (pkgs) lib;
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
  };

  testScript =
    { nodes, ... }:
    ''
      MACHINE = "${nodes.machine.networking.primaryIPAddress}"
      DEV = "${nodes.dev.networking.primaryIPAddress}"
      QUIET = "${nodes.quiet.networking.primaryIPAddress}"
      start_all()
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
    '';
}
