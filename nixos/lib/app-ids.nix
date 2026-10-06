# Catalog app ids known to the device config (state.json `apps`) and where each one comes from.
# Single source of truth for state.nix (which ids evaluate), the installer (which ids a plan may
# name, and which of them work offline) and the ISO (which closure it carries).
#
# TODO(M8): the catalog flake input replaces this list.
rec {
  # Free apps whose closure is on the installer ISO: an offline install can pick any of them.
  onIso = [
    "jellyfin"
    "youtube"
    "crunchyroll"
    "firefox"
  ];

  # Everything else is downloaded during the install, so it needs a network. Steam and Plex HTPC
  # are unfree: never in a cache or on the ISO (unfree.nix).
  onlineOnly = [
    "steam"
    "plex-htpc"
    "moonlight"
  ];

  all = onIso ++ onlineOnly;

  # Pre-selected in the installer's app step.
  preselected = [
    "youtube"
    "firefox"
  ];
}
