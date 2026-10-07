# Runtime settings (session API 0.8) against the real services under cage: NetworkManager, BlueZ's
# bus policy, PipeWire (a null sink stands in for hardware) and logind/polkit. The session daemon
# runs as the session user; the test talks to its socket as that user.
#
# BlueZ: bluetoothd only starts with a controller (the VM has none), so the test starts the same
# daemon by hand as a transient unit. What it checks is the D-Bus policy: the session user can
# reach org.bluez, another user cannot, and bluetooth.status answers `unavailable` cleanly (no
# adapter). Display: under cage there is no gamescope, so display.modes is `unavailable`
# (service display) or reports can_set false; the gamescope mode files are checked by eval
# (tests/eval/apps.nix).
{ self, pkgs }:
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-runtime-settings";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [
        self.nixosModules.session
        self.nixosModules.daemon
        self.nixosModules.input
        self.nixosModules.runtime
        ../../nixos/vm
      ];
      # A virtual output so PipeWire has a sink to list.
      services.pipewire.extraConfig.pipewire."99-hinteros-null-sink" = {
        "context.objects" = [
          {
            factory = "adapter";
            args = {
              "factory.name" = "support.null-audio-sink";
              "node.name" = "hinteros_test_sink";
              "node.description" = "Test output";
              "media.class" = "Audio/Sink";
              "audio.position" = "FL,FR";
            };
          }
        ];
      };
      environment.systemPackages = [ pkgs.socat ];
    };

  testScript = ''
    import json
    import shlex

    machine.wait_for_unit("multi-user.target")
    machine.wait_until_succeeds("pgrep -u hinteros -f '/bin/cage '")
    machine.wait_for_unit("hinteros-session.service", "hinteros")
    uid = machine.succeed("id -u hinteros").strip()
    sock = f"/run/user/{uid}/hinteros/session.sock"
    machine.wait_until_succeeds(f"test -S {sock}")

    def rpc(method, params=None, wait=3):
        msgs = [
            {"jsonrpc": "2.0", "id": 0, "method": "hello",
             "params": {"api_version": "0.8", "client": {"name": "runtime-settings-test", "version": "0"}}},
            {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}},
        ]
        payload = "".join(json.dumps(m) + "\n" for m in msgs)
        cmd = f"(printf %s {shlex.quote(payload)}; sleep {wait}) | socat -t{wait} - UNIX-CONNECT:{sock}"
        out = machine.succeed(f"runuser -u hinteros -- sh -c {shlex.quote(cmd)}")
        replies = [json.loads(line) for line in out.splitlines() if line.strip()]
        assert "error" not in replies[0] and replies[0]["result"]["api_version"] == "0.8", replies[0]
        return next(r for r in replies if r.get("id") == 1)

    def poll(method, good, params=None, timeout=60):
        # The services behind a method may still be starting: retry until `good(reply)`.
        last = None
        for _ in range(timeout // 2):
            last = rpc(method, params)
            if good(last):
                return last
            machine.sleep(2)
        raise Exception(f"{method} never became good: {last}")

    # Network: the real NetworkManager answers (no Wi-Fi in the VM).
    machine.wait_for_unit("NetworkManager.service")
    net = poll("network.status", lambda r: "result" in r)["result"]
    print("network.status", net)
    assert net["wifi_available"] is False and "connectivity" in net, net

    # Bluetooth: the bus policy first, then the API. Start bluetoothd by hand (no adapter, so the
    # packaged unit's condition keeps it down).
    machine.succeed(
        "systemd-run --unit=bluetoothd-test "
        "${pkgs.bluez}/libexec/bluetooth/bluetoothd -n"
    )
    machine.wait_until_succeeds("busctl --system status org.bluez")
    machine.succeed("runuser -u hinteros -- busctl --system introspect org.bluez /org/bluez | grep -q org.bluez.AgentManager1")
    # The policy is narrow: another user may not call org.bluez.
    machine.succeed("id other || useradd -m other")
    machine.fail("runuser -u other -- busctl --system introspect org.bluez /org/bluez")
    bt = rpc("bluetooth.status")
    print("bluetooth.status", bt)
    if "error" in bt:
        assert bt["error"]["code"] == 4001 and bt["error"]["data"]["service"] == "bluez", bt
    else:
        assert bt["result"]["available"] is False, bt

    # Audio: pactl reaches the real PipeWire (pipewire-pulse is socket activated).
    machine.wait_for_unit("pipewire.socket", "hinteros")
    audio = poll(
        "audio.outputs",
        lambda r: "result" in r and any(o["id"] == "hinteros_test_sink" for o in r["result"]["outputs"]),
    )["result"]
    print("audio.outputs", audio)
    sink = next(o for o in audio["outputs"] if o["id"] == "hinteros_test_sink")
    assert sink["name"], sink
    assert 0 <= audio["volume"] <= 100 and isinstance(audio["muted"], bool), audio

    # Power: logind, authorised for the session user by the polkit rules.
    power = poll("power.capabilities", lambda r: "result" in r)["result"]
    print("power.capabilities", power)
    assert power["reboot"] == "yes" and power["poweroff"] == "yes", power
    assert power["suspend"] in ("yes", "na"), power  # the VM may lack suspend support

    # Display: no gamescope under cage.
    disp = rpc("display.modes")
    print("display.modes", disp)
    if "error" in disp:
        assert disp["error"]["code"] == 4001 and disp["error"]["data"]["service"] == "display", disp
    else:
        assert disp["result"]["can_set"] is False, disp

    machine.succeed("systemctl stop bluetoothd-test.service")
  '';
}
