# Runtime settings services: everything Settings changes without a rebuild (M5). NetworkManager
# (Wi-Fi), BlueZ (controller pairing), PipeWire (audio output and volume) and logind/polkit
# (sleep, restart, shutdown). The session daemon talks to them over DBus as the profile's user,
# so the polkit rules here are scoped to the active local session of a profile: a member of the
# `hinteros` group (profiles.md, "Device access per seat"; spike 7: polkit treats the profile's
# user service as active and local).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hinteros.runtime;
  group = config.hinteros.daemon.group;
  greeterOn = config.hinteros.profiles.greeter.enable or false;
  greeterUser = config.hinteros.profiles.greeter.user or "hinteros-greeter";

  # Only a profile in an active local session (the console). Remote logins such as SSH, and
  # every other user, keep the stock policy.
  scoped = ''subject.isInGroup("${group}") && subject.local && subject.active'';
  # The greeter (the picker) gets power only.
  scopedPower =
    if greeterOn then
      ''(subject.isInGroup("${group}") || subject.user == "${greeterUser}") && subject.local && subject.active''
    else
      scoped;

  ruleFor = scope: actions: ''
    polkit.addRule(function(action, subject) {
      if (${scope} && (${lib.concatMapStringsSep " || " (a: ''action.id == "${a}"'') actions})) {
        return polkit.Result.YES;
      }
    });
  '';

  rule = ruleFor scoped;

  # What the Wi-Fi settings screen needs: scan, toggle, connect, and per-user connections.
  # ACCEPTED (threat-model.md, B3): settings.modify.system is granted. The session user can
  # therefore add system-wide connections and read their secrets, Wi-Fi passwords included.
  # Accepted so Wi-Fi works before login and for every profile; the PSK is not treated as
  # secret from a game. Other users and non-local/inactive sessions keep the stock policy.
  networkActions = [
    "org.freedesktop.NetworkManager.network-control"
    "org.freedesktop.NetworkManager.enable-disable-wifi"
    "org.freedesktop.NetworkManager.wifi.scan"
    "org.freedesktop.NetworkManager.settings.modify.own"
    "org.freedesktop.NetworkManager.settings.modify.system"
  ];

  powerActions = map (a: "org.freedesktop.login1.${a}") [
    "suspend"
    "suspend-multiple-sessions"
    "reboot"
    "reboot-multiple-sessions"
    "power-off"
    "power-off-multiple-sessions"
  ];
in
{
  options.hinteros.runtime = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.hinteros.session.enable;
      defaultText = lib.literalExpression "config.hinteros.session.enable";
      description = "Run the services behind the runtime settings (network, Bluetooth, audio, power).";
    };

    network.enable =
      lib.mkEnableOption "NetworkManager, with the session user allowed to manage connections"
      // {
        default = true;
      };

    bluetooth.enable =
      lib.mkEnableOption "BlueZ with the experimental features controller pairing needs"
      // {
        default = true;
      };

    audio.enable = lib.mkEnableOption "PipeWire and WirePlumber (HDMI audio profiles included)" // {
      default = true;
    };

    power = {
      enable =
        lib.mkEnableOption "power button sleeps, and the session user may suspend, restart and power off"
        // {
          default = true;
        };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        security.polkit.enable = true;
      }

      (lib.mkIf cfg.network.enable {
        networking.networkmanager = {
          enable = true;
          # No VPN plugins: the session user may create connections (threat-model.md B3).
          plugins = lib.mkForce [ ];
        };
        # The scoped rule below is what lets the session user manage connections; no netdev
        # group membership, which would also cover non-session logins.
        security.polkit.extraConfig = rule networkActions;
      })

      (lib.mkIf cfg.bluetooth.enable {
        # The session daemon pairs controllers over the system bus as the session user. This BlueZ
        # (bluetooth.conf) lets *every* local user talk to org.bluez, and older ones only
        # `at_console` users and group `lp`. Pin it: org.bluez is closed to everyone but root (BlueZ
        # itself) and the profiles (the `hinteros` group), whatever BlueZ ships. Later policy wins, hence mkAfter (the
        # BlueZ package is added to the list by hardware.bluetooth); a user policy beats the default
        # context.
        services.dbus.packages = lib.mkAfter [
          (pkgs.writeTextDir "share/dbus-1/system.d/hinteros-bluez.conf" ''
            <!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
              "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
            <busconfig>
              <policy context="default">
                <deny send_destination="org.bluez"/>
              </policy>
              <policy group="${group}">
                <allow send_destination="org.bluez"/>
              </policy>
            </busconfig>
          '')
        ];
        hardware.bluetooth = {
          enable = true;
          powerOnBoot = true;
          settings = {
            General = {
              # Needed for newer controllers (battery reporting, LE features) and pairing flows.
              Experimental = true;
              FastConnectable = true;
              # Xbox pads over LE: without privacy the pad answered nothing after pairing, the
              # link timed out and the pad dropped the bond (seen with an RTL8761B dongle; xpadneo
              # reports the same). A pad that lost its key may pair again by itself.
              Privacy = "device";
              JustWorksRepairing = "always";
            };
            Policy.AutoEnable = true;
          };
          # The input plugin's settings go in input.conf: in main.conf BlueZ ignores them
          # ("Unknown key").
          input.General = {
            # Game controllers over HID-over-GATT/classic HID are handled by uhid in BlueZ.
            UserspaceHID = true;
            # Keep true: false re-opens CVE-2023-45866 (unpaired devices in range inject
            # keystrokes). Set it to false only for a specific controller that needs it.
            ClassicBondedOnly = true;
          };
        };
        # RTL8761B USB dongles (TP-Link UB500 and many more): linux-firmware's 0xDFC6_D922
        # (commit 1de22a39) drops LE links. An Xbox controller pairs, then its link times out
        # before the services are read and it forgets the bond; about half of the connections fail
        # at once (0x3E). Known bad (xpadneo, hardware notes). The file from before that commit
        # works. The first package in the list wins.
        hardware.firmware = lib.mkBefore [
          (pkgs.runCommand "rtl8761bu-firmware" { } ''
            install -Dm444 ${
              pkgs.fetchurl {
                url = "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/rtl_bt/rtl8761bu_fw.bin?id=dee0d4cdf195d3294c1ed2be07a1745be0084ba6";
                name = "rtl8761bu_fw.bin";
                hash = "sha256-FIuqJcPbFxSAR+LKlwtisKenW5YLR2LqIPBFt5d8/3Y=";
              }
            } $out/lib/firmware/rtl_bt/rtl8761bu_fw.bin
          '')
        ];
      })

      (lib.mkIf cfg.audio.enable {
        security.rtkit.enable = true;
        services.pipewire = {
          enable = true;
          alsa.enable = true;
          pulse.enable = true;
          wireplumber.enable = true;
        };
        # A sound card has one profile at a time, and only its outputs are sinks. WirePlumber
        # picks the highest-priority available profile, and on most boxes that is analog: a
        # speaker or line-out jack without detection always counts as available, so the TV on
        # HDMI or DisplayPort got no sound. A TV box plays on the TV: the HDMI/DP stereo
        # profiles come first whenever their output is available (a display with audio is
        # plugged in), keeping the analog input where the card has one. A profile the user
        # picks (Settings, through the session daemon) is stored by WirePlumber and still wins.
        # alsa-utils is there for debugging.
        services.pipewire.wireplumber.extraConfig."60-hinteros-hdmi-first" = {
          "device.profile.priority.rules" = [
            {
              matches = [ { "device.name" = "~alsa_card.*"; } ];
              actions.update-props.priorities = lib.concatMap (out: [
                "output:${out}+input:analog-stereo"
                "output:${out}"
              ]) ([ "hdmi-stereo" ] ++ map (n: "hdmi-stereo-extra${toString n}") (lib.range 1 7));
            }
          ];
        };
        environment.systemPackages = [ pkgs.alsa-utils ];
      })

      (lib.mkIf cfg.power.enable {
        # The power button sleeps the box (TV-remote style); there is no lid.
        services.logind.settings.Login = {
          HandlePowerKey = "suspend";
          HandlePowerKeyLongPress = "poweroff";
          HandleLidSwitch = "ignore";
          HandleLidSwitchExternalPower = "ignore";
          HandleLidSwitchDocked = "ignore";
        };
        security.polkit.extraConfig = ruleFor scopedPower powerActions;
      })
    ]
  );
}
