# Neutral placeholder app icon: a rounded square in one colour with one white letter,
# generated at build time. Deliberately not the apps' logos (trademarks).
{
  lib,
  runCommand,
  imagemagick,
  dejavu_fonts,
}:
{
  letter,
  color,
}:
runCommand "hinteros-icon-${lib.toLower letter}.png"
  {
    nativeBuildInputs = [ imagemagick ];
  }
  ''
    magick -size 512x512 xc:none \
      -fill ${lib.escapeShellArg color} -draw "roundrectangle 0,0 511,511 96,96" \
      -font ${dejavu_fonts}/share/fonts/truetype/DejaVuSans-Bold.ttf \
      -fill white -pointsize 320 -gravity center -annotate +0+10 ${lib.escapeShellArg letter} \
      $out
  ''
