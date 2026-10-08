"""What a virtual console shows (root): vt.py N prints {"blocks": <cells drawn with the block
characters of the console splash's big letters>, "text": <the printable ASCII on it>} for /dev/vcsuN
(one UTF-32 code point per cell)."""

import json
import sys

n = sys.argv[1]
cells = open(f"/dev/vcsu{n}", "rb").read().decode("utf-32-le", errors="replace")
print(json.dumps({
    "blocks": sum(c in "█▀▄" for c in cells),
    "text": "".join(c if " " <= c <= "~" else " " for c in cells),
}))
