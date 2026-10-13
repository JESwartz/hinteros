"""A profile switch driven like the launcher's Switching page and its not-responding pop-up
(session API 0.12), run in the background as the session user:

    switcher.py OUT TARGET [PIN]

Subscribes to switch_progress and switch_blocked, calls session.switch_profile {id: TARGET,
pin?} and appends the response and every event as one JSON line to OUT. The pop-up's buttons are
read from OUT.cmd (one line: `wait`, `force_close <app id>` or `cancel`; the file is removed once
the request is sent, and its response is logged too). Ends when the session daemon goes away
(the session ended) or after `switch_progress {stage: cancelled}`, logging {"closed": true} or
{"done": "cancelled"}.
"""

import json
import os
import socket
import sys

from session import Session


def main():
    out_path, target = sys.argv[1], sys.argv[2]
    pin = sys.argv[3] if len(sys.argv) > 3 else None
    cmd_path = out_path + ".cmd"
    out = open(out_path, "a", buffering=1)

    def log(obj):
        out.write(json.dumps(obj) + "\n")

    s = Session("hinteros-launcher")
    r = s.call("subscribe", {"events": ["switch_progress", "switch_blocked"]})
    assert "result" in r, r
    params = {"id": target}
    if pin:
        params["pin"] = pin
    r = s.call("session.switch_profile", params)
    log({"response": r})
    if "result" not in r:
        return
    s.s.settimeout(0.2)
    while True:
        try:
            s._read()
        except (socket.timeout, TimeoutError):
            pass
        except (EOFError, OSError):
            log({"closed": True})
            return
        while s.responses:
            _, resp = s.responses.popitem()
            log({"response": resp})
        while s.events:
            m = s.events.pop(0)
            log(m)
            if m.get("method") == "switch_progress" and m.get("params", {}).get("stage") == "cancelled":
                log({"done": "cancelled"})
                return
        if os.path.exists(cmd_path):
            words = open(cmd_path).read().split()
            os.remove(cmd_path)
            if not words:
                continue
            if words[0] == "wait":
                method, p = "session.switch_wait", {}
            elif words[0] == "cancel":
                method, p = "session.switch_cancel", {}
            elif words[0] == "force_close":
                method, p = "session.switch_force_close", {"app": words[1]}
            else:
                log({"bad_command": words})
                continue
            s.send(method, p)
            log({"sent": method, "params": p})


if __name__ == "__main__":
    main()
