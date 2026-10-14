# The system stage's three steps in hinteros-install's progress lines (included in the install
# tests' scripts): packages, build, bootloader in that order; build lines with their counts;
# step_percent never going back within one run of a step. `fetch` is "copy" (offline) or
# "download" (online).
import re


def check_system_steps(lines, fetch):
    steps = [l for l in lines if l["stage"] in ("packages", "build", "bootloader")]
    for l in steps:
        print("STEP:", json.dumps(l))
    assert all(l["phase"] == "system" for l in steps), steps
    order: list = []
    for l in steps:
        if l["stage"] not in order:
            order.append(l["stage"])
    assert order == ["packages", "build", "bootloader"], order
    # Each step comes once, unless a retry starts again from the packages.
    runs: list = []
    for l in steps:
        if l.get("code") in ("system-retry", "bootloader-retry"):
            runs.append(None)
        elif not runs or runs[-1] != l["stage"]:
            runs.append(l["stage"])
    seq = [r for r in runs if r is not None]
    assert seq[:3] == ["packages", "build", "bootloader"], runs

    pkgs = [l for l in steps if l["stage"] == "packages"]
    assert any(l["message"] == "Getting the package list" and "step_percent" not in l for l in pkgs), pkgs
    counted = [l for l in pkgs if "step_percent" in l]
    assert counted and counted[-1]["step_percent"] == 100, counted
    for l in counted:
        assert re.fullmatch(r"\d+ of \d+ packages|Nothing to " + fetch, l["message"]), l

    builds = [l for l in steps if l["stage"] == "build"]
    assert builds, steps
    for l in builds:
        assert "step_percent" in l and "build_index" in l and "build_total" in l, l
        assert 0 <= l["build_index"] <= l["build_total"], l
        if "build" in l:
            assert l["message"] == f"Building {l['build']} ({l['build_index']} of {l['build_total']})", l
            assert l["build"] and not re.search(r"[0-9a-z]{32}-|\.drv$", l["build"]), l
        else:
            assert re.fullmatch(r"\d+ of \d+ built|Nothing to build", l["message"]), l
    assert builds[-1]["step_percent"] == 100, builds[-1]

    boot = [l for l in steps if l["stage"] == "bootloader"]
    assert any(l["message"] == "Installing the boot loader" and "step_percent" not in l for l in boot), boot
    last = steps[-1]
    assert last["stage"] == "bootloader" and last["percent"] == 70 and last["step_percent"] == 100, last
    assert last["message"] == "System installed, boot loader written", last

    # step_percent never goes back within one run of a step.
    cur: object = None
    prev = -1
    for l in steps:
        if l.get("code") in ("system-retry", "bootloader-retry") or l["stage"] != cur:
            cur, prev = l["stage"], -1
        if "step_percent" in l:
            assert l["step_percent"] >= prev, (l, prev)
            prev = l["step_percent"]
