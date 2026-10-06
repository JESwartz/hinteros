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
  };

  config = lib.mkIf cfg.enable {
    services.inputplumber.enable = true;

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
