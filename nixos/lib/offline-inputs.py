# Used by offline-inputs.nix; see there. Walks the derivations named in $defaultDrv and $variantDrvs
# and prints the outputs the derivations that an install builds
# need from derivations it does not build: "<output path>\t<drv path>\t<output name>".
import os


def parse(s):
    """Parse a derivation (ATerm) into nested lists and strings."""
    pos = 0

    def value():
        nonlocal pos
        c = s[pos]
        if c == '"':
            pos += 1
            out = []
            while s[pos] != '"':
                if s[pos] == "\\":
                    pos += 1
                    out.append({"n": "\n", "t": "\t", "r": "\r"}.get(s[pos], s[pos]))
                else:
                    out.append(s[pos])
                pos += 1
            pos += 1
            return "".join(out)
        if c in "[(":
            close = "]" if c == "[" else ")"
            pos += 1
            items = []
            while s[pos] != close:
                items.append(value())
                if s[pos] == ",":
                    pos += 1
            pos += 1
            return items
        start = pos
        while s[pos] not in "([":
            pos += 1
        pos += 1  # the "(" of Derive(
        items = []
        while s[pos] != ")":
            items.append(value())
            if s[pos] == ",":
                pos += 1
        pos += 1
        return items

    return value()


_cache = {}


def drv(path):
    if path not in _cache:
        d = parse(open(path).read())
        outputs = {o[0]: o[1] for o in d[0]}
        inputs = {i[0]: i[1] for i in d[1]}
        _cache[path] = (outputs, inputs)
    return _cache[path]


def closure(root):
    """The derivations root needs to be built (itself included)."""
    seen = set()
    todo = [root]
    while todo:
        d = todo.pop()
        if d not in seen:
            seen.add(d)
            todo.extend(drv(d)[1])
    return seen


default = closure(os.environ["defaultDrv"])
required = {}
built = set()
for root in os.environ["variantDrvs"].split():
    new = closure(root) - default
    built |= new
    for d in new:
        for inp, outs in drv(d)[1].items():
            if inp in new:
                continue
            for o in outs:
                required[drv(inp)[0][o]] = (inp, o)
# An output of a derivation that another variant builds is built there, not required.
print(f"# {len(built)} derivations built by the variants")
for out, (d, o) in sorted(required.items()):
    print(f"{out}\t{d}\t{o}")
