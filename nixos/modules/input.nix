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
  ip = "org.shadowblip.InputPlumber";
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

    # InputPlumber ignores pads until ManageAllDevices is set, and the property is not
    # persistent (it resets whenever InputPlumber restarts). Temporary: the session daemon
    # will own this (set it at start and on NameOwnerChanged). bindsTo + wantedBy re-runs it
    # on every InputPlumber restart.
    systemd.services.hinteros-inputplumber-manage = {
      description = "Make InputPlumber manage all input devices";
      wantedBy = [ "inputplumber.service" ];
      bindsTo = [ "inputplumber.service" ];
      after = [ "inputplumber.service" ];
      path = [ pkgs.systemd ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        until busctl --system tree ${ip} >/dev/null 2>&1; do sleep 0.5; done
        busctl --system set-property ${ip} /org/shadowblip/InputPlumber/Manager \
          org.shadowblip.InputManager ManageAllDevices b true
      '';
    };
  };
}
