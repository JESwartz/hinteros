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
  options.hinteros.input = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.hinteros.session.enable;
      defaultText = lib.literalExpression "config.hinteros.session.enable";
      description = "Run InputPlumber so that exactly one input stream per controller exists.";
    };
    pointerCurve = lib.mkOption {
      type = lib.types.addCheck lib.types.float (k: k > 0.0);
      default = 2.5;
      description = ''
        Response curve exponent k of the right-stick pointer: mouse speed is speed_pps * m^k, with m
        the stick deflection past the deadzone, rescaled to 0..1. Larger k means slower small
        movements; full deflection is always full speed, and 1.0 is linear. Set as
        INPUTPLUMBER_POINTER_CURVE in the InputPlumber service (read at startup).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.inputplumber.enable = true;
    systemd.services.inputplumber.environment.INPUTPLUMBER_POINTER_CURVE = toString cfg.pointerCurve;
    # InputPlumber hides the physical pads it took over (a udev rule that runs chmod and
    # `setfacl -b` on their device nodes) so games see only its virtual pad. It looks up setfacl
    # on PATH; without it the hiding fails ("Unable to determine setfacl command location") and
    # games see two pads, the physical one silent (InputPlumber grabs it).
    systemd.services.inputplumber.path = [ pkgs.acl ];

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
