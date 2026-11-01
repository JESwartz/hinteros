# Two profiles are two Unix users (profiles.md "One Unix user per profile", "Per profile vs.
# shared", "Authority"; threat-model B2; VM `profiles-isolation`). Greeter mode; p1 = `hinteros-p1`
# (James, admin, unlocked, PIN 2468; apps Firefox and YouTube), p2 = `hinteros-p2` (Sam,
# unlocked, PIN 1357; no apps).
#   - p1 leaves Steam, launcher, Firefox profile and private files in its home; p2 (the active
#     profile after a switch) can read none of them, nor list p1's home, p1's runtime dir or
#     session socket, nor the root-held state (profiles.json, PINs, the app registry,
#     runtime.json); it reads the public view, which carries no PIN data.
#   - Apps: p2 sees only its own (none), cannot repoint p1's app profile or link, and its own
#     install (Moonlight) leaves p1's app profile, generations and registry entry as they were.
#   - Seat: p1, no longer on screen, gets `permission_denied {reason: seat}` for every mutating
#     system.sock call; p2 cannot keep a user manager running (linger is denied to the group,
#     checked with pkcheck on p2's own session processes) while its active session passes the
#     group's NetworkManager rule.
#   - Box-wide: the display mode and the audio output p1 saved are what p2's session starts with
#     (gamescope's mode file is copied by the display-env wrapper; the audio output node is
#     published at /run/hinteros/audio-output, and p2's session daemon makes it PipeWire's default
#     sink at start, over two null sinks of which PipeWire itself prefers the other); p2's choice
#     replaces it for everyone; no profile can write the published files itself.
# Not covered in a VM: real gamescope modes and real outputs (HDMI, headphones plugged in);
# per-profile volume (WirePlumber state in the home).
{ self, pkgs }:
let
  profiles = import ./system/profiles.nix { inherit self pkgs; };
in
profiles.mkTest {
  name = "profiles-isolation";
  timeout = 2400;
  state = profiles.mkState {
    accounts = [
      "p1"
      "p2"
    ];
    guest = false;
  };
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
  # Kiosk apps open local pages (nothing here launches them; same envs as profile-apps).
  overrides.youtube.kiosk.url = "file:///etc/hinteros-pages/youtube.html";
  envs = {
    p1.ids = [
      "firefox"
      "youtube"
    ];
    empty.ids = [ ];
    moonlight.ids = [ "moonlight" ];
  };
  # Two virtual outputs (PipeWire null sinks, as in runtime-settings); WirePlumber prefers a.
  extraModule =
    { pkgs, ... }:
    {
      services.pipewire.extraConfig.pipewire."99-hinteros-null-sinks"."context.objects" =
        map
          (n: {
            factory = "adapter";
            args = {
              "factory.name" = "support.null-audio-sink";
              "node.name" = "hinteros_sink_${n.name}";
              "node.description" = "Test output ${n.name}";
              "media.class" = "Audio/Sink";
              "audio.position" = "FL,FR";
              "priority.session" = n.priority;
              "priority.driver" = n.priority;
            };
          })
          [
            {
              name = "a";
              priority = 2000;
            }
            {
              name = "b";
              priority = 1000;
            }
          ];
      environment.systemPackages = [ pkgs.pulseaudio ];
    };
  appProfiles = {
    hinteros-p1 = "p1";
    hinteros-p2 = "empty";
  };

  testScript =
    { nodes, ... }:
    ''
      boot_box()
      DISPLAY_ENV = "${nodes.machine.hinteros.session.displayEnvWrapper}"
      P1 = "/nix/var/nix/profiles/hinteros/apps/hinteros-p1"
      P2 = "/nix/var/nix/profiles/hinteros/apps/hinteros-p2"
      P1_FILES = [
          "/home/hinteros-p1/.local/share/Steam/config/loginusers.vdf",
          "/home/hinteros-p1/.local/share/Steam/steamapps/appmanifest_1.acf",
          "/home/hinteros-p1/.config/hinteros/launcher.json",
          "/home/hinteros-p1/.local/share/hinteros/firefox/youtube/cookies.sqlite",
          "/home/hinteros-p1/notes.txt",
      ]

      def default_sink(user):
          return machine.succeed(
              f"runuser -u {user} -- env XDG_RUNTIME_DIR=/run/user/{uid(user)} pactl get-default-sink"
          ).strip()

      def as_p2(cmd):
          return f"runuser -u hinteros-p2 -- sh -c {json.dumps(cmd)}"

      with subtest("p1's session leaves its files; box-wide choices"):
          enter("p1", "hinteros-p1")
          for f in P1_FILES:
              machine.succeed(f"runuser -u hinteros-p1 -- sh -c 'mkdir -p \"$(dirname {f})\" && echo secret-of-p1 > {f}'")
          u1 = uid("hinteros-p1")
          assert sess_ok("hinteros-p1", "system.display.save_mode", {"display": "QEMU Monitor", "width": 1280, "height": 720, "refresh": 60}) == {}
          # Before any choice: PipeWire's own default (the sink with the higher priority).
          machine.wait_until_succeeds(
              f"runuser -u hinteros-p1 -- env XDG_RUNTIME_DIR=/run/user/{u1} pactl get-default-sink | grep -qx hinteros_sink_a",
              timeout=60,
          )
          assert sess_ok("hinteros-p1", "system.audio.save_output", {"node": "hinteros_sink_b"}) == {}
          assert machine.succeed("cat /run/hinteros/gamescope-modes") == "QEMU Monitor:1280x720@60\n"
          assert machine.succeed("cat /run/hinteros/audio-output") == "hinteros_sink_b\n"
          for f in ["gamescope-modes", "audio-output"]:
              assert machine.succeed(f"stat -c '%a %U' /run/hinteros/{f}").strip() == "644 root", f
          p1_env = machine.succeed(f"readlink -f {P1}").strip()
          assert p1_env == env_path("p1")
          p1_gens = machine.succeed(f"nix-env -p {P1} --list-generations")
          switch("hinteros-p1", "p2", "hinteros-p2")
          machine.wait_until_fails("pgrep -u hinteros-p1", timeout=30)

      with subtest("p2 cannot read p1's home, runtime dir or session socket"):
          assert machine.succeed("stat -c '%a %U' /home/hinteros-p1").strip() == "700 hinteros-p1"
          assert machine.succeed("stat -c '%a %U' /home/hinteros-p2").strip() == "700 hinteros-p2"
          machine.fail(as_p2("ls /home/hinteros-p1"))
          for f in P1_FILES:
              machine.fail(as_p2(f"cat {f}"))
              machine.fail(as_p2(f"test -e {f}"))
          machine.fail(as_p2(f"ls /run/user/{u1}"))
          machine.fail(as_p2(f"test -S /run/user/{u1}/hinteros/session.sock"))
          # p2's own runtime dir is its own.
          assert machine.succeed(f"stat -c '%a %U' /run/user/{uid('hinteros-p2')}").strip() == "700 hinteros-p2"

      with subtest("p2 cannot read the root-held state; the public view has no secrets"):
          for f in ["/var/lib/hinteros/profiles.json", "/var/lib/hinteros/pins/p1", "/var/lib/hinteros/pins/p2",
                    "/var/lib/hinteros/runtime.json"]:
              machine.succeed(f"test -e {f}")
              machine.fail(as_p2(f"cat {f}"))
          machine.fail(as_p2("ls /var/lib/hinteros"))
          pub = json.loads(machine.succeed(as_p2("cat /run/hinteros/profiles-public.json")))
          assert {p["id"] for p in pub["profiles"]} == {"p1", "p2"}, pub
          text = json.dumps(pub)
          assert "argon2" not in text and "pin" not in [k for p in pub["profiles"] for k in p], pub

      with subtest("apps: each profile its own"):
          ids = [a["id"] for a in sess_ok("hinteros-p2", "apps.list")["apps"]]
          assert "firefox" not in ids and "youtube" not in ids, ids
          mine = sys_ok("hinteros-p2", "apps.list")
          assert mine["ids"] == [], mine
          machine.fail(as_p2(f"ln -sfn /tmp {P1}"))
          machine.fail(as_p2(f"rm {P1}"))
          machine.fail(as_p2("rm /run/hinteros/apps/hinteros-p1"))
          machine.fail(as_p2("ln -sfn /tmp /run/hinteros/apps/hinteros-p2"))
          j = sys_ok("hinteros-p2", "apps.install", {"ids": ["moonlight"], "revision": mine["revision"]})["job_id"]
          done = wait_job("hinteros-p2", j)
          assert done["state"] == "succeeded" and done["kind"] == "apps_install", done
          assert machine.succeed(f"readlink -f {P2}").strip() == env_path("moonlight")
          for _ in range(30):
              if "moonlight" in [a["id"] for a in sess_ok("hinteros-p2", "apps.list")["apps"]]:
                  break
              machine.sleep(1)
          assert "moonlight" in [a["id"] for a in sess_ok("hinteros-p2", "apps.list")["apps"]]
          # p1's apps are as they were.
          assert machine.succeed(f"readlink -f {P1}").strip() == p1_env
          assert machine.succeed(f"nix-env -p {P1} --list-generations") == p1_gens
          assert machine.succeed("readlink -f /run/hinteros/apps/hinteros-p1").strip() == p1_env
          reg = json.loads(machine.succeed("cat /var/lib/hinteros/apps/registry.json"))
          assert reg["owners"]["p1"]["ids"] == ["firefox", "youtube"], reg
          assert reg["owners"]["p2"]["ids"] == ["moonlight"], reg
          machine.fail(as_p2("cat /var/lib/hinteros/apps/registry.json"))

      with subtest("p1, not on screen, cannot change anything"):
          rev = sys_ok("hinteros-p1", "settings.get")["revision"]
          p1_rev = sys_ok("hinteros-p1", "apps.list")["revision"]
          for method, params in [
              ("apps.install", {"ids": ["moonlight"], "revision": p1_rev}),
              ("apps.remove", {"ids": ["youtube"], "revision": p1_rev, "delete_data": False}),
              ("profiles.rename", {"id": "p1", "name": "Mallory"}),
              ("profiles.set_locked", {"locked": True, "pin": "2468"}),
              ("profiles.switch", {"id": "p1"}),
              ("display.save_mode", {"display": "QEMU Monitor", "width": 640, "height": 480, "refresh": 60}),
              ("audio.save_output", {"node": "p1-was-here"}),
              ("settings.set", {"revision": rev, "changes": {}}),
          ]:
              e = sys_err("hinteros-p1", method, params, 3002)
              assert e["data"]["reason"] == "seat", (method, e)
          assert profiles_file()["profiles"]["p1"]["name"] == "James"
          assert machine.succeed("cat /run/hinteros/audio-output") == "hinteros_sink_b\n"

      with subtest("no lingering for profiles; the group's grants follow the active session"):
          cage = machine.succeed("pgrep -u hinteros-p2 -o -f '/bin/cage '").strip()
          machine.fail(f"pkcheck --action-id org.freedesktop.login1.set-self-linger --process {cage}")
          machine.succeed(f"pkcheck --action-id org.freedesktop.NetworkManager.network-control --process {cage}")
          assert machine.succeed("loginctl show-user hinteros-p2 -p Linger --value").strip() == "no"
          machine.fail("test -e /var/lib/systemd/linger/hinteros-p2")

      with subtest("display mode and audio output are the box's"):
          home2 = "/home/hinteros-p2"
          out = machine.succeed(
              f"runuser -u hinteros-p2 -- env HOME={home2} XDG_RUNTIME_DIR=/run/user/{uid('hinteros-p2')} "
              f"{DISPLAY_ENV} sh -c 'cat \"$GAMESCOPE_MODE_SAVE_FILE\"'"
          )
          assert out == "QEMU Monitor:1280x720@60\n", out
          assert machine.succeed(as_p2("cat /run/hinteros/audio-output")) == "hinteros_sink_b\n"
          machine.fail(as_p2("echo x > /run/hinteros/audio-output"))
          machine.fail(as_p2("echo x > /run/hinteros/gamescope-modes"))
          # p2's choice is the box's from now on (not a per-profile copy).
          assert sess_ok("hinteros-p2", "system.display.save_mode", {"display": "QEMU Monitor", "width": 1920, "height": 1080, "refresh": 50}) == {}
          assert sess_ok("hinteros-p2", "system.audio.save_output", {"node": "hinteros_sink_a"}) == {}
          assert machine.succeed("cat /run/hinteros/gamescope-modes") == "QEMU Monitor:1920x1080@50\n"
          assert machine.succeed("cat /run/hinteros/audio-output") == "hinteros_sink_a\n"
          rt = json.loads(machine.succeed("cat /var/lib/hinteros/runtime.json"))
          assert rt["audio_output"] == "hinteros_sink_a", rt
          assert rt["display_modes"] == {"QEMU Monitor": "1920x1080@50"}, rt
          # p1's next session starts with it too.
          out = machine.succeed(
              f"runuser -u hinteros-p1 -- env HOME=/home/hinteros-p1 {DISPLAY_ENV} sh -c 'cat \"$GAMESCOPE_MODE_SAVE_FILE\"'"
          )
          assert out == "QEMU Monitor:1920x1080@50\n", out

      with subtest("the box's audio output became p2's default sink at its session start"):
          # p1 had saved b before p2's session began. (p2's save_output above only changed the
          # box's file, not p2's sink.)
          print(machine.succeed("journalctl --no-pager -t hinteros-session | grep -i 'shared audio output' || true"))
          got = default_sink("hinteros-p2")
          if got != "hinteros_sink_b":
              # Diagnosis: does the same pactl call work now (a start-up race), or never?
              rc, out = machine.execute(
                  f"runuser -u hinteros-p2 -- env XDG_RUNTIME_DIR=/run/user/{uid('hinteros-p2')} "
                  "pactl set-default-sink hinteros_sink_b 2>&1"
              )
              print(f"pactl set-default-sink now: rc={rc} {out!r}, default {default_sink('hinteros-p2')}")
          assert got == "hinteros_sink_b", got
    '';
}
