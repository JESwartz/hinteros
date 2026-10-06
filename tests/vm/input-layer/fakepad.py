# Creates a fake physical Xbox 360 pad (045e:028e) via uinput and holds it open.
# Reads commands from a FIFO: "press BTN_SOUTH", "release BTN_SOUTH", "axis ABS_X 20000"
import evdev, sys, os, time
from evdev import UInput, ecodes as e, AbsInfo
caps = {
 e.EV_KEY: [e.BTN_SOUTH, e.BTN_EAST, e.BTN_NORTH, e.BTN_WEST, e.BTN_TL, e.BTN_TR,
            e.BTN_SELECT, e.BTN_START, e.BTN_MODE, e.BTN_THUMBL, e.BTN_THUMBR],
 e.EV_ABS: [(e.ABS_X, AbsInfo(0,-32768,32767,16,128,0)), (e.ABS_Y, AbsInfo(0,-32768,32767,16,128,0)),
            (e.ABS_RX, AbsInfo(0,-32768,32767,16,128,0)), (e.ABS_RY, AbsInfo(0,-32768,32767,16,128,0)),
            (e.ABS_Z, AbsInfo(0,0,255,0,0,0)), (e.ABS_RZ, AbsInfo(0,0,255,0,0,0)),
            (e.ABS_HAT0X, AbsInfo(0,-1,1,0,0,0)), (e.ABS_HAT0Y, AbsInfo(0,-1,1,0,0,0))],
}
ui = UInput(caps, name="Sunshine X-Box One (virtual) pad", vendor=0x045e, product=0x028e, version=0x110, bustype=e.BUS_USB)
print("created", ui.device.path, flush=True)
fifo = "/tmp/fakepad.fifo"
if not os.path.exists(fifo): os.mkfifo(fifo)
while True:
    with open(fifo) as f:
        for line in f:
            p = line.split()
            if not p: continue
            if p[0] == "press": ui.write(e.EV_KEY, getattr(e, p[1]), 1); ui.syn()
            elif p[0] == "release": ui.write(e.EV_KEY, getattr(e, p[1]), 0); ui.syn()
            elif p[0] == "axis": ui.write(e.EV_ABS, getattr(e, p[1]), int(p[2])); ui.syn()
