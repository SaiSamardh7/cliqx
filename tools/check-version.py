#!/usr/bin/env python3
"""VERSION is the one source of the app's version number.

Two configurations carried 0.1 and two carried 1.0, so which version shipped
depended on which scheme was built. This fails the build when the project file
and VERSION disagree, or when the four configurations disagree with each other.
"""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
declared = (root / "VERSION").read_text().strip()
# Xcode wants at most three dot-separated integers; VERSION may carry a
# pre-release suffix that MARKETING_VERSION cannot.
marketing = re.match(r"\d+(\.\d+){0,2}", declared)
if not marketing:
    sys.exit(f"VERSION is not a version number: {declared!r}")
expected = marketing.group(0)

project = (root / "ios/App/CleanPlayerApp.xcodeproj/project.pbxproj").read_text()
found = re.findall(r"MARKETING_VERSION = ([^;]+);", project)
if not found:
    sys.exit("No MARKETING_VERSION in the project file.")

wrong = sorted({value for value in found if value.strip() != expected})
if wrong:
    sys.exit(
        f"VERSION says {expected}, but the project file has {', '.join(wrong)}. "
        f"Run tools/set-version.py after editing VERSION."
    )

print(f"version {expected} across {len(found)} configurations")
