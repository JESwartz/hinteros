# Runtime settings services: everything Settings changes without a rebuild (M5). NetworkManager
# (Wi-Fi), BlueZ (controller pairing), PipeWire (audio output and volume) and logind/polkit
# (sleep, restart, shutdown). The session daemon talks to them over DBus as the session user,
# so the polkit rules here are scoped to that user's active local session.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hinteros.runtime;
  user = config.hinteros.session.user;

  # Only the session user, in an active local session (the console). Remote logins such as
  # SSH, and every other user, keep the stock policy.
  scoped = ''subject.user == "${user}" && subject.local && subject.active'';

  rule = actions: ''
    polkit.addRule(function(action, subject) {
      if (${scoped} && (${lib.concatMapStringsSep " || " (a: ''action.id == "${a}"'') actions})) {
        return polkit.Result.YES;
      }
    });
  '';

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
        hardware.bluetooth = {
          enable = true;
          powerOnBoot = true;
          settings = {
            General = {
              # Needed for newer controllers (battery reporting, LE features) and pairing flows.
              Experimental = true;
              # Game controllers over HID-over-GATT/classic HID are handled by uhid in BlueZ.
              UserspaceHID = true;
              # Keep true: false re-opens CVE-2023-45866 (unpaired devices in range inject
              # keystrokes). Set it to false only for a specific controller that needs it.
              ClassicBondedOnly = true;
              FastConnectable = true;
            };
            Policy.AutoEnable = true;
          };
        };
      })

      (lib.mkIf cfg.audio.enable {
        security.rtkit.enable = true;
        services.pipewire = {
          enable = true;
          alsa.enable = true;
          pulse.enable = true;
          wireplumber.enable = true;
        };
        # HDMI/DisplayPort outputs show up as ALSA card profiles; WirePlumber exposes every
        # profile unless a rule hides it, so the Settings audio screen can list them.
        # alsa-utils is there for debugging.
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
        security.polkit.extraConfig = rule powerActions;
      })
    ]
  );
}
