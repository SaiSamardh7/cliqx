#!/usr/bin/env python3
"""Checks the Info.plist wiring, which fails silently in three ways.

The app enables Picture in Picture and AirPlay. Both suspend the moment the
screen locks unless the target declares the `audio` background mode — there is
no build error, no warning, and no symptom until someone locks their phone
mid-episode and the sound stops.

Guarded here because every way of getting this wrong is quiet:

1. `INFOPLIST_KEY_UIBackgroundModes` looks like it works and does nothing.
   Xcode maps only a documented subset of keys through INFOPLIST_KEY_*, and
   UIBackgroundModes is not one of them; an unsupported setting is ignored
   rather than rejected.

2. Putting the file inside `CleanPlayerApp/` breaks the build instead — that
   directory is a PBXFileSystemSynchronizedRootGroup, so the plist is also
   copied in as a resource and the build fails with "Multiple commands
   produce". That one at least announces itself.

3. Dropping INFOPLIST_FILE from one configuration but not the other ships a
   Release build without the capability a Debug build had.
"""
import plistlib
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROJECT = ROOT / "ios/App/CleanPlayerApp.xcodeproj/project.pbxproj"
PLIST = ROOT / "ios/App/CleanPlayerApp-Info.plist"
SYNCED_DIR = ROOT / "ios/App/CleanPlayerApp"

REQUIRED_MODES = {"audio"}

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


project = PROJECT.read_text()

# One per app-target configuration, Debug and Release. The UI test target has
# no display name and must not gain a plist of its own.
declared = len(re.findall(r"INFOPLIST_FILE = \"?CleanPlayerApp-Info\.plist\"?;", project))
check(declared == 2,
      f"INFOPLIST_FILE is set in {declared} configurations, expected 2 "
      "(Debug and Release of the app target)")

check("INFOPLIST_KEY_UIBackgroundModes" not in project,
      "INFOPLIST_KEY_UIBackgroundModes is set. Xcode ignores it silently — "
      "the key has to live in the Info.plist file instead.")

check("GENERATE_INFOPLIST_FILE = YES" in project,
      "GENERATE_INFOPLIST_FILE is off, so the keys that DO come from build "
      "settings would stop being merged into the file")

check(PLIST.is_file(), f"{PLIST.relative_to(ROOT)} is missing")

check(not (SYNCED_DIR / "Info.plist").exists(),
      "Info.plist is inside the filesystem-synchronized source folder, so it "
      "is copied in as a resource too — the build fails with 'Multiple "
      "commands produce'. Keep it beside the folder, not in it.")

if PLIST.is_file():
    with PLIST.open("rb") as handle:
        content = plistlib.load(handle)
    modes = set(content.get("UIBackgroundModes", []))
    missing = REQUIRED_MODES - modes
    check(not missing,
          f"UIBackgroundModes is missing {sorted(missing)} — Picture in "
          "Picture and AirPlay will stop when the screen locks")

if failures:
    print("Info.plist wiring:")
    for failure in failures:
        print(f"  FAIL  {failure}")
    sys.exit(1)

print("ok    Info.plist: UIBackgroundModes declares "
      f"{sorted(REQUIRED_MODES)}, wired into both configurations")
