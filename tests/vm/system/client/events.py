"""Subscribe to job events and append every event as one JSON line to the file given as argv[1].
Reconnects when the service restarts (a switch restarts it), like the session daemon does."""

import json
import sys
import time

sys.path.insert(0, "/etc/hinteros-test")
from rpc import Conn  # noqa: E402

out = open(sys.argv[1], "a", buffering=1)
while True:
    try:
        c = Conn()
        r = c.call("subscribe", {"events": ["job_started", "job_progress", "job_finished"]})
        out.write(json.dumps({"subscribed": r["result"]}) + "\n")
        while True:
            m = c.msg()
            if m is None:
                break
            out.write(json.dumps(m) + "\n")
    except OSError:
        pass
    time.sleep(0.3)
