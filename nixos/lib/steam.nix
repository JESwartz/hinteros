# The box's Steam: stock pkgs.steam (spike 8) with HinterOS's sockets hidden in its FHS bwrap
# (sandbox.md, step 5). Steam is not in the app sandbox (it is trusted, threat model B3), but it
# needs no HinterOS socket: a tmpfs covers /run/hinteros (system.sock; the app envs come back
# read-only) and $XDG_RUNTIME_DIR/hinteros (session.sock, osk.sock). Directories, not the
# sockets: a bind over a socket goes away when its daemon makes the socket again.
#
# The arguments go unquoted into the bwrap script's bash array, so "$XDG_RUNTIME_DIR" expands at
# run time. `.run-free` (steam-run without Steam) gets the same arguments; the VM test uses it.
steam:
steam.override {
  extraBwrapArgs = [
    "--tmpfs /run/hinteros"
    "--ro-bind-try /run/hinteros/apps /run/hinteros/apps"
    ''--tmpfs "$XDG_RUNTIME_DIR/hinteros"''
  ];
}
