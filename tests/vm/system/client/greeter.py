"""Drives the greeter-mode session daemon the way the picker does (session API 0.13).

greeter.py ID [PIN...]   as the greeter user, against HINTEROS_SESSION_SOCK: `greeter.login ID`,
then each PIN in turn when greetd asks for one (`greeter_prompt`), logging in again after a
refusal. Prints {"list": greeter.list, "outcomes": [greeter_result params...]} on one line.
"""

import json
import sys

from session import Session


def main():
    target, pins = sys.argv[1], sys.argv[2:]
    s = Session("hinteros-launcher")
    r = s.call("subscribe", {"events": ["greeter_prompt", "greeter_result"]})
    assert "result" in r, r
    listed = s.call("greeter.list")
    assert "result" in listed, listed
    outcomes = []

    def login():
        r = s.call("greeter.login", {"id": target})
        assert "result" in r, r

    def answer():
        """The next prompt (True) or result (its params)."""
        while True:
            for i, m in enumerate(s.events):
                if m.get("method") == "greeter_prompt":
                    del s.events[i]
                    return True
                if m.get("method") == "greeter_result":
                    del s.events[i]
                    return m["params"]
            s._read()

    login()
    a = answer()
    if a is not True:
        outcomes.append(a)
    else:
        for n, pin in enumerate(pins):
            if n > 0:
                login()
                assert answer() is True, "no PIN prompt after a refusal"
            r = s.call("greeter.pin", {"pin": pin})
            assert "result" in r, r
            res = answer()
            assert res is not True, "asked again for the PIN"
            outcomes.append(res)
            if res["ok"]:
                break
    print(json.dumps({"list": listed["result"], "outcomes": outcomes}))


if __name__ == "__main__":
    main()
