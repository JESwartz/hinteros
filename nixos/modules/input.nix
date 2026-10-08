# Controller input layer: InputPlumber grabs the physical pads and exposes one virtual pad.
# The session daemon then switches, per pad, between "input goes to the foreground app" and
# "input goes to us" over DBus (M0 spike 4).
{
  config,
  lib,
  ...
}:
let
  cfg = config.hinteros.input;
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

    # Every InputPlumber DBus call, even reading a property, goes through polkit.
    security.polkit.enable = true;

    # The stock module omits these: uaccess rules for hidraw pads and device setup rules.
    services.udev.packages = [ config.services.inputplumber.package ];

    # InputPlumber's shipped polkit rule grants its actions to this group (or wheel).
    users.groups.inputplumber = { };
    users.users.${config.hinteros.session.user}.extraGroups = [ "inputplumber" ];

    # ManageAllDevices (off by default, reset on every InputPlumber restart) is set by the
    # session daemon (hinteros.daemon), which also re-applies it after restarts.
  };
}
