"""greetd's IPC as a greeter speaks it, run as root to probe greetd's PAM stack directly:

    greetd.py USER [ANSWER...]

Finds greetd's socket (GREETD_SOCK of the greeter session's processes; the picker must be up),
sends create_session USER, answers each secret/visible prompt with the next ANSWER (an empty
answer when none is left), acknowledges info and error messages, and cancels the session at the
end: it never starts one. Prints one JSON line:
{"result": "success"|"error", "error_type"?, "description"?, "messages": [...], "prompts": n}.
"""

import json
import socket
import struct
import subprocess
import sys


def greetd_sock():
    pids = subprocess.run(["pgrep", "-u", "hinteros-greeter"], capture_output=True, text=True).stdout.split()
    for pid in pids:
        try:
            env = open(f"/proc/{pid}/environ", "rb").read().split(b"\0")
        except OSError:
            continue
        for e in env:
            if e.startswith(b"GREETD_SOCK="):
                return e.split(b"=", 1)[1].decode()
    raise SystemExit("no greeter process with GREETD_SOCK")


def recvn(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise EOFError("greetd closed the connection")
        buf += chunk
    return buf


def send(s, msg):
    data = json.dumps(msg).encode()
    s.sendall(struct.pack("=I", len(data)) + data)


def recv(s):
    (n,) = struct.unpack("=I", recvn(s, 4))
    return json.loads(recvn(s, n))


def main():
    user, answers = sys.argv[1], sys.argv[2:]
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(60)
    s.connect(greetd_sock())
    send(s, {"type": "create_session", "username": user})
    out = {"messages": [], "prompts": 0}
    while True:
        m = recv(s)
        if m["type"] == "auth_message":
            if m["auth_message_type"] in ("secret", "visible"):
                out["prompts"] += 1
                send(s, {"type": "post_auth_message_response", "response": answers.pop(0) if answers else ""})
            else:
                out["messages"].append(m["auth_message"])
                send(s, {"type": "post_auth_message_response", "response": None})
        elif m["type"] == "success":
            out["result"] = "success"
            break
        else:
            out["result"] = "error"
            out["error_type"] = m.get("error_type")
            out["description"] = m.get("description")
            break
    # Never start a session: leave greetd as the greeter left it.
    send(s, {"type": "cancel_session"})
    try:
        recv(s)
    except (EOFError, OSError):
        pass
    print(json.dumps(out))


if __name__ == "__main__":
    main()
