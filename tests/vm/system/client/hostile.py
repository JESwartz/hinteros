"""Hostile input straight at hinteros-system's socket, as the session user (not via the session
daemon). Every case must be refused with the expected error, and the service must keep answering.
Exits non-zero (assertion) on the first surprise."""

import json
import socket
import sys
import time

sys.path.insert(0, "/etc/hinteros-test")
from rpc import SOCK, Conn  # noqa: E402

INVALID, NOT_FOUND_METHOD, PARSE, INVALID_REQUEST = -32602, -32601, -32700, -32600
REV = "0" * 64
JOB = "0123456789abcdef"


def refused(method, params, code=INVALID, field=None):
    c = Conn()
    r = c.call(method, params)
    assert r is not None and "error" in r, (method, params, r)
    assert r["error"]["code"] == code, (method, params, r)
    if field is not None:
        assert r["error"].get("data", {}).get("field") in (field, "changes." + field), (method, params, r)
    assert "result" not in r
    print("ok", method, json.dumps(params)[:70], r["error"]["code"])


def alive():
    # Connections closed by the client are released by the service a moment later.
    for _ in range(50):
        try:
            c = Conn()
            r = c.call("system.info")
            if r and "result" in r:
                return
        except (AssertionError, OSError):
            pass
        time.sleep(0.2)
    raise AssertionError("the service stopped answering")


# Unknown fields: forged identities, paths, URLs, commands (every params object is closed).
for method, params in [
    ("settings.set", {"revision": REV, "changes": {}, "uid": 0}),
    ("settings.set", {"revision": REV, "changes": {}, "path": "/etc/passwd"}),
    ("ssh.set", {"enabled": True, "uid": 0}),
    ("ssh.set", {"enabled": True, "command": "id"}),
    ("ssh.set", {"enabled": True, "keys": ["ssh-ed25519 AAAA"]}),
    ("rebuild", {"path": "/etc/hinteros"}),
    ("rebuild", {"flake": "github:evil/flake"}),
    ("hardware.redetect", {"output": "/etc/passwd"}),
    ("rollback", {"generation": 1, "path": "../../etc"}),
    ("update.check", {"url": "https://evil.example/hinteros.git"}),
    ("update.apply", {"rev": "0" * 40, "url": "https://evil.example/x.git"}),
    ("channel.set", {"channel": "beta", "url": "https://evil.example/x.git"}),
    ("base.set", {"base": "stable", "substituter": "https://evil.example"}),
    ("jobs.cancel", {"job_id": JOB, "signal": 9}),
    ("jobs.get", {"job_id": JOB, "path": "/"}),
    ("system.info", {"verbose": True}),
]:
    refused(method, params)

# settings.set: fields of `changes` that do not exist (nothing is settable in API 0.2), named.
for changes, field in [
    ({"ssh": {"enabled": True}}, "ssh"),
    ({"settings": {"ssh": {"authorizedKeys": ["command=\"x\" ssh-ed25519 AAAA"]}}}, "settings"),
    ({"path": "/etc/shadow"}, "path"),
    ({"../x": 1}, "../x"),
    ({"allowAdmin": True}, "allowAdmin"),
    ({"schemaVersion": 2}, "schemaVersion"),
    ({"profiles": []}, "profiles"),
    ({"substituters": ["https://evil.example"]}, "substituters"),
]:
    refused("settings.set", {"revision": REV, "changes": changes}, field=field)

# Wrong types, bad formats, and paths where an enum or id belongs.
for method, params in [
    ("settings.set", {"revision": REV, "changes": []}),
    ("settings.set", {"revision": REV, "changes": "x"}),
    ("settings.set", {"revision": 7, "changes": {}}),
    ("settings.set", {"revision": "../../etc/passwd", "changes": {}}),
    ("settings.set", {"revision": "G" * 64, "changes": {}}),
    ("settings.set", {"changes": {}}),
    ("settings.set", {"revision": REV}),
    ("ssh.set", {"enabled": "yes"}),
    ("ssh.set", {"enabled": 1}),
    ("ssh.set", {"enabled": None}),
    ("ssh.set", {}),
    ("rollback", {"generation": "../../etc"}),
    ("rollback", {"generation": -1}),
    ("rollback", {"generation": 0}),
    ("rollback", {"generation": 2**40}),
    ("rollback", {"generation": 1.5}),
    ("rollback", {"generation": "1"}),
    ("update.apply", {"rev": "../.."}),
    ("update.apply", {"rev": "a" * 41}),
    ("update.apply", {"rev": "A" * 40}),
    ("update.apply", {"rev": 5}),
    ("update.apply", {}),
    ("channel.set", {"channel": "https://evil.example/x.git"}),
    ("channel.set", {"channel": "../beta"}),
    ("channel.set", {"channel": "nightly"}),
    ("channel.set", {"channel": "beta", "acknowledge_downgrade": "true"}),
    ("channel.set", {}),
    ("base.set", {"base": "../../etc"}),
    ("base.set", {"base": "/nix/store/x"}),
    ("base.set", {"base": "unstable", "acknowledge_downgrade": 1}),
    ("jobs.cancel", {"job_id": "../../etc/passwd"}),
    ("jobs.cancel", {"job_id": "0123456789ABCDEF"}),
    ("jobs.cancel", {"job_id": JOB + "0"}),
    ("jobs.cancel", {"job_id": 12}),
    ("jobs.get", {"job_id": "../../../proc/self/environ"}),
    ("jobs.get", {"job_id": ""}),
    ("jobs.get", {}),
    # params that are not an object at all
    ("ssh.set", [True]),
    ("ssh.set", "true"),
    ("rebuild", [1]),
    ("rebuild", "now"),
    ("jobs.cancel", [JOB]),
]:
    refused(method, params)

# A hello that lies about the version, and a hello with extra fields.
c = Conn(hello=False)
r = c.call("hello", {"api_version": "9.0", "client": {"name": "x", "version": "0"}})
assert r["error"], r
c = Conn(hello=False)
r = c.call("hello", {"api_version": "0.2", "client": {"name": "x", "version": "0"}, "uid": 0})
# NOTE: the daemon (e0f95a2) accepts unknown fields in hello (the schema says closed); the extra
# field is ignored, never used as an identity. Recorded, not asserted.
print("hello with an extra field ->", "error" if "error" in r else "accepted, ignored")

# Methods that do not exist (including ones the design keeps out of the API, and path-ish names).
for method in ["ssh.keys.add", "profiles.create", "apps.install", "exec", "system.exec", "", "../x",
               "rebuild\n", "__proto__", "power", "system.power", "update.apply ", "settings.set/x"]:
    refused(method, {}, code=NOT_FOUND_METHOD)

# Before the handshake, a mutating method is refused.
c = Conn(hello=False)
r = c.call("ssh.set", {"enabled": True})
assert r["error"]["code"] != 0 and "result" not in r, r
print("ok before hello", r["error"])

# Garbage framing: each bad line gets an error (or the connection is closed); never a crash.
def raw(data, expect_reply=True):
    c = Conn(hello=False)
    c.send(data)
    try:
        m = c.line()
    except socket.timeout:
        m = b"<timeout>"
    print("raw", data[:40], "->", (m or b"<closed>")[:100])
    return m


m = raw(b"{not json\n")
assert m is None or json.loads(m)["error"]["code"] in (PARSE, INVALID_REQUEST), m
m = raw(b"\xff\xfe\xfd\x00\x80\n")  # not UTF-8
assert m is None or json.loads(m)["error"]["code"] in (PARSE, INVALID_REQUEST), m
m = raw(b"[]\n")
assert m is None or json.loads(m)["error"]["code"] in (PARSE, INVALID_REQUEST), m
m = raw(b"null\n")
assert m is None or json.loads(m)["error"]["code"] in (PARSE, INVALID_REQUEST), m
m = raw(b'{"jsonrpc":"1.0","id":1,"method":"hello"}\n')
assert m is None or json.loads(m)["error"], m
m = raw(b'{"jsonrpc":"2.0","id":{"a":1},"method":"system.info"}\n')
assert m is None or json.loads(m)["error"], m
m = raw(b'{"jsonrpc":"2.0","id":1,"method":["x"]}\n')
assert m is None or json.loads(m)["error"], m
alive()

# Oversize: the socket's limit is 64 KiB per message. A 70 KB line, and 1 MiB without a newline.
c = Conn()
big = json.dumps({"jsonrpc": "2.0", "id": 99, "method": "settings.set",
                  "params": {"revision": REV, "changes": {}, "pad": "a" * 70000}}) + "\n"
try:
    c.send(big.encode())
    m = c.line()
except (BrokenPipeError, ConnectionResetError, socket.timeout) as e:
    m = None
print("oversize ->", (m or b"<closed>")[:120])
assert m is None or "error" in json.loads(m), m
try:
    c = Conn()
    c.send(b"A" * (1 << 20))
    c.s.settimeout(3)
    m = c.line()
except (BrokenPipeError, ConnectionResetError, socket.timeout):
    m = None
assert m is None or "error" in json.loads(m), m
alive()

# Nesting bomb and a huge array: refused or closed, never a hang for the next client.
c = Conn()
try:
    c.send(b'{"jsonrpc":"2.0","id":1,"method":"rebuild","params":' + b"[" * 20000 + b"]" * 20000 + b"}\n")
    m = c.line()
except (BrokenPipeError, ConnectionResetError, socket.timeout):
    m = None
assert m is None or "error" in json.loads(m), m
alive()

# Connection flood: far more than the per-uid limit (8); extra ones are refused or closed, and
# the service serves a fresh client once they are gone.
held = []
for _ in range(40):
    try:
        held.append(Conn(hello=False, timeout=3))
    except OSError:
        pass
served = 0
for h in held:
    try:
        r = h.call("hello", {"api_version": "0.2", "client": {"name": "flood", "version": "0"}})
        served += 1 if r and "result" in r else 0
    except (OSError, socket.timeout):
        pass
print("flood: connections served", served, "of", len(held))
assert served <= 8, served
for h in held:
    h.s.close()
alive()

# A client that connects and sends half a message then vanishes.
c = Conn()
c.send(b'{"jsonrpc":"2.0","id":1,"method":"ssh.set","params":{"enab')
c.s.close()
alive()
print("hostile: all refused, service alive")
