"""What a virtual console shows (root): vt.py N prints {"text": <the printable ASCII on it>
(/dev/vcsuN, one UTF-32 code point per cell), "graphics": <in KD_GRAPHICS mode>, "held": <a
session controller holds it (VT_PROCESS)>, "active": <the foreground console's number>}."""

import fcntl
import json
import os
import struct
import sys

KDGETMODE, VT_GETMODE, VT_GETSTATE = 0x4B3B, 0x5601, 0x5603

n = sys.argv[1]
cells = open(f"/dev/vcsu{n}", "rb").read().decode("utf-32-le", errors="replace")
fd = os.open(f"/dev/tty{n}", os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
try:
    kd = struct.unpack("i", fcntl.ioctl(fd, KDGETMODE, b"\0" * 4))[0]
    mode = struct.unpack("bbhhh", fcntl.ioctl(fd, VT_GETMODE, b"\0" * 8))[0]
    active = struct.unpack("HHH", fcntl.ioctl(fd, VT_GETSTATE, b"\0" * 6))[0]
finally:
    os.close(fd)
print(json.dumps({
    "text": "".join(c if " " <= c <= "~" else " " for c in cells),
    "graphics": kd == 1,
    "held": mode == 1,
    "active": active,
}))
