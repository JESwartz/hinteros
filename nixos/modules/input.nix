# Controller input layer: InputPlumber grabs the physical pads and exposes one virtual pad.
# The session daemon then switches, per pad, between "input goes to the foreground app" and
# "input goes to us" over DBus (M0 spike 4).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hinteros.input;
  group = config.hinteros.daemon.group or "hinteros";
  greeterOn = config.hinteros.profiles.greeter.enable or false;
  greeterUser = config.hinteros.profiles.greeter.user or "hinteros-greeter";
in
{
  imports = [
    (lib.mkRemovedOptionModule [ "hinteros" "input" "pointerCurve" ] ''
      The right-stick pointer's curve is part of its InputPlumber profile now: `curve` under
      [pointer] in the session daemon's config.
    '')
  ];

  options.hinteros.input = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.hinteros.session.enable;
      defaultText = lib.literalExpression "config.hinteros.session.enable";
      description = "Run InputPlumber so that exactly one input stream per controller exists.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.inputplumber.enable = true;
    # InputPlumber hides the physical pads it took over (a udev rule that runs chmod and
    # `setfacl -b` on their device nodes) so games see only its virtual pad. It looks up setfacl
    # on PATH; without it the hiding fails ("Unable to determine setfacl command location") and
    # games see two pads, the physical one silent (InputPlumber grabs it).
    systemd.services.inputplumber.path = [ pkgs.acl ];

    # The HID drivers of Bluetooth pads load at boot. Loaded on demand, the first pad after boot
    # gets hid-generic, then its own driver takes it over and its device nodes come again in the
    # same second. InputPlumber 0.81.0 adds the new hidraw node twice, the second open fails
    # (EBUSY), and it stops the virtual pad but keeps the physical one hidden: the pad shows as
    # connected and does nothing.
    boot.kernelModules = [
      "hid_microsoft"
      "hid_nintendo"
      "hid_playstation"
      "hid_sony"
      "hid_steam"
    ];

    # Every InputPlumber DBus call, even reading a property, goes through polkit.
    security.polkit.enable = true;

    # The stock module omits these: uaccess rules for hidraw pads and device setup rules.
    services.udev.packages = [ config.services.inputplumber.package ];

    # Autologin: InputPlumber's shipped polkit rule grants its actions to this group (or wheel).
    # With the greeter no account is in it: the active local session of a profile (or the
    # greeter) gets the actions instead (profiles.md, "Device access per seat"; spike 7: polkit
    # sees the profile's user service as active and local, a system service as that user not).
    users.groups.inputplumber = { };
    users.users.${config.hinteros.session.user}.extraGroups = lib.optionals (!greeterOn) [
      "inputplumber"
    ];
    security.polkit.extraConfig = lib.mkIf greeterOn ''
      polkit.addRule(function (action, subject) {
        if (action.id.indexOf("org.shadowblip.") === 0 && subject.local && subject.active &&
            (subject.isInGroup("${group}") || subject.user == "${greeterUser}")) {
          return polkit.Result.YES;
        }
      });
    '';

    # ManageAllDevices (off by default, reset on every InputPlumber restart) is set by the
    # session daemon (hinteros.daemon), which also re-applies it after restarts.
  };
}
