# Signed updates end to end: `update.check`, `update.apply`, `channel.check` and `channel.set`
# through the system API, run by the real daemon in its `hinteros-job@` unit (with that unit's
# environment and PATH), against a local channel repo (file:///srv/hinteros.git, built by
# system/update-repo.sh with throwaway keys; no network). The box trusts the release key through
# `hinteros.update.allowedSigners`, so the key is in the running generation's allowed_signers.
#
# Real: the git fetch into the /var/lib/hinteros-root mirror, `ssh-keygen -Y verify` (git
# verify-commit) against /run/current-system's allowed_signers, the fast-forward and seen-tip
# rules, the target's catalog evaluation, the flake.lock rewrite (`nix flake lock
# --override-input`), the flake.nix retarget, the profile generation and the switch.
#
#   - refused tips: unsigned, signed by an untrusted key, a bad signature, not on top of the
#     locked revision. Each check job fails with update_verification_failed, update.apply does not
#     take the revision, and the box stays on its generation and its flake.lock;
#   - the job verifies again: a check result changed on disk to name an unsigned commit is refused
#     by the apply job itself, before any lock or build;
#   - a signed update: the check describes it (signer, version, security trailer, catalog),
#     update.apply needs the admin PIN, flake.lock pins the verified revision, new generation;
#   - channel.set to an older channel (beta -> stable, an ancestor): channel.check reports it as
#     older, channel.set needs that revision and the PIN, flake.nix follows stable and flake.lock
#     pins its tip.
#
# STUBBED: building the new system (as system-jobs). The job's PATH starts with a stub `nix`
# whose `build` prints a prebuilt specialisation of this VM; every other nix command (the lock,
# the catalog evaluation) is the real nix. The specialisations' snapshots have no flake.lock (the
# lock the job writes is not known when the VM is built), so no later job takes it back.
{ self, pkgs }:
let
  inherit (pkgs) lib;
  url = "file:///srv/hinteros.git";
  stubNix = nix: import ./system/stub-nix.nix { inherit pkgs nix; };
  profiles = import ./system/profiles.nix { inherit self pkgs; };
  pin = "2468";

  repo =
    pkgs.runCommand "hinteros-system-update-repo"
      {
        nativeBuildInputs = [
          pkgs.git
          pkgs.openssh
          pkgs.jq
          pkgs.nix
        ];
      }
      ''
        bash ${./system/update-repo.sh} "$out" ${url} ${./fixtures/system-a/state.json}
      '';
  # Import from derivation: the box is built with the key and the locked revision.
  revs = builtins.fromJSON (builtins.readFile "${repo}/revs.json");
  releaseKey = lib.trim (builtins.readFile "${repo}/release.pub");
in
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-system-update";
  meta.timeout = 1800;

  nodes.machine =
    { config, lib, ... }:
    {
      imports = [
        (import ./system/node.nix {
          inherit self pkgs;
          fixture = "${repo}/config";
        })
      ];

      hinteros.update = {
        repo = url;
        allowedSigners = [ "release ${releaseKey}" ];
      };
      systemd.services."hinteros-job@".path = lib.mkBefore [ (stubNix config.nix.package) ];
      environment.systemPackages = [ pkgs.git ];
      system.extraDependencies = [ repo ];

      # p1 is the admin profile, with a PIN (update.apply and channel.set need it).
      systemd.services.hinteros-test-profiles = {
        wantedBy = [ "hinteros-system.service" ];
        before = [ "hinteros-system.service" ];
        after = [ "systemd-tmpfiles-setup.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          install -d -m 0700 /var/lib/hinteros /var/lib/hinteros/pins
          install -m 0600 ${
            profiles.profilesJson (lib.importJSON ./fixtures/system-a/state.json) {
              p1 = {
                name = "James";
                admin = true;
              };
            }
          } /var/lib/hinteros/profiles.json
          install -m 0600 ${profiles.pinHash pin} /var/lib/hinteros/pins/p1
          # The service's files (it is not root), as if it had written them.
          chown -R hinteros-system:hinteros /var/lib/hinteros
        '';
      };

      # The VM boots its kernel directly; there is no boot loader for the switch to install.
      boot.loader.grub.enable = lib.mkForce false;

      # The systems the stub "builds": the update (still on beta) and the switch to stable.
      specialisation = lib.genAttrs [ "beta" "stable" ] (name: {
        configuration = {
          environment.etc."hinteros-built".text = "${name}\n";
          hinteros.deviceConfig.configDir = lib.mkForce "${repo}/config-${name}";
        };
      });
    };

  testScript = ''
    import json
    import time

    REVS = json.loads('${builtins.toJSON revs}')
    URL = "${url}"
    REPO = "${repo}"
    KEY = "${releaseKey}"
    PIN = "${pin}"

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("hinteros-system.service")
    machine.wait_for_unit("greetd.service")
    machine.wait_until_succeeds("loginctl list-sessions --no-legend | grep -w hinteros-p1")
    machine.wait_until_succeeds("test -S /run/hinteros/system.sock")

    def rpc(method, params=None, user="hinteros-p1"):
        rc, out = machine.execute(f"runuser -u {user} -- python3 /etc/hinteros-test/rpc.py {method} '{json.dumps(params or {})}'")
        try:
            return json.loads(out)
        except ValueError:
            return {"failed": out}

    def call(method, params=None, user="hinteros-p1"):
        """The response; a job the launcher started (an update check) is waited out."""
        for _ in range(120):
            r = rpc(method, params, user)
            assert "response" in r and r["response"], r
            resp = r["response"]
            if "error" in resp and resp["error"]["code"] == 3005:
                time.sleep(1)
                continue
            return resp
        raise AssertionError(f"{method}: job_busy for 2 min")

    def ok(method, params=None, user="hinteros-p1"):
        r = call(method, params, user)
        assert "result" in r, (method, params, r)
        return r["result"]

    def fails(method, params, code, user="hinteros-p1"):
        r = call(method, params, user)
        assert "error" in r and r["error"]["code"] == code, (method, params, r)
        return r["error"]

    def wait_job(jid, timeout=240):
        """Poll until the job leaves `running`; the service may be restarted meanwhile."""
        for _ in range(timeout):
            r = rpc("jobs.get", {"job_id": jid})
            resp = r.get("response")
            if resp and "result" in resp and resp["result"]["job"]["state"] != "running":
                return resp["result"]["job"]
            time.sleep(1)
        raise AssertionError(f"job {jid} did not finish: {rpc('jobs.get', {'job_id': jid})}")

    def in_job_unit(jid):
        """The job ran in its own hinteros-job@ instance."""
        machine.succeed(f"journalctl -q -o cat -u hinteros-job@{jid}.service | grep -q .")

    def check():
        """update.check: the finished job. The last result is dropped first: the launcher's own
        check (at startup) must not answer from the cache for this test."""
        machine.succeed("rm -f /var/lib/hinteros/update-check.json")
        r = ok("update.check")
        if r["job_id"] is None:
            return {"state": "succeeded", "result": r["result"], "job_id": None}
        done = wait_job(r["job_id"])
        assert done["kind"] == "update_check", done
        in_job_unit(r["job_id"])
        return done

    def gens():
        return ok("generations.list")["generations"]

    def current_system():
        return machine.succeed("readlink -f /run/current-system").strip()

    def lock():
        return json.loads(machine.succeed("cat /etc/hinteros/flake.lock"))["nodes"]["hinteros"]

    def tip(branch, name):
        machine.succeed(f"git --git-dir=/srv/hinteros.git update-ref refs/heads/{branch} {REVS[name]}")

    def nix_log():
        return machine.succeed("cat /run/stub/nix.log 2>/dev/null || true")

    # The launcher starts an update check of its own at startup; let it finish (before the
    # channel repo is there, so it records nothing).
    for _ in range(60):
        js = ok("jobs.list")["jobs"]
        if any(j["kind"] == "update_check" for j in js) and not [j for j in js if j["state"] == "running"]:
            break
        machine.sleep(1)
    machine.sleep(3)

    # ---- set up: generation 1 is the running system; the channel repo; the admin PIN ----------
    orig = current_system()
    built = {n: machine.succeed(f"readlink -f /run/current-system/specialisation/{n}").strip() for n in ("beta", "stable")}
    machine.succeed("mkdir -p /run/stub")
    machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {orig}")
    machine.succeed(
        f"cp -r {REPO}/hinteros.git /srv/hinteros.git",
        "chmod -R u+w /srv/hinteros.git",
    )
    gen1 = gens()[0]["generation"]

    def unchanged():
        """Still generation 1, with the device config it was built from."""
        assert current_system() == orig
        g = gens()
        assert len(g) == 1 and g[0]["generation"] == gen1, g
        for f in ("flake.nix", "flake.lock"):
            machine.succeed(f"cmp {REPO}/config/{f} /etc/hinteros/{f}")
        machine.fail("test -e /var/lib/hinteros-root/staging")
        assert "flake lock" not in nix_log() and "build" not in nix_log(), nix_log()

    with subtest("the running generation carries the trust and the channel table"):
        policy = "/run/current-system/sw/share/hinteros/update"
        machine.succeed(f"grep -qxF 'release namespaces=\"git\" {KEY}' {policy}/allowed_signers || (cat {policy}/allowed_signers; false)")
        table = json.loads(machine.succeed(f"cat {policy}/channels.json"))
        assert table["repo"] == URL, table
        info = ok("system.info")
        assert info["channel"] == "beta" and info["rev"] == REVS["cur"], info
        unchanged()

    with subtest("refused tips: the check fails and the box stays on its generation"):
        for name, reason in [
            ("unsigned", "unsigned"),
            ("other", "unknown_signer"),
            ("badsig", "unknown_signer"),
            ("notff", "not_fast_forward"),
        ]:
            tip("beta", name)
            done = check()
            print(name, done)
            assert done["state"] == "failed", (name, done)
            err = done["error"]
            assert err["code"] == 3009 and err["data"]["reason"] == reason, (name, err)
            # Fetched into the mirror, and refused there.
            machine.succeed(f"git --git-dir=/var/lib/hinteros-root/git cat-file -e {REVS[name]}^{{commit}}")
            # Never the verified revision: update.apply does not take it.
            e = fails("update.apply", {"rev": REVS[name], "admin_pin": PIN}, 3007)
            assert e["data"]["reason"] == "update_rev", e
            unchanged()

    with subtest("a signed update is found and described"):
        tip("beta", "newer")
        done = check()
        assert done["state"] == "succeeded", done
        r = done["result"]
        assert r["channel"] == "beta" and r["current_rev"] == REVS["cur"], r
        a = r["available"]
        assert a["rev"] == REVS["newer"] and a["signer"] == "release", a
        assert a["version"] == "1.0.2" and a["summary"] == "Release 1.0.2" and a["commits"] == 1, a
        assert a["security"] == "high" and a["security_summary"] == "Test fix.", a
        # The target's catalog was evaluated (real nix, git+file input): it adds no app.
        assert a["new_apps"] == [] and a["removed_apps"] == [], a
        # The verified tips: beta's, and stable's (checked too, for a later switch).
        tips = json.loads(machine.succeed("cat /var/lib/hinteros-root/channel-tips.json"))["tips"]
        assert tips == {"beta": REVS["newer"], "stable": REVS["base"]}, tips
        # Within the cache window the same result comes back without a job.
        again = ok("update.check")
        assert again["job_id"] is None and again["result"]["available"]["rev"] == REVS["newer"], again
        unchanged()

    with subtest("update.apply needs the admin PIN"):
        for params in ({"rev": REVS["newer"]}, {"rev": REVS["newer"], "admin_pin": "1111"}):
            fails("update.apply", params, 3016)
        unchanged()

    with subtest("the apply job verifies again: an unsigned commit in a changed check result is refused"):
        cache = "/var/lib/hinteros/update-check.json"
        saved = machine.succeed(f"cat {cache}")
        machine.succeed(
            "python3 -c 'import json, sys; p = sys.argv[1]; c = json.load(open(p)); "
            "c[\"data\"][\"available\"][\"rev\"] = sys.argv[2]; open(p, \"w\").write(json.dumps(c))' "
            f"{cache} {REVS['unsigned']}"
        )
        j = ok("update.apply", {"rev": REVS["unsigned"], "admin_pin": PIN})["job_id"]
        done = wait_job(j)
        print(done)
        assert done["state"] == "failed" and done["kind"] == "update_apply", done
        assert done["error"]["code"] == 3009 and done["error"]["data"]["reason"] == "unsigned", done
        in_job_unit(j)
        unchanged()
        machine.succeed(f"cat > {cache} <<'EOF'\n{saved}\nEOF")

    with subtest("update.apply installs the verified revision"):
        machine.succeed(f"echo {built['beta']} > /run/stub/toplevel")
        j = ok("update.apply", {"rev": REVS["newer"], "admin_pin": PIN})["job_id"]
        done = wait_job(j)
        print(done)
        assert done["state"] == "succeeded", done
        in_job_unit(j)
        assert done["subject"]["rev"] == REVS["newer"] and done["subject"]["version"] == "1.0.2", done
        # flake.lock pins the verified revision of the channel; flake.nix still follows beta.
        n = lock()
        assert n["locked"]["rev"] == REVS["newer"] and n["locked"]["type"] == "git", n
        assert n["locked"]["url"] == URL and n["locked"]["narHash"].startswith("sha256-"), n
        assert n["original"]["ref"] == "beta" and n["original"]["url"] == URL, n
        machine.succeed(f"cmp {REPO}/config/flake.nix /etc/hinteros/flake.nix")
        log = nix_log()
        assert f"flake lock --override-input hinteros git+{URL}?ref=beta&rev={REVS['newer']}" in log, log
        assert "build" in log, log
        # The switch: a new generation, the built system running.
        assert current_system() == built["beta"]
        assert machine.succeed("cat /etc/hinteros-built").strip() == "beta"
        g = gens()
        assert len(g) == 2 and g[0]["current"] and g[0]["generation"] == gen1 + 1, g
        assert done["result"]["generation"] == gen1 + 1, done
        machine.fail("test -e /var/lib/hinteros-root/staging")
        info = ok("system.info")
        assert info["channel"] == "beta" and info["rev"] == REVS["newer"], info

    with subtest("up to date after the update"):
        done = check()
        assert done["state"] == "succeeded" and done["job_id"] is not None, done
        assert done["result"]["current_rev"] == REVS["newer"] and done["result"]["available"] is None, done

    with subtest("channel.set to an older channel"):
        # channel.set takes only the revision channel.check verified.
        e = fails("channel.set", {"channel": "stable", "rev": REVS["base"], "admin_pin": PIN}, 3007)
        assert e["data"]["reason"] == "channel_rev", e
        j = ok("channel.check", {"channel": "stable"})["job_id"]
        done = wait_job(j)
        assert done["state"] == "succeeded", done
        in_job_unit(j)
        r = done["result"]
        assert r["channel"] == "stable" and r["current_rev"] == REVS["newer"] and r["older"] is True, r
        assert r["target"]["rev"] == REVS["base"] and r["target"]["signer"] == "release", r
        assert r["target"]["version"] == "1.0.0", r
        fails("channel.set", {"channel": "stable", "rev": REVS["base"]}, 3016)
        e = fails("channel.set", {"channel": "stable", "admin_pin": PIN}, 3007)
        assert e["data"]["reason"] == "channel_rev", e
        assert len(gens()) == 2 and current_system() == built["beta"]

        machine.succeed(f"echo {built['stable']} > /run/stub/toplevel")
        j = ok("channel.set", {"channel": "stable", "rev": REVS["base"], "admin_pin": PIN})["job_id"]
        done = wait_job(j)
        print(done)
        assert done["state"] == "succeeded" and done["kind"] == "channel", done
        in_job_unit(j)
        # flake.nix follows stable (only the input line changed), flake.lock pins its tip.
        machine.succeed(f"cmp {REPO}/config-stable/flake.nix /etc/hinteros/flake.nix")
        n = lock()
        assert n["locked"]["rev"] == REVS["base"] and n["original"]["ref"] == "stable", n
        log = nix_log()
        assert f"flake lock --override-input hinteros git+{URL}?ref=stable&rev={REVS['base']}" in log, log
        assert current_system() == built["stable"]
        assert machine.succeed("cat /etc/hinteros-built").strip() == "stable"
        g = gens()
        assert len(g) == 3 and g[0]["current"] and g[0]["generation"] == gen1 + 2, g
        info = ok("system.info")
        assert info["channel"] == "stable" and info["rev"] == REVS["base"], info
        # A switch never lowers the newest verified tip of a branch.
        tips = json.loads(machine.succeed("cat /var/lib/hinteros-root/channel-tips.json"))["tips"]
        assert tips == {"beta": REVS["newer"], "stable": REVS["base"]}, tips
  '';
}
