#!/usr/bin/env python3
"""Guards the app icon.

Both failures this catches are silent: a target with no
ASSETCATALOG_COMPILER_APPICON_NAME builds fine and ships with no icon, and an
icon with an alpha channel builds fine and is rejected at upload. Neither shows
up in any test.

Reads the PNG header directly rather than importing Pillow — the CI runner for
this check is plain Ubuntu, and IHDR is thirteen fixed bytes.
"""
import pathlib
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PBXPROJ = ROOT / "ios/App/CleanPlayerApp.xcodeproj/project.pbxproj"
ICONSET = ROOT / "ios/App/CleanPlayerApp/Assets.xcassets/AppIcon.appiconset"
ICON = ICONSET / "icon-1024.png"

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
COLOUR_TYPES_WITH_ALPHA = {4, 6}


def png_header(path: pathlib.Path) -> tuple[int, int, int]:
    """Returns (width, height, colour type) from IHDR."""
    raw = path.read_bytes()[:26]
    if raw[:8] != PNG_MAGIC or raw[12:16] != b"IHDR":
        raise ValueError(f"{path.name} is not a PNG")
    width, height = struct.unpack(">II", raw[16:24])
    return width, height, raw[25]


def main() -> int:
    problems = []

    setting = "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;"
    found = PBXPROJ.read_text().count(setting)
    # Debug and Release both, or one configuration ships iconless.
    if found < 2:
        problems.append(
            f"{setting} appears in {found} build configurations, expected 2")

    if not (ICONSET / "Contents.json").is_file():
        problems.append(f"{ICONSET}/Contents.json is missing")

    if not ICON.is_file():
        problems.append(f"{ICON} is missing — regenerate with tools/make-icon.py")
    else:
        width, height, colour = png_header(ICON)
        if (width, height) != (1024, 1024):
            problems.append(f"{ICON.name} is {width}x{height}, must be 1024x1024")
        if colour in COLOUR_TYPES_WITH_ALPHA:
            problems.append(
                f"{ICON.name} has an alpha channel; App Store Connect rejects it")

    for problem in problems:
        print(f"FAIL  {problem}")
    if problems:
        return 1
    print("ok    app icon: 1024x1024, opaque, wired into both configurations")
    return 0


if __name__ == "__main__":
    sys.exit(main())
