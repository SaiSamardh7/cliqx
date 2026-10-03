#!/usr/bin/env python3
"""PRIVACY.md says the app fetches no filter rules. Prove it.

FilterListUpdater is compiled into the binary but has no caller: the app reads
WebKit JSON and the updater fetches Adblock Plus text, so wiring it needs a
conversion pipeline that does not exist yet. The claim in PRIVACY.md is true
only while nothing calls it, and that is exactly the kind of fact that rots
silently. This fails the build the day a caller appears without the policy
being updated with it.
"""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
app = root / "ios/App/CleanPlayerApp"
package = root / "ios/Sources/CleanPlayer"

callers = []
for path in list(app.rglob("*.swift")) + list(package.rglob("*.swift")):
    if path.name == "FilterListUpdater.swift":
        continue
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if re.search(r"\bFilterListUpdater\b", line) and not line.lstrip().startswith("//"):
            callers.append(f"{path.relative_to(root)}:{number}: {line.strip()}")

policy = (root / "PRIVACY.md").read_text()
claims_no_fetch = "does not contact any server to fetch them" in policy

if callers and claims_no_fetch:
    sys.exit(
        "PRIVACY.md says the app fetches no filter rules, but FilterListUpdater "
        "now has callers:\n  " + "\n  ".join(callers)
        + "\n\nUpdate PRIVACY.md (and NOTICE.md if a new source is added) with it."
    )

if not callers and not claims_no_fetch:
    sys.exit("PRIVACY.md no longer claims rules are never fetched, but nothing fetches them.")

print("no filter-rule network path; PRIVACY.md agrees" if not callers
      else "filter rules are fetched, and PRIVACY.md says so")
