# Catalog app ids as the installer and the ISO need them, derived from the catalog's entries
# (hinteros-catalog; `entries` is `config.hinteros.catalog.entries`). The ids are the catalog's
# and never change, so plans and state.json stay valid (`plex-htpc` is Plex's id).
entries:
let
  inherit (builtins) attrNames filter;
  ids = attrNames entries;
  # Retired apps keep working where installed but cannot be chosen any more; tombstones are gone.
  available = filter (id: entries.${id}.status == "available") ids;
in
rec {
  # Free apps whose closure is on the installer ISO: an offline install can pick any of them.
  onIso = filter (id: entries.${id}.onIso) available;

  # Everything else the installer offers is downloaded during the install, so it needs a network.
  # Unfree apps are never on the ISO: Plex is built on the box, Steam is fetched from the cache
  # (`cache = true`).
  onlineOnly = filter (id: entries.${id}.installer && !entries.${id}.onIso) available;

  all = onIso ++ onlineOnly;

  # Pre-selected in the installer's app step.
  preselected = filter (id: entries.${id}.installerDefault) available;
}
