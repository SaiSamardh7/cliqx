#!/usr/bin/env python3
"""Write VERSION into every MARKETING_VERSION in the project file."""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
declared = (root / "VERSION").read_text().strip()
marketing = re.match(r"\d+(\.\d+){0,2}", declared)
if not marketing:
    sys.exit(f"VERSION is not a version number: {declared!r}")
expected = marketing.group(0)

path = root / "ios/App/CleanPlayerApp.xcodeproj/project.pbxproj"
text = path.read_text()
updated, count = re.subn(
    r"MARKETING_VERSION = [^;]+;", f"MARKETING_VERSION = {expected};", text)
path.write_text(updated)
print(f"set MARKETING_VERSION = {expected} in {count} configurations")
