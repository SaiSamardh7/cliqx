#!/usr/bin/env python3
"""Guard App Store privacy and packaging declarations that fail only at upload."""
import pathlib
import plistlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP_MANIFEST = ROOT / "ios/App/CleanPlayerApp/PrivacyInfo.xcprivacy"
VLC_MANIFEST = ROOT / "ios/App/MobileVLCKit-PrivacyInfo.xcprivacy"
INFO_PLIST = ROOT / "ios/App/CleanPlayerApp-Info.plist"
PROJECT = ROOT / "ios/App/CleanPlayerApp.xcodeproj/project.pbxproj"

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def reasons(path):
    with path.open("rb") as handle:
        manifest = plistlib.load(handle)
    check(manifest.get("NSPrivacyTracking") is False,
          f"{path.name} must explicitly declare no tracking")
    check(manifest.get("NSPrivacyCollectedDataTypes") == [],
          f"{path.name} must explicitly declare no collected data")
    return {
        item["NSPrivacyAccessedAPIType"]: set(item["NSPrivacyAccessedAPITypeReasons"])
        for item in manifest.get("NSPrivacyAccessedAPITypes", [])
    }


for required in (APP_MANIFEST, VLC_MANIFEST, INFO_PLIST, PROJECT):
    check(required.is_file(), f"missing {required.relative_to(ROOT)}")

if APP_MANIFEST.is_file():
    app = reasons(APP_MANIFEST)
    check("35F9.1" in app.get("NSPrivacyAccessedAPICategorySystemBootTime", set()),
          "app manifest must declare 35F9.1 for the bridge rate-limit timer")

if VLC_MANIFEST.is_file():
    vlc = reasons(VLC_MANIFEST)
    expected = {
        "NSPrivacyAccessedAPICategoryFileTimestamp": {"C617.1", "3B52.1"},
        "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1"},
        "NSPrivacyAccessedAPICategoryDiskSpace": {"E174.1"},
    }
    for category, declared in expected.items():
        check(declared <= vlc.get(category, set()),
              f"VLCKit manifest is missing {category}: {sorted(declared)}")

if INFO_PLIST.is_file():
    with INFO_PLIST.open("rb") as handle:
        info = plistlib.load(handle)
    check(info.get("ITSAppUsesNonExemptEncryption") is False,
          "Info.plist must declare ITSAppUsesNonExemptEncryption=false")

if PROJECT.is_file():
    project = PROJECT.read_text()
    check("Install VLCKit privacy manifest" in project,
          "Xcode target does not install the VLCKit manifest")
    check("MobileVLCKit.framework/PrivacyInfo.xcprivacy" in project,
          "VLCKit manifest output path is not declared")

if failures:
    print("App Store readiness:")
    for failure in failures:
        print(f"  FAIL  {failure}")
    sys.exit(1)

print("ok    App Store privacy manifests, export compliance and VLCKit packaging")
