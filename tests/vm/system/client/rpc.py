"""Tiny client for hinteros-system's socket, run inside the test VMs as the user under test.

CLI: rpc.py METHOD [PARAMS_JSON]   one connection: hello (API 0.5), the call, then prints
                                    {"response": {...}} (the raw JSON-RPC reply) on one line.
     A failed connect prints {"connect_error": "<errno name>"} and exits 0.
Library: Conn(...) for the other scripts (hostile.py, events.py).
"""

import errno
import json
import os
import socket
import sys
import time

SOCK = "/run/hinteros/system.sock"
VERSION = os.environ.get("HINTEROS_SYSTEM_API", "0.9")


class Conn:
    def __init__(self, path=SOCK, hello=True, timeout=10):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.settimeout(timeout)
        self.s.connect(path)
        self.buf = b""
        self.n = 0
        self.events = []
        if hello:
            r = self.call("hello", {"api_version": VERSION, "client": {"name": "vmtest", "version": "0"}})
            assert "result" in r, r

    def send(self, data):
        self.s.sendall(data)

    def line(self):
        """Next raw line (bytes), or None at EOF."""
        while b"\n" not in self.buf:
            try:
                chunk = self.s.recv(65536)
            except (ConnectionResetError, BrokenPipeError):
                return None
            if not chunk:
                return None
            self.buf += chunk
        line, _, self.buf = self.buf.partition(b"\n")
        return line

    def msg(self):
        raw = self.line()
        return None if raw is None else json.loads(raw)

    def call(self, method, params=None):
        self.n += 1
        req = {"jsonrpc": "2.0", "id": self.n, "method": method}
        if params is not None:
            req["params"] = params
        self.send((json.dumps(req) + "\n").encode())
        while True:
            m = self.msg()
            if m is None:
                return None
            if m.get("id") == self.n:
                return m
            self.events.append(m)


def main():
    method = sys.argv[1]
    params = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
    try:
        c = Conn()
    except OSError as e:
        print(json.dumps({"connect_error": errno.errorcode.get(e.errno, str(e))}))
        return
    print(json.dumps({"response": c.call(method, params)}))


if __name__ == "__main__":
    main()
