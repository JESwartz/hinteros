# Catalog app ids as the installer and the ISO need them, derived from the catalog's entries
# (hinteros-catalog, format 3; `entries` is `config.hinteros.catalog.entries`). The ids are the
# catalog's and never change, so plans and state.json stay valid (`plex-htpc` is Plex's id).
entries:
let
  inherit (builtins) attrNames filter;
  ids = attrNames entries;
  # Retired apps keep working where installed but cannot be chosen any more; tombstones are gone.
  # Services are never offered by the installer.
  available = filter (
    id: (entries.${id}.kind or "app") == "app" && entries.${id}.status == "available"
  ) ids;
  starter = id: entries.${id}.starter or null;
in
rec {
  # Free apps whose closure is on the installer ISO: an offline install can pick any of them.
  onIso = filter (id: entries.${id}.onIso && starter id != null) available;

  # Everything else the installer offers is downloaded during the install, so it needs a network.
  # Unfree apps are never on the ISO: Plex is built on the box, Steam is fetched from the cache
  # (`delivery = "download"`).
  onlineOnly = filter (id: starter id != null && !entries.${id}.onIso) available;

  all = onIso ++ onlineOnly;

  # Pre-selected in the installer's app step (`starter = "ticked"`).
  preselected = filter (id: starter id == "ticked") available;
}
