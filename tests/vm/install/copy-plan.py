# copy_plan (included in the install tests' scripts): a plan built at evaluation time cannot know
# the diskSeq of its disk (the kernel numbers the disks at boot), so it is added here, read from
# the installer VM, unless the plan has one or `seq` is given. (Aliased imports: the including
# script may import the same modules.)
import json as _json
import os as _os
import shlex as _shlex


def copy_plan(src, dest, seq=None):
    with open(src) as f:
        plan = _json.load(f)
    if seq is not None:
        plan["diskSeq"] = seq
    elif "diskSeq" not in plan:
        dev = _os.path.basename(plan.get("disk") or "")
        status, out = installer.execute(f"cat /sys/class/block/{_shlex.quote(dev)}/diskseq")
        plan["diskSeq"] = int(out) if status == 0 and out.strip() else 1
    installer.succeed(f"printf '%s' {_shlex.quote(_json.dumps(plan))} > {_shlex.quote(dest)}")
