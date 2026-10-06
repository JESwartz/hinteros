# usage: reader.py <name-substring> <seconds>  -> prints key/abs events seen on every matching evdev node
import evdev, sys, select, time
from evdev import ecodes as e
sub, secs = sys.argv[1], float(sys.argv[2])
devs = [evdev.InputDevice(p) for p in evdev.list_devices()]
devs = [d for d in devs if sub in d.name]
print("reading", [(d.path, d.name) for d in devs], flush=True)
def nm(t, c):
    n = e.bytype[t].get(c, c)
    return n[-1] if isinstance(n, (list, tuple)) else n   # last alias, e.g. BTN_SOUTH
end = time.time() + secs
while time.time() < end:
    r, _, _ = select.select(devs, [], [], 0.2)
    for d in r:
        for ev in d.read():
            if ev.type in (e.EV_KEY, e.EV_ABS):
                print("EVENT", d.name, "|", nm(ev.type, ev.code), ev.value, flush=True)
