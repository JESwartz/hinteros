"""The launcher's side of the admin password flow against the real session daemon, polkit and PAM.

argv: <right password> <wrong password>. Runs three flows and asserts as it goes:
  1. system.ssh.set: authentication_requested, a client not named hinteros-launcher cannot see or
     answer it, a wrong password (attempts_left drops), the right one, authentication_finished
     authorized, the job and its job_finished;
  2. three wrong passwords: authentication_finished failed, permission_denied (reason polkit);
  3. auth.cancel: authentication_finished cancelled, authentication_required.
Flow 1 goes last (it turns SSH on); prints its job id on the last line.
"""

import sys

sys.path.insert(0, "/etc/hinteros-test")
from session import Session  # noqa: E402

RIGHT, WRONG = sys.argv[1], sys.argv[2]
PERMISSION_DENIED, AUTH_REQUIRED, NOT_AUTHORIZED = 3002, 3012, None


def request(c):
    rid = c.send("system.ssh.set", {"enabled": True})
    ev = c.event("authentication_requested", 30)
    assert ev["action"] == "org.hinteros.system.ssh", ev
    assert "remote login (SSH)" in ev["message"], ev
    assert ev["identities"][0]["name"] == "hinteros-admin" and ev["identities"][0]["uid"] != 0, ev
    return rid, ev["cookie"]


launcher = Session("hinteros-launcher")
launcher.call("subscribe", {"events": ["authentication_requested", "authentication_finished", "job_finished"]})
other = Session("not-the-launcher")
other.call("subscribe", {"events": ["authentication_requested", "authentication_finished"]})

# first: three wrong passwords
rid, cookie = request(launcher)
left = [launcher.call("auth.respond", {"cookie": cookie, "password": WRONG}) for _ in range(3)]
print("wrong passwords:", left)
assert [m["result"]["attempts_left"] for m in left[:2]] == [2, 1], left
fin = launcher.event("authentication_finished", 30)
assert fin["outcome"] == "failed", fin
resp = launcher.response(rid, 60)
assert resp["error"]["code"] == PERMISSION_DENIED and resp["error"]["data"]["reason"] == "polkit", resp

# then: cancelled
rid, cookie = request(launcher)
assert launcher.call("auth.cancel", {"cookie": cookie})["result"] == {}
fin = launcher.event("authentication_finished", 30)
assert fin == {"cookie": cookie, "outcome": "cancelled"}, fin
resp = launcher.response(rid, 60)
assert resp["error"]["code"] == AUTH_REQUIRED, resp

# last: the right password after one wrong one (ssh is on afterwards)
rid, cookie = request(launcher)
r = launcher.call("auth.respond", {"cookie": cookie, "password": WRONG})["result"]
assert r == {"ok": False, "attempts_left": 2}, r
# Another client, even with the right password and the real cookie: refused, and the request stays.
e = other.call("auth.respond", {"cookie": cookie, "password": RIGHT})
assert "error" in e, e
print("other client:", e["error"])
assert "error" in other.call("auth.cancel", {"cookie": cookie})
assert other.quiet("authentication_requested"), other.events
r = launcher.call("auth.respond", {"cookie": cookie, "password": RIGHT})["result"]
assert r["ok"] is True, r
fin = launcher.event("authentication_finished", 30)
assert fin == {"cookie": cookie, "outcome": "authorized"}, fin
resp = launcher.response(rid, 60)
assert "result" in resp and resp["result"]["job_id"], resp
job = resp["result"]["job_id"]
done = launcher.event("job_finished", 240, lambda p: p["job_id"] == job)
assert done["ok"] is True, done

# A cookie that is not (or no longer) pending.
assert "error" in launcher.call("auth.respond", {"cookie": cookie, "password": RIGHT})
print(job)
