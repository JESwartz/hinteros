# Placeholder home app: big visible text in an X11 window (runs under gamescope's Xwayland).
{
  writeShellApplication,
  xterm,
}:
writeShellApplication {
  name = "hinteros-placeholder-home";
  runtimeInputs = [ xterm ];
  text = ''
    exec xterm -fullscreen -bg black -fg white -fa Monospace -fs 40 \
      -e sh -c 'echo; echo "  HinterOS placeholder home app"; echo; exec sleep infinity'
  '';
}
