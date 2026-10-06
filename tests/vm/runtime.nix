# Runtime settings services (NetworkManager, BlueZ, PipeWire, logind/polkit) and maintenance:
# the services are up, the session user may manage the network and sleep/restart/power off but
# not do anything privileged, boot-complete.target is gated on the launcher and daemon, and the
# low-disk warning fires.
{ self, pkgs }:
(pkgs.extend self.overlays.default).testers.runNixOSTest {
  name = "hinteros-runtime";

  nodes.machine = {
    imports = [
      self.nixosModules.session
      self.nixosModules.daemon
      self.nixosModules.input
      self.nixosModules.runtime
      self.nixosModules.maintenance
      ../../nixos/vm
    ];
    # Gate boot-complete.target on the launcher and daemon (no systemd-boot in the test VM).
    hinteros.maintenance.bootCounting.enable = true;
    # Absurd threshold so the warning path runs.
    hinteros.maintenance.diskCheck.minFreeGiB = 1000000;
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_until_succeeds("pgrep -u hinteros -f hinteros-launcher")

    machine.wait_for_unit("NetworkManager.service")
    # bluetoothd only starts with a controller present (ConditionPathIsDirectory=/sys/class/bluetooth),
    # and the VM has none; check that the unit is installed and enabled for hotplug.
    machine.succeed("systemctl cat bluetooth.service | grep -q bluetoothd")
    machine.succeed("test -e /etc/systemd/system/bluetooth.target.wants/bluetooth.service || systemctl is-enabled bluetooth.service")
    machine.succeed("grep -q '^Experimental *= *true' /etc/bluetooth/main.conf")
    machine.succeed("grep -q '^UserspaceHID *= *true' /etc/bluetooth/main.conf")
    machine.wait_for_unit("pipewire.socket", "hinteros")  # socket-activated
    machine.succeed("systemctl cat wireplumber.service | grep -q wireplumber")

    # logind: power button sleeps, lid ignored.
    out = machine.succeed("systemd-analyze cat-config systemd/logind.conf")
    assert "HandlePowerKey=suspend" in out and "HandleLidSwitch=ignore" in out, out

    # polkit, as seen from a process of the active console session.
    pid = machine.succeed("pgrep -u hinteros -f hinteros-launcher | head -n1").strip()
    def check(action, pid=pid):
        return machine.execute(f"pkcheck --action-id {action} --process {pid}")[0]

    for action in (
        "org.freedesktop.login1.suspend",
        "org.freedesktop.login1.reboot",
        "org.freedesktop.login1.power-off",
        "org.freedesktop.NetworkManager.settings.modify.own",
        "org.freedesktop.NetworkManager.network-control",
        "org.freedesktop.NetworkManager.enable-disable-wifi",
    ):
        assert check(action) == 0, f"session user should be allowed {action}"

    for action in (
        "org.freedesktop.systemd1.manage-units",
        "org.freedesktop.NetworkManager.settings.modify.system",
        "org.freedesktop.systemd1.manage-unit-files",
        "org.freedesktop.hostname1.set-static-hostname",
        "org.freedesktop.timedate1.set-time",
    ):
        assert check(action) != 0, f"session user must not be allowed {action}"

    # Another user (no session) gets none of it.
    machine.succeed("useradd -m other")
    machine.succeed("runuser -u other -- sleep 300 >/dev/null 2>&1 &")
    machine.wait_until_succeeds("pgrep -u other sleep")
    other = machine.succeed("pgrep -u other sleep | head -n1").strip()
    for action in (
        "org.freedesktop.login1.reboot",
        "org.freedesktop.login1.power-off",
        "org.freedesktop.NetworkManager.settings.modify.own",
    ):
        assert check(action, other) != 0, f"other users must not be allowed {action}"

    # Boot counting gate: launcher and daemon are up, so the boot is good.
    machine.succeed("systemctl start boot-complete.target")
    machine.succeed("systemctl is-active hinteros-boot-health.service")

    # Maintenance: low-disk warning at priority 4, GC trims to N generations first.
    machine.succeed("systemctl start hinteros-disk-check.service")
    machine.succeed("journalctl -t hinteros-disk-check -p warning --no-pager | grep 'low disk space'")
    pre = machine.succeed("systemctl show -p ExecStartPre --value nix-gc.service").split("path=")[1].split(" ")[0].rstrip(";")
    machine.succeed(f"grep -- '--delete-generations +5' {pre}")
    machine.succeed("systemctl cat nix-optimise.timer")
  '';
}
