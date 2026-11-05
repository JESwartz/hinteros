# The time zone (hinteros-docs/design/time-zone.md), with the real hinteros-system, its helper
# unit hinteros-time-zone-apply, activation and hinteros-config-sync. Greeter mode; p1 = James,
# the admin profile (PIN 2468); p2 = Sam (PIN 1357), on screen. state.json starts with
# `settings.timeZone` "America/Chicago".
#   - Boot: activation points /etc/localtime at /etc/zoneinfo/America/Chicago (one link, from the
#     live state.json); `date` and timedated show it; hinteros-config-sync leaves state.json alone.
#   - `time_zone.get` and `time_zone.list` (system API 0.9).
#   - `time_zone.set` needs the admin PIN: none, p2's own and a wrong one are refused (also through
#     the session daemon's relay, session API 0.18), and nothing changes; an unknown zone and
#     path tricks are refused.
#   - With the admin PIN (through the relay, as the launcher does it): /etc/localtime and
#     state.json change at once, with no job, through the helper unit (the service itself cannot
#     write /etc) and systemd-timedated (/etc/localtime stays one link; timedated names the
#     zone); a new process's `date` shows the new zone. The helper's sandbox can write
#     /etc/hinteros and /run/hinteros only, nothing else in /etc. A timedated that still thinks
#     the zone is set while the link says another is restarted, and the zone applies.
#   - A job (guest.set; STUBBED build: the guest-on specialisation) replaces /etc/hinteros and
#     switches: the zone stays, and the same service process can still set one afterwards.
#   - A reboot keeps it: activation reads the zone the service wrote, and hinteros-config-sync
#     keeps the live zone although the generation's snapshot still says America/Chicago.
#   - Activation again (as a switch or a rollback does): a zone that is not tzdata's or no zone
#     means UTC; a valid one comes back; a second run leaves the link as it is.
{ self, pkgs }:
let
  profiles = import ./system/profiles.nix { inherit self pkgs; };
  # In place of the helper's ExecStart, in its own sandbox: which directories can it write?
  probe = pkgs.writeShellScript "nm13-probe" ''
    for p in /etc/nm13-probe /etc/hinteros/nm13-probe /run/hinteros/nm13-probe; do
      if touch "$p" 2>/dev/null; then echo "ok $p"; rm -f "$p"; else echo "no $p"; fi
    done
    if ln -sfn /etc/zoneinfo/UTC /etc/.nm13-probe 2>/dev/null; then echo "ok link"; else echo "no link"; fi
    if ln -sfn /etc/zoneinfo/UTC /etc/localtime 2>/dev/null; then echo "ok localtime"; else echo "no localtime"; fi
    if touch /etc/shadow 2>/dev/null; then echo "ok shadow"; else echo "no shadow"; fi
  '';
  probeDropIn = pkgs.writeText "probe.conf" ''
    [Service]
    ExecStart=
    ExecStart=${probe}
    StandardOutput=file:/run/nm13-probe.out
  '';
  stateWith =
    guest:
    let
      s = profiles.mkState {
        accounts = [
          "p1"
          "p2"
        ];
        inherit guest;
      };
    in
    s
    // {
      settings = s.settings // {
        timeZone = "America/Chicago";
      };
    };
in
profiles.mkTest {
  name = "time-zone";
  state = stateWith false;
  specialisations.guest-on = stateWith true;
  profiles = {
    p1 = {
      name = "James";
      admin = true;
      pin = "2468";
    };
    p2 = {
      name = "Sam";
      color = "orange";
      pin = "1357";
    };
  };
  extraModule =
    { config, ... }:
    {
      # A real box has /etc/hinteros before its first boot (the installer writes it); the test
      # VM gets it from tmpfiles, after activation. Put it there first, so the first boot's
      # activation reads it like any later one.
      system.activationScripts = {
        hinteros-test-config.text = ''
          if [ ! -e /etc/hinteros ]; then
            install -d -m 0755 /etc/hinteros
            for f in ${config.hinteros.deviceConfig.snapshot}/*; do
              install -m 0644 "$f" /etc/hinteros/
            done
          fi
        '';
        hinteros-time-zone.deps = [ "hinteros-test-config" ];
      };
    };

  testScript = ''
    systems = boot_box()

    def link():
        return machine.succeed("readlink /etc/localtime").strip()

    def zone_of_link():
        """The zone /etc/localtime names: one link, absolute, straight into /etc/zoneinfo (as
        activation and NixOS's timedated write it; OpenJDK and timedated read the name from it)."""
        t = link()
        if t.startswith("/etc/zoneinfo/"):
            return t[len("/etc/zoneinfo/"):]
        raise AssertionError(f"/etc/localtime -> {t}")

    def timedated_zone():
        # timedated's Timezone: from one readlink of /etc/localtime.
        return machine.succeed("timedatectl show -p Timezone --value").strip()

    def date(fmt):
        # A new process: it reads /etc/localtime (TZ is not set).
        return machine.succeed(f"env -u TZ date +{fmt}").strip()

    def tz_state():
        return state_json()["settings"].get("timeZone")

    def activate():
        machine.succeed("/run/current-system/activate")

    with subtest("boot: /etc/localtime follows the live state.json"):
        machine.wait_for_unit("hinteros-config-sync.service")
        assert link() == "/etc/zoneinfo/America/Chicago", link()
        assert date("%Z") in ("CST", "CDT"), date("%Z")
        assert machine.succeed("runuser -u hinteros-p2 -- env -u TZ date +%Z").strip() in ("CST", "CDT")
        assert timedated_zone() == "America/Chicago", timedated_zone()
        assert date("%z") in ("-0600", "-0500"), date("%z")
        assert tz_state() == "America/Chicago", state_json()
        machine.succeed("journalctl -b -u hinteros-config-sync | grep -q 'already matches'")

    enter("p2", "hinteros-p2")
    jobs_idle("hinteros-p2")

    with subtest("time_zone.get and time_zone.list"):
        info = sys_ok("hinteros-p2", "time_zone.get")
        assert info["zone"] == "America/Chicago", info
        assert info["standard_offset_s"] == -6 * 3600, info
        assert info["offset_s"] in (-6 * 3600, -5 * 3600), info
        assert isinstance(info["offset_valid_until"], int), info  # Chicago has DST
        assert sess_ok("hinteros-p2", "system.time_zone.get") == info
        zones = sys_ok("hinteros-p2", "time_zone.list")["zones"]
        names = [z["zone"] for z in zones]
        assert names == sorted(names), names[:10]
        for z in ("UTC", "Europe/Berlin", "Asia/Tokyo", "America/Chicago"):
            assert z in names, z
        tokyo = next(z for z in zones if z["zone"] == "Asia/Tokyo")
        assert tokyo["offset_s"] == tokyo["standard_offset_s"] == 9 * 3600, tokyo

    before = (link(), machine.succeed("sha256sum /etc/hinteros/state.json"))

    with subtest("time_zone.set: refused without the admin PIN"):
        for extra in [{}, {"admin_pin": "1357"}, {"admin_pin": "0000"}]:
            e = sys_err("hinteros-p2", "time_zone.set", {"zone": "Asia/Tokyo", **extra}, 3016)
            assert e["data"] == {"pin": "admin"}, (extra, e)
            r = sess("hinteros-p2", "system.time_zone.set", {"zone": "Asia/Tokyo", **extra})
            assert r["error"]["code"] == 3016 and r["error"]["data"] == {"pin": "admin"}, (extra, r)
        assert (link(), machine.succeed("sha256sum /etc/hinteros/state.json")) == before

    with subtest("time_zone.set: an unknown zone is refused"):
        for bad in ["Mars/Olympus_Mons", "../../etc/shadow", "/etc/passwd", "America", "zone1970.tab", ""]:
            r = sysrpc("hinteros-p2", "time_zone.set", {"zone": bad, "admin_pin": "2468"})
            assert "error" in r, (bad, r)
        assert (link(), machine.succeed("sha256sum /etc/hinteros/state.json")) == before
        machine.fail("ls -a /etc | grep -v '^localtime$' | grep -i localtime")

    with subtest("time_zone.set with the admin PIN: at once, no job"):
        gens = system_generations()
        info = sess_ok("hinteros-p2", "system.time_zone.set", {"zone": "Europe/London", "admin_pin": "2468"})
        assert info["zone"] == "Europe/London", info
        assert info["standard_offset_s"] == 0 and isinstance(info["offset_valid_until"], int), info
        assert zone_of_link() == "Europe/London", link()
        assert tz_state() == "Europe/London", state_json()
        assert date("%Z") in ("GMT", "BST"), date("%Z")
        # Written by the helper unit, not by the service (a finished oneshot is unloaded, so its
        # journal is the record), and the link by timedated, which names the zone.
        machine.succeed("journalctl -b -u hinteros-time-zone-apply.service --no-pager | grep -q 'Deactivated successfully'")
        machine.succeed("journalctl -b -u systemd-timedated.service --no-pager | grep -q \"Changed time zone to 'Europe/London'\"")
        assert timedated_zone() == "Europe/London", timedated_zone()
        assert sys_ok("hinteros-p2", "time_zone.get")["zone"] == "Europe/London"
        assert not [j for j in sys_ok("hinteros-p2", "jobs.list")["jobs"] if j["state"] == "running"]
        assert system_generations() == gens
        # The rest of state.json is as it was.
        st = state_json()
        assert st["profiles"] == [{"id": "p1"}, {"id": "p2"}], st
        assert st["settings"]["guest"] == {"enable": False}, st
        # Nothing left behind next to either file.
        machine.fail("ls -a /etc | grep -v '^localtime$' | grep -i localtime")
        machine.fail("ls -a /etc/hinteros | grep -i tmp")

    with subtest("a timedated that missed a change is restarted"):
        # timedated reads /etc/localtime only when it starts and ignores a call for the zone it
        # thinks is set. Point the link elsewhere behind its back (as activation may).
        assert timedated_zone() == "Europe/London", timedated_zone()
        machine.succeed("ln -sfn /etc/zoneinfo/UTC /etc/.lt-test && mv -fT /etc/.lt-test /etc/localtime")
        assert timedated_zone() == "Europe/London", "still the old process"
        info = sess_ok("hinteros-p2", "system.time_zone.set", {"zone": "Europe/London", "admin_pin": "2468"})
        assert info["zone"] == "Europe/London", info
        assert zone_of_link() == "Europe/London", link()
        machine.succeed("journalctl -b -u hinteros-time-zone-apply.service --no-pager | grep -q 'restarting it'")
        assert timedated_zone() == "Europe/London", timedated_zone()

    with subtest("the helper's sandbox writes only /etc/hinteros and /run/hinteros"):
        # The unit itself, with a probe in place of its ExecStart (a runtime drop-in, removed
        # afterwards): making or changing any other entry of /etc fails, /etc/localtime too.
        machine.succeed(
            "install -D -m 0644 ${probeDropIn} /run/systemd/system/hinteros-time-zone-apply.service.d/probe.conf"
            " && systemctl daemon-reload"
        )
        print(machine.succeed("systemctl cat hinteros-time-zone-apply.service"))
        machine.succeed("systemctl start hinteros-time-zone-apply.service")
        out = machine.succeed("cat /run/nm13-probe.out").split("\n")
        print(out)
        assert out[:6] == [
            "no /etc/nm13-probe",
            "ok /etc/hinteros/nm13-probe",
            "ok /run/hinteros/nm13-probe",
            "no link",
            "no localtime",
            "no shadow",
        ], out
        machine.fail("test -e /etc/nm13-probe || test -e /etc/.nm13-probe")
        assert zone_of_link() == "Europe/London", link()
        machine.succeed(
            "rm -r /run/systemd/system/hinteros-time-zone-apply.service.d /run/nm13-probe.out && systemctl daemon-reload"
        )

    with subtest("a job replaces /etc/hinteros: it keeps the zone, and the service can still set one"):
        # guest.set rebuilds (the stub "builds" the guest-on specialisation) and swaps
        # /etc/hinteros for its staged copy; the switch runs activation.
        stub_build(systems["guest-on"])
        j = sys_ok("hinteros-p2", "guest.set", {"enabled": True, "admin_pin": "2468"})["job_id"]
        done = wait_job("hinteros-p2", j)
        assert done["state"] == "succeeded", done
        assert current_system() == systems["guest-on"]
        assert state_json()["settings"]["guest"] == {"enable": True}, state_json()
        assert tz_state() == "Europe/London", state_json()
        assert link() == "/etc/zoneinfo/Europe/London", link()
        # Same service process, after the swap: the helper writes the new /etc/hinteros.
        info = sess_ok("hinteros-p2", "system.time_zone.set", {"zone": "Asia/Tokyo", "admin_pin": "2468"})
        assert info["zone"] == "Asia/Tokyo", info
        assert info["offset_s"] == info["standard_offset_s"] == 9 * 3600, info
        assert info["offset_valid_until"] is None, info  # no DST in Japan
        assert zone_of_link() == "Asia/Tokyo", link()
        assert tz_state() == "Asia/Tokyo", state_json()
        assert date("%Z") == "JST" and date("%z") == "+0900", (date("%Z"), date("%z"))

    with subtest("a reboot keeps it"):
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("hinteros-config-sync.service")
        machine.wait_for_unit("hinteros-system.service")
        assert link() == "/etc/zoneinfo/Asia/Tokyo", link()
        assert tz_state() == "Asia/Tokyo", state_json()
        assert date("%Z") == "JST", date("%Z")
        # The snapshot still says Chicago; the live zone won.
        assert json.loads(machine.succeed("cat /run/current-system/hinteros/state.json"))["settings"]["timeZone"] == "America/Chicago"
        # The boot still ends a first runuser session now and then: ask until one answers.
        machine.wait_until_succeeds("runuser -u hinteros-p1 -- true")
        for _ in range(10):
            try:
                zone = sys_ok("hinteros-p1", "time_zone.get")["zone"]
                break
            except AssertionError:
                machine.sleep(1)
        assert zone == "Asia/Tokyo", zone

    with subtest("activation: an unknown or absent zone is UTC; a valid one comes back"):
        for bad in ["Mars/Olympus_Mons", "../../etc/shadow", "posix/Asia/Tokyo", 5]:
            machine.succeed(f"jq --argjson z '{json.dumps(bad)}' '.settings.timeZone = $z' /etc/hinteros/state.json > /tmp/s && mv /tmp/s /etc/hinteros/state.json")
            activate()
            assert link() == "/etc/zoneinfo/UTC", (bad, link())
            assert date("%Z") == "UTC", date("%Z")
        machine.succeed("jq 'del(.settings.timeZone)' /etc/hinteros/state.json > /tmp/s && mv /tmp/s /etc/hinteros/state.json")
        # A link that points elsewhere (by hand, or a timedated call that did not go through the
        # helper) is put back to the zone of state.json.
        machine.succeed("ln -sfn /etc/zoneinfo/Asia/Tokyo /etc/localtime")
        activate()
        assert link() == "/etc/zoneinfo/UTC", link()
        machine.succeed("jq '.settings.timeZone = \"Europe/Berlin\"' /etc/hinteros/state.json > /tmp/s && mv /tmp/s /etc/hinteros/state.json")
        activate()
        assert link() == "/etc/zoneinfo/Europe/Berlin", link()
        assert date("%Z") in ("CET", "CEST"), date("%Z")
        # Idempotent: a second run does not replace the link.
        ino = machine.succeed("stat -c %i /etc/localtime")
        activate()
        assert machine.succeed("stat -c %i /etc/localtime") == ino
  '';
}
