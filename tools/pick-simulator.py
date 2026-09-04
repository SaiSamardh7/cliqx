#!/usr/bin/env python3
"""Print the UDID of the newest available iPhone simulator.

`-destination 'platform=iOS Simulator,name=iPhone 17 Pro'` is two separate
bets: that the runner image has that exact model, and that xcodebuild can match
it by name. The second one is not reliable for the Swift package scheme —
xcodebuild reports "Supported platforms for the buildables in the current
scheme is empty" and then lists no concrete simulators at all, so the name
matches nothing and the run fails with exit 70. The app project, whose
supported platforms are explicit, resolves the same name without trouble.

A UDID sidesteps the matching entirely, and choosing it at runtime means a
runner image that ships a newer iPhone does not break the build.
"""
import json
import re
import subprocess
import sys


def newest_iphone() -> tuple[str, str, str] | None:
    raw = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "--json"],
        capture_output=True, text=True, check=True).stdout

    best = None
    for runtime, devices in json.loads(raw)["devices"].items():
        version = re.search(r"iOS[-.](\d+)[-.](\d+)", runtime)
        if not version:
            continue
        release = (int(version.group(1)), int(version.group(2)))
        for device in devices:
            name = device["name"]
            if not device.get("isAvailable") or not name.startswith("iPhone"):
                continue
            model = re.search(r"\d+", name)
            # Newest runtime first, then the highest model, then Pro over base.
            key = (release, int(model.group()) if model else 0, "Pro" in name)
            if best is None or key > best[0]:
                best = (key, device["udid"], name, runtime)

    return None if best is None else best[1:]


def main() -> int:
    found = newest_iphone()
    if found is None:
        print("No available iPhone simulator runtime is installed.",
              file=sys.stderr)
        return 1
    udid, name, runtime = found
    print(f"Using {name} ({runtime})", file=sys.stderr)
    print(udid)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
