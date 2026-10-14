"""Client for the session daemon's socket (API 0.15), run inside the test VMs as the session user.

Library: Session(name) says hello, `send` starts a request without waiting (responses may come
out of order, and `system.ssh.set` waits for the admin password), `response(id)` and `event(name)`
wait for one.
CLI: session.py [--name NAME] METHOD [PARAMS_JSON]   one connection, one call, prints
     {"response": {...}} on one line.
"""

import glob
import json
import os
import socket
import sys
import time

VERSION = os.environ.get("HINTEROS_SESSION_API", "0.15")


def sock_path():
    # HINTEROS_SESSION_SOCK: a particular daemon (the greeter's and a profile's can both exist).
    if os.environ.get("HINTEROS_SESSION_SOCK"):
        return os.environ["HINTEROS_SESSION_SOCK"]
    (p,) = glob.glob("/run/user/*/hinteros/session.sock")
    return p


class Session:
    def __init__(self, name="hinteros-launcher", timeout=300):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.settimeout(timeout)
        self.s.connect(sock_path())
        self.buf = b""
        self.n = 0
        self.responses = {}
        self.events = []
        r = self.call("hello", {"api_version": VERSION, "client": {"name": name, "version": "0"}})
        assert "result" in r, r

    def _read(self):
        while b"\n" not in self.buf:
            chunk = self.s.recv(65536)
            if not chunk:
                raise EOFError("session socket closed")
            self.buf += chunk
        line, _, self.buf = self.buf.partition(b"\n")
        m = json.loads(line)
        if "id" in m and ("result" in m or "error" in m):
            self.responses[m["id"]] = m
        else:
            self.events.append(m)

    def send(self, method, params=None):
        self.n += 1
        req = {"jsonrpc": "2.0", "id": self.n, "method": method}
        if params is not None:
            req["params"] = params
        self.s.sendall((json.dumps(req) + "\n").encode())
        return self.n

    def response(self, rid, timeout=60):
        end = time.time() + timeout
        while rid not in self.responses:
            assert time.time() < end, f"no response to request {rid}"
            self._read()
        return self.responses.pop(rid)

    def call(self, method, params=None, timeout=60):
        return self.response(self.send(method, params), timeout)

    def event(self, name, timeout=60, where=lambda p: True):
        end = time.time() + timeout
        while True:
            for i, m in enumerate(self.events):
                if m.get("method") == name and where(m.get("params", {})):
                    del self.events[i]
                    return m["params"]
            assert time.time() < end, f"no {name} event; saw {[m.get('method') for m in self.events]}"
            self._read()

    def quiet(self, name, seconds=3):
        """True if no `name` event arrives within `seconds`."""
        self.s.settimeout(seconds)
        try:
            while True:
                self._read()
        except (socket.timeout, TimeoutError):
            pass
        finally:
            self.s.settimeout(300)
        return not any(m.get("method") == name for m in self.events)


def main():
    argv = sys.argv[1:]
    name = "hinteros-launcher"
    if argv[:1] == ["--name"]:
        name, argv = argv[1], argv[2:]
    method = argv[0]
    params = json.loads(argv[1]) if len(argv) > 1 else {}
    print(json.dumps({"response": Session(name).call(method, params)}))


if __name__ == "__main__":
    main()
