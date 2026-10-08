# Building Cliqx

Everything in here was learned by hitting it. Read the device section before
you plug a phone in; two of the three failures below look like broken tooling
and are not.

Requires **Xcode 26.2** and an iOS 17+ target. CI pins the same Xcode.

## Simulator

```bash
cd ios/App && xcodebuild build -scheme CleanPlayerApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Simulator builds are unsigned on purpose —
`CODE_SIGNING_ALLOWED[sdk=iphonesimulator*]` is off — so nothing in CI signs,
and a checkout under `~/Desktop` still builds.

## Tests

```bash
# Swift unit + UI, on a simulator destination
cd ios && xcodebuild test -scheme CleanPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# Page agent, in both engines
npm ci && npx playwright install chromium webkit && npx playwright test
```

**`swift test` does not work, and cannot.** `Package.swift` declares
`.iOS(.v17)` only and the sources use iOS-only WebKit and CryptoKit APIs, so a
host build fails to compile. An iOS Simulator destination is the only option.

WebKit is not optional in the Playwright matrix: Mode B is built on
`webkitEnterFullscreen`, which Chromium does not have.

CI picks its simulator by UDID via `tools/pick-simulator.py`, because
`xcodebuild` cannot resolve a simulator by *name* for the package scheme — it
reports the scheme's supported platforms as empty, offers no concrete
simulators, and the job exits 70.

## Device

### Build outside `~/Desktop`, `~/Documents` and `~/Downloads`

macOS stamps files under those directories with a `com.apple.provenance`
extended attribute that `codesign` rejects as "resource fork, Finder
information, or similar detritus". `xattr -c` cannot remove it.

`-derivedDataPath /tmp/dd` is what keeps the build products out of such a
directory, which is why the repository itself can live anywhere.

### The two commands want different ids for the same phone

Passing one where the other belongs is the usual reason an install stops
working.

| Command | Wants | Looks like | Get it from |
|---|---|---|---|
| `xcodebuild -destination` | **hardware** id | `00008130-000C203E1E90001C` | `xcodebuild -scheme CleanPlayerApp -showdestinations` |
| `devicectl` | **CoreDevice** id | `FE3646BF-9AB2-587F-AAC7-C7785C465700` | `xcrun devicectl list devices` |

Handing the CoreDevice UUID to `xcodebuild` fails with "Unable to find a device
matching the provided destination specifier", even with the phone plugged in
and visible in Xcode.

```bash
cd ios/App && xcodebuild -scheme CleanPlayerApp \
  -destination 'platform=iOS,id=<hardware-id>' \
  -derivedDataPath /tmp/dd -allowProvisioningUpdates build

xcrun devicectl device install app --device <coredevice-uuid> \
  /tmp/dd/Build/Products/Debug-iphoneos/CleanPlayerApp.app
```

### Signing

Device builds need `DEVELOPMENT_TEAM` in `project.pbxproj`. It is committed,
the same value in all four configurations, because this repository builds to one
person's device. Fork it and you will want your own.

## Versioning

The version lives in [`VERSION`](../VERSION) and nowhere else.
`tools/set-version.py` writes it into every configuration and
`tools/check-version.py` fails CI when they drift — two configurations once
carried 0.1 while two carried 1.0, so which version shipped depended on which
scheme was built.

## Regenerating the filter rules

Needs a Rust toolchain. Downloads EasyList, EasyPrivacy and Fanboy's Annoyance,
converts ABP syntax to WebKit content-blocker JSON, compresses it, and rewrites
the manifest:

```bash
./tools/convert-filters.sh
```

The manifest's `generatedSha256` keys WebKit's compiled-list cache, so it must
match the shipped payload. CI checks this, and so does the Swift suite.

## What CI runs

Four jobs, on every push to `main` and every pull request:

1. Swift tests on an iOS Simulator
2. UI tests on an iOS Simulator
3. The page agent in Chromium and WebKit
4. Rule, icon, version and test-count checks

The workflow collapses `push` and `pull_request` into one run per commit. They
did not collapse before — their refs differ (`refs/heads/x` against
`refs/pull/N/merge`) — and two full macOS matrices fought over the same
runners. The failures that produced ("Timed out while launching application via
Xcode", "Failed to terminate", a pure-logic assertion taking nine seconds) had
nothing to do with the code under test.
