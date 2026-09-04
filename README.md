# Cliqx

**iOS only.** Cliqx is a native iPhone and iPad app, and there is no Android,
web or desktop version — not planned, not in progress. The whole approach is
built on iOS-specific WebKit APIs (`WKContentWorld`, `WKContentRuleList`,
`webkitEnterFullscreen`), so it does not port. Requires **iOS 17 or later**.

An iOS browser for watching video: it blocks advertising and tracking requests,
cancels popups before they open, hides the overlays that sit on top of players,
and offers a native "Watch clean" player with next/previous episode controls.

No account, no server, no analytics, no third-party SDKs.

## Status

Pre-release, and not on the App Store yet. The engineering is in place and
covered by tests — 190 Playwright specs across Chromium and WebKit, plus the
XCTest suite — but see [`docs/ROADMAP.md`](docs/ROADMAP.md) for what is still
open before submission.

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — how it works and why
- [`NOTICE.md`](NOTICE.md) — third-party licences and obligations
- [`PRIVACY.md`](PRIVACY.md) — privacy policy
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — everything left before release, and who unblocks it
- [`docs/FILTER-ENGINE.md`](docs/FILTER-ENGINE.md) — engine and licence assessment, and why we pick what we pick
- [`docs/APP-STORE.md`](docs/APP-STORE.md) — submission status and what is open

## Layout

```
ios/Sources/CleanPlayer/   Swift package: rules, settings, WebKit setup
ios/Tests/                 XCTest suite
ios/App/                   The app target (Xcode project)
tests/                     Playwright suite for the injected page agent
tools/                     Build-time filter-list converter (Rust)
```

## Running the tests

**`swift test` does not work, and cannot.** `Package.swift` declares
`.iOS(.v17)` only and the sources use iOS-only WebKit and CryptoKit APIs, so a
host build fails to compile. An iOS Simulator destination is the only option:

```bash
cd ios && xcodebuild test -scheme CleanPlayer -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The page agent runs in both Chromium and WebKit. WebKit is not optional — Mode
B is built on `webkitEnterFullscreen`, which Chromium does not have:

```bash
npm ci && npx playwright install chromium webkit && npx playwright test
```

## Building for a device

Build somewhere outside `~/Desktop`, `~/Documents` or `~/Downloads`. macOS
stamps files under those with a `com.apple.provenance` attribute that `codesign`
rejects as "resource fork, Finder information, or similar detritus", and
`xattr -c` cannot remove it:

```bash
cd ios/App && xcodebuild -scheme CleanPlayerApp -destination 'platform=iOS,id=<device-id>' -derivedDataPath /tmp/dd -allowProvisioningUpdates build
```

`xcrun devicectl list devices` gives the id; `xcrun devicectl device install app
--device <id> /tmp/dd/Build/Products/Debug-iphoneos/CleanPlayerApp.app` installs
it. Simulator builds are unsigned (`CODE_SIGNING_ALLOWED[sdk=iphonesimulator*]`)
and are unaffected.

## Building and running the app

```bash
cd ios/App && xcodebuild build -scheme CleanPlayerApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Regenerating the filter rules

Needs a Rust toolchain. Downloads EasyList and EasyPrivacy, converts them to
WebKit content-blocker JSON, compresses them and rewrites the manifest:

```bash
./tools/convert-filters.sh
```

The manifest's `generatedSha256` keys WebKit's compiled-list cache, so it must
match the shipped payload — CI checks this, and so does the Swift suite.

## Licence

MIT — see [`LICENSE`](LICENSE). The generated filter-rule data under
`ios/App/CleanPlayerApp/Resources/rules/` is a derived work of EasyList and is
offered under CC BY-SA 3.0 instead; [`NOTICE.md`](NOTICE.md) sets out that split
and the attribution it requires.
