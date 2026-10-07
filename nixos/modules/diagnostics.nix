# Diagnostics on every HinterOS system (devices and the installer ISO): the tools to look at
# hardware and network problems from a console, and `hinteros-diagnose`, which prints a compact
# network/hardware report that fits one or two TV screens (so it can be photographed).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hinteros.diagnostics;

  # No `set -e`: every probe may fail (no carrier, no Wi-Fi, no permission) and the report goes on.
  diagnose = pkgs.writeShellApplication {
    name = "hinteros-diagnose";
    bashOptions = [ ];
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.iproute2
      pkgs.ethtool
      pkgs.iw
      pkgs.pciutils
      pkgs.usbutils
      pkgs.networkmanager
      pkgs.util-linux
      pkgs.systemd
    ];
    text = ''
      # hinteros-diagnose [--full]: network and hardware report. --full: nothing is shortened.
      full=0
      case "''${1:-}" in
        "") ;;
        --full) full=1 ;;
        *) echo "usage: hinteros-diagnose [--full]" >&2; exit 2 ;;
      esac
      # One or two TV screens: shorten lines and the kernel log excerpt unless --full.
      fit() { if [ "$full" = 1 ]; then cat; else cut -c1-110; fi; }
      head_() { if [ "$full" = 1 ]; then cat; else head -n "$1"; fi; }
      section() { printf '\n== %s ==\n' "$1"; }

      # shellcheck disable=SC1091
      . /etc/os-release 2>/dev/null
      echo "HinterOS diagnose  $(date '+%F %T')  $(uname -r)  ''${VERSION_ID:-}"

      section "Links (ip -br link)"
      ip -br link | fit

      section "Network interfaces: carrier, speed, driver, firmware"
      for p in /sys/class/net/*; do
        i=''${p##*/}
        [ "$i" = lo ] && continue
        state=$(cat "$p/operstate" 2>/dev/null)
        carrier=$(cat "$p/carrier" 2>/dev/null || echo "n/a (interface down)")
        et=$(ethtool "$i" 2>/dev/null)
        speed=$(printf '%s\n' "$et" | awk -F': ' '/Speed:/{print $2}')
        link=$(printf '%s\n' "$et" | awk -F': ' '/Link detected:/{print $2}')
        info=$(ethtool -i "$i" 2>/dev/null)
        drv=$(printf '%s\n' "$info" | awk -F': ' '/^driver:/{print $2}')
        fw=$(printf '%s\n' "$info" | awk -F': ' '/^firmware-version:/{print $2}')
        bus=$(printf '%s\n' "$info" | awk -F': ' '/^bus-info:/{print $2}')
        an=$(printf '%s\n' "$et" | awk -F': ' '/Auto-negotiation:/{print $2}')
        eee=$(ethtool --show-eee "$i" 2>/dev/null | awk -F': ' '/EEE status:/{print $2}')
        echo "$i: state=''${state:-?} carrier=$carrier link=''${link:-?} speed=''${speed:-?} autoneg=''${an:-?}"
        echo "    driver=''${drv:-?} fw=''${fw:--} bus=''${bus:--}''${eee:+ EEE=$eee}"
      done
      echo "PCIe ASPM policy: $(sed 's/.*\[\(.*\)\].*/\1/' /sys/module/pcie_aspm/parameters/policy 2>/dev/null)"

      section "Machine and firmware"
      for f in sys_vendor product_name product_version bios_version bios_date; do
        printf "%s=%s  " "$f" "$(cat "/sys/class/dmi/id/$f" 2>/dev/null || echo "?")"
      done
      echo

      section "PCI network devices (lspci -nnk)"
      { lspci -nnk -d ::0200; lspci -nnk -d ::0280; } 2>&1 | grep -v '^$' | fit
      usb=$(lsusb 2>/dev/null | grep -iE 'ethernet|network|wireless|wlan|lan[0-9]|rtl81|ax88|r8152' || true)
      if [ -n "$usb" ]; then
        echo "USB network adapters:"
        printf '%s\n' "$usb" | fit
      fi

      section "Kernel log: NIC drivers and firmware"
      log=$( (dmesg 2>/dev/null || journalctl -k --no-pager -o cat 2>/dev/null) |
        grep -iE 'r8169|r8125|r8152|rtl_nic|rtl[0-9]|igc|igb|e1000e|ax88179|cdc_(ncm|ether)|iwlwifi|rtw[0-9]|mt79|ath[0-9]+k|brcm|firmware.*(load|fail|not found|error|missing)|(load|fail|missing).*firmware|link (is )?(up|down)|NIC Link|eth[0-9]|enp[0-9]' |
        grep -viE 'ACPI|nvme|usb-storage|scsi|amdgpu|i915|uvc|Firmware Bug|regulatory' || true)
      if [ -n "$log" ]; then
        printf '%s\n' "$log" | tail -n "$([ "$full" = 1 ] && echo 1000 || echo 22)" | fit
      else
        echo "(nothing found; run as root to read the kernel log)"
      fi

      section "NetworkManager"
      nmcli device 2>&1 | fit
      nmcli general 2>&1 | fit

      section "Wi-Fi and rfkill"
      iw dev 2>/dev/null | awk '/Interface|type|ssid/' | head_ 6
      rfkill list 2>&1 | head_ 12 | fit
      echo
    '';
  };
in
{
  options.hinteros.diagnostics = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Hardware and network diagnostic tools and `hinteros-diagnose` on this system.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = diagnose;
      description = "The `hinteros-diagnose` report command.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      diagnose
      pkgs.pciutils
      pkgs.usbutils
      pkgs.ethtool
      pkgs.iw
      pkgs.lshw
      pkgs.nixos-facter
    ];
  };
}
