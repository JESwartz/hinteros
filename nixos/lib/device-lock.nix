# Builds the flake.lock of a device flake (see hinteros-docs/design/device-config.md) whose single
# input `hinteros` is pinned to a given revision of this repo, by embedding the system repo's
# own lock: every input `hinteros` locks becomes a node of the device lock, so the whole input
# graph is resolved without contacting anything. Used by the installer ISO: the pinned revision
# is the one baked into the ISO, so an offline install evaluates from the ISO's store, and a
# later `nix flake update hinteros` on the box moves it to the channel.
{ lib }:
{
  # Decoded flake.lock of the system repo (builtins.fromJSON (readFile ./flake.lock)).
  selfLock,
  # `locked` attributes of the hinteros node: url, rev, narHash, lastModified, revCount, ref.
  locked,
  # `original` attributes of the hinteros node (the device flake's input as written).
  original,
}:
let
  prefix = "hinteros";

  # A follows path in a dependency's lock is relative to the root of the lock; the system repo's
  # root becomes the `hinteros` node, so every path moves under it.
  rewrite = lib.mapAttrs (_: v: if builtins.isList v then [ prefix ] ++ v else v);

  mapNode = n: if n ? inputs then n // { inputs = rewrite n.inputs; } else n;

  rootNode = selfLock.nodes.${selfLock.root};
in
assert
  !(selfLock.nodes ? ${prefix})
  || throw "device-lock: the system repo's lock already has a node named ${prefix}";
{
  version = 7;
  root = "root";
  nodes = (lib.mapAttrs (_: mapNode) (lib.removeAttrs selfLock.nodes [ selfLock.root ])) // {
    root.inputs.${prefix} = prefix;
    ${prefix} = {
      inherit locked original;
      inputs = rewrite (rootNode.inputs or { });
    };
  };
}
