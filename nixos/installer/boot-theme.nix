# The ISO's boot menu in HinterOS colors (the launcher's dark theme, hinter_theme.dart) with a
# "HinterOS" wordmark instead of the NixOS logo: the GRUB theme for UEFI and the splash for BIOS.
# The GRUB theme is NixOS' (layout, fonts, icons) with its images replaced and its colors changed.
{
  lib,
  runCommand,
  imagemagick,
  atkinson-hyperlegible,
  nixos-grub2-theme,
}:
let
  font = "${atkinson-hyperlegible}/share/fonts/opentype/AtkinsonHyperlegible-Bold.otf";
  background = "#0E1118";
  surface = "#1B2030";
  text = "#F4F6FB";
  accent = "#7AA2FF";
  onAccent = "#0B1020";
in
{
  grubTheme = runCommand "hinteros-grub-theme" { nativeBuildInputs = [ imagemagick ]; } ''
    cp -r --no-preserve=mode ${nixos-grub2-theme} $out
    cd $out
    # PNG32: GRUB reads only 8- or 16-bit PNGs without a palette. ImageMagick writes small
    # one-color images as 1-bit palette PNGs, and then GRUB stops with an error and shows its
    # text menu.
    # The theme places a 319x100 logo.
    magick -size 319x100 xc:none -font ${font} -pointsize 64 -fill '${text}' \
      -gravity center -annotate +0+0 HinterOS PNG32:logo.png
    magick -size 1x1 xc:'${background}' PNG32:background.png
    for f in boot_menu_*.png; do
      magick "$f" -alpha set -fill '${surface}' -colorize 100 "PNG32:$f"
    done
    magick select_c.png -alpha set -fill '${accent}' -colorize 100 PNG32:select_c.png
    # The Breeze icons are dark: make them light for the dark menu.
    for f in icons/*.png; do magick "$f" -channel RGB -negate +channel "PNG32:$f"; done
    sed -i \
      -e 's/item_color = "#232627"/item_color = "${text}"/' \
      -e 's/selected_item_color= "#232627"/selected_item_color= "${onAccent}"/' \
      -e 's/border_color = #5579C4/border_color = ${surface}/' \
      -e 's/bg_color = #7EBAE4/bg_color = ${surface}/' \
      -e 's/fg_color = #5579C4/fg_color = ${accent}/' \
      theme.txt
    # Every image must be one GRUB can read (bit depth 8 or 16, color type 2 or 6: no palette).
    for f in $(find . -name '*.png'); do
      depth=$(od -An -tu1 -j24 -N1 "$f" | tr -d ' ')
      type=$(od -An -tu1 -j25 -N1 "$f" | tr -d ' ')
      case "$depth/$type" in
        8/2 | 8/6 | 16/2 | 16/6) ;;
        *) echo "$f: bit depth $depth, color type $type: GRUB cannot read it" >&2; exit 1 ;;
      esac
    done
  '';

  # BIOS (syslinux) menu: a plain background, 800x600 like the NixOS one (syslinux prints the
  # title), and the NixOS colors with light text.
  biosSplash = runCommand "hinteros-bios-boot.png" { nativeBuildInputs = [ imagemagick ]; } ''
    magick -size 800x600 xc:'${background}' png:$out
  '';
  syslinuxColors = ''
    #                                FG:AARRGGBB  BG:AARRGGBB   shadow
    MENU COLOR BORDER       30;44      #00000000    #00000000   none
    MENU COLOR SCREEN       37;40      #FF${lib.removePrefix "#" text}    #00000000   none
    MENU COLOR TABMSG       31;40      #80${lib.removePrefix "#" text}    #00000000   none
    MENU COLOR TIMEOUT      1;37;40    #FF${lib.removePrefix "#" text}    #00000000   none
    MENU COLOR TIMEOUT_MSG  37;40      #FF${lib.removePrefix "#" text}    #00000000   none
    MENU COLOR CMDMARK      1;36;40    #FF${lib.removePrefix "#" text}    #00000000   none
    MENU COLOR CMDLINE      37;40      #FF${lib.removePrefix "#" text}    #00000000   none
    MENU COLOR TITLE        1;36;44    #FF${lib.removePrefix "#" text}    #00000000   none
    MENU COLOR UNSEL        37;44      #FF${lib.removePrefix "#" text}    #00000000   none
    MENU COLOR SEL          7;37;40    #FF${lib.removePrefix "#" onAccent}    #FF${lib.removePrefix "#" accent}   std
  '';
}
