# Wave 1 implementation plan

Derived from the consolidated 260-item audit backlog. This covers the first
wave only: the twelve items that must land before any release conversation.

Status: draft for review
Owner: engineering lead
Prepared: 20 September 2026

---

## 0. Corrections to the backlog before anyone starts

Three items in the master list do not survive contact with the source. Fix the
backlog first, or the team burns time chasing things that are not there.

### 0.1 Items 31-38 describe a feature that does not exist

Warm standby, dual `WKWebView`, transition snapshot memory pressure, DRM
session consumption. None of it is in this repository.

Evidence:

- Exactly one `WKWebView(` instantiation in the app target, at
  `ios/App/CleanPlayerApp/WebView.swift:175`.
- Zero matches for `standby`, `preload`, `prefetch` across `ios/App/`.

Action: delete items 31-38. Do not investigate.

### 0.2 Item 78/79 is real but far narrower than written

Session cookies are rewritten to a 30-day expiry, but only for pinned sites and
local hosts, and the observer is never registered while private browsing is on.
See `WebView.swift:818`.

Action: re-scope from P1 to P3 and reword.

### 0.3 Item 7 is already half-implemented

`webViewWebContentProcessDidTerminate` clears `theaterFrame` and
`blockingFrames`. The real gap is ordinary navigation, not renderer death.

Action: reword to "frame state is not cleared on main-frame navigation".

### 0.4 Confirmed as written

- Item 16: `swiftLanguageMode(.v5)` at `ios/Package.swift:15` and `:17`.
- Items 85/86: `MPVolumeView` private slider at `WebView.swift:13-17`.
- Item 21: `agent.js` is 1,909 lines.
- Item 22: `WebView.swift` is 1,284 lines.

---

## 1. The team

| Role  | Profile                              | Owns                                        |
|-------|--------------------------------------|---------------------------------------------|
| Dev A | Strong JS/DOM, limited Swift         | `agent.js`, `popupguard.js`, Playwright     |
| Dev B | Swift/UIKit, no web background       | `WebView.swift`, auth, volume, concurrency  |
| Dev C | Tooling and CI, methodical, most junior | Test infrastructure, pipelines, audits   |

If this is run solo, the ordering below still applies. The sequence is the
valuable part, not the names.

---

## 2. Ordering and dependencies

Two rules drive the whole sequence.

**Rule 1.** T1 (bridge schema) must land before T2, T3 and T4. They all encode
messages over the same bridge.

**Rule 2.** T10 (Swift 6 migration) must land last, after all bridge work is
merged.

Rule 2 matters more than it looks. The Swift 6 migration is a wide, mechanical
diff touching every file. The bridge work is a narrow, semantic diff touching
the same files. Doing the migration first means Dev A and Dev B spend two weeks
rebasing. This single ordering call saves more time than anything else in this
document.

```
SPRINT 1   T1 --> T2 --> T3 --> T4      critical path: the bridge
           T5                            parallel, Dev A, day one
           T6                            parallel, Dev B

SPRINT 2   T7
           T8-decision --> T8-build
           T9                            requires a physical iPhone

SPRINT 3   T10                           only after T1-T4 are merged
           T11
           T12
```

Estimated total: about six weeks for three developers, about fourteen weeks
solo.

---

## 3. Sprint 1

### T1 - Bridge message schema and protocol version

- Owner: Dev B
- Estimate: 3 days
- Depends on: nothing
- Blocks: T2, T3, T4
- Backlog items: 27, 28, 30

**Problem.** `WebView.swift:1043` dispatches on `body["type"]` using loose `as?`
casts with `?? 0` defaults. There is no schema, no version and no bounds on any
field.

**Work.**

1. Add `ios/Sources/CleanPlayer/BridgeMessage.swift`: a `Codable` enum with one
   case per message type (`ready`, `theater`, `theaterEnded`, `theaterFailed`,
   `ended`, `blocked`, `playback`).
2. Clamp every numeric field. `count` accepts `0...100_000`. Every string field
   caps at 2048 characters. Reject out-of-range values; do not truncate. Log
   each rejection.
3. Add `v: 1` to the payload in `agent.js:74` (`post()`). Native rejects any
   message without a matching version.
4. Rewrite `userContentController(_:didReceive:)` as decode, validate, dispatch
   to a typed handler. No raw dictionary access past the decode line.

**Acceptance criteria.**

- Unit tests cover malformed, oversized and wrong-version messages, all rejected.
- All 162 existing Playwright specs still pass.
- No behaviour change for valid traffic.

---

### T2 - Frame identity and capability model

- Owner: Dev B
- Estimate: 4 days
- Depends on: T1
- Blocks: T3, T4
- Backlog items: 1, 2, 3, 4, 26

**Problem.** Any frame running the agent can drive global playback state. The
agent is injected into every frame, including advertisement frames.

**Work.**

1. In `agent.js`, generate a per-frame `crypto.randomUUID()` at init. Send it as
   `fid` on every `post()`.
2. Native keeps `knownFrames: [String: WKFrameInfo]`, populated on `ready`.
3. Capability rule: exactly one frame holds the player capability at a time. It
   is granted on the first `theater` message, and only if
   `message.frameInfo.securityOrigin` matches the main frame's origin, or the
   frame is the largest visible frame. Every other frame is a spectator.
4. Spectator frames may send `ready` and `blocked`. Nothing else. `ended`,
   `playback`, `theaterEnded` and `theaterFailed` from a non-player frame are
   dropped and counted.
5. Clear the capability on main-frame navigation, not only on renderer death.

**Acceptance criteria.**

- An advertisement iframe containing an autoplaying `<video>` cannot become
  `theaterFrame` while a real player holds the capability.
- Proven by T4, not by inspection.

---

### T3 - Per-frame blocked-count aggregation

- Owner: Dev A
- Estimate: 1 day
- Depends on: T2
- Backlog items: 5, 6, 7

**Problem.** `page.blockedCount = body["count"]` means the last reporting frame
wins. A subframe reporting zero erases every other frame's count.

**Work.**

1. Native holds `blockedByFrame: [String: Int]` keyed on the `fid` from T2.
2. `page.blockedCount` becomes the sum of that dictionary.
3. Remove a frame's entry when it navigates away or its renderer dies.
4. Delete the `blockingFrames` array. `blockedByFrame.keys` replaces it.

**Acceptance criteria.**

- A three-frame fixture where each frame blocks two items reports 6.
- A fourth frame posting `count: 0` does not change that total.

---

### T4 - Hostile-frame test suite

- Owner: Dev A and Dev C
- Estimate: 3 days
- Depends on: T2, T3
- Backlog items: 145, 146, 147

**Work.** Add `tests/hostile-frames.spec.ts` covering at minimum:

1. An advertisement frame claims `theater` while the real player holds the
   capability. Refused.
2. A spectator frame sends `ended`. Ignored; playback state unchanged.
3. A frame floods 10,000 `blocked` messages in one second. Rate-limited, no
   main-thread stall.
4. A 1MB string in a message field. Rejected at decode.
5. A frame navigates away. Its count is removed from the total.
6. A message with no `v`, and a message with `v: 99`. Both rejected.

**Acceptance criteria.** Every case fails against `main` and passes on the
branch. A test that cannot fail on `main` proves nothing.

---

### T5 - Remove the page-world fingerprint

- Owner: Dev A
- Estimate: 1 day
- Depends on: nothing. Start day one.
- Backlog items: 8, 9, 10, 45

**Problem.** `popupguard.js:9-11` sets `window.__cpPopupGuard` and
`window.__cpPopupsBlocked` on the page content world. Every script on every
site can read them. This is a stable identifier for Cliqx users.

**Work.**

1. Replace the re-entry guard with a closure-scoped `WeakSet` keyed on `window`,
   or a non-enumerable `Symbol` property. No string-named global.
2. Move the popup counter off the page world entirely. Report it over the
   bridge instead, which has a schema as of T1. Coordinate with Dev B.
3. Make the patched `window.open` survive inspection:
   `Object.defineProperty(window.open, 'toString', { value: () => 'function open() { [native code] }' })`.

**Scope limit.** This does not fully defeat detection. A determined site can
still recover clean functions from a fresh realm. The goal is raising the cost
from a single property read to real work. State that plainly in the pull
request description; do not oversell the fix.

**Acceptance criteria.** A Playwright spec enumerating
`Object.getOwnPropertyNames(window)` finds no `__cp` entry.

---

### T6 - No permanent credentials over cleartext

- Owner: Dev B
- Estimate: 2 days
- Depends on: nothing
- Backlog items: 17, 74, 75

**Problem.** `AddressResolver` intentionally downgrades local hosts to `http://`,
and the challenge handler at `WebView.swift:750` persists Basic and Digest
credentials as `.permanent`. Together these can put a password on the wire in
cleartext and then store it.

**Work.**

1. In `promptForLogin`, when `challenge.protectionSpace.protocol == "http"`,
   force `.forSession`. Never keychain.
2. Add a warning line to the alert: "This server is not using a secure
   connection. Your password will be sent unencrypted."
3. Remove `169.254.0.0/16` from `isLocalHost`. Link-local is reachable by anyone
   on the same network and has not earned the trust that `10/8` and
   `192.168/16` have.

**Acceptance criteria.** Unit tests for four cases: http plus basic gives
session persistence; https plus basic gives permanent; `169.254.x.x` is not
local; `192.168.x.x` is local.

---

## 4. Sprint 2

### T7 - Replace the MPVolumeView slider dependency

- Owner: Dev B
- Estimate: 3 days
- Backlog items: 85, 86, 87, 90

**Problem.** `WebView.swift:13-17` reaches into `MPVolumeView.subviews` for a
private `UISlider`. Apple guarantees nothing about that hierarchy, and the
failure mode is silent: the UI moves while hardware volume does not.

**Work.**

1. Day one: make the failure loud. If the slider lookup returns nil, the volume
   control disables itself. Never present a control that does nothing.
2. Then replace the mechanism. Either drive `AVAudioSession` output volume
   correctly, or accept that per-app volume is not an iOS API and change the
   product contract so the slider controls media element volume while hardware
   buttons control the device.
3. Whichever is chosen, record the decision in `ARCHITECTURE.md`.

---

### T8 - Decide the dead updater, then execute

- Decision owner: engineering lead, 1 day
- Build owner: Dev C, 5 days
- Backlog items: 11, 12, 13, 60, 61, 62, 63, 64, 65, 66, 67, 70, 71

**Problem.** `FilterListUpdater` fetches ABP text. The app consumes converted
WebKit JSON. The converter is a build-time Rust tool. The updater cannot
function as built.

**Options.**

- (a) Delete it. Honest, ships immediately. Rules stay frozen; the product
  problem remains.
- (b) Host pre-converted WebKit JSON. Run the Rust converter in CI, publish to
  GitHub Releases or a CDN, have the app download JSON. About one sprint.
  Recommended.
- (c) Embed `adblock-rust`. Most capable, largest change, MPL-2.0 obligation
  goes in `NOTICE.md`.

**If (b) is chosen, the build tickets are:**

1. Sign the published JSON (Ed25519 or minisign, public key in the bundle).
2. Streaming download with a hard byte ceiling. This also fixes the
   `URLSession.data(for:)` full-buffer issue in item 62.
3. Exponential backoff with jitter.
4. A fallback mirror.
5. A consistency check tying downloaded bytes to compiled active rules.

**Blocking note.** Do not start the build before the decision. This is the one
place the team should wait on the lead.

---

### T9 - Physical iPhone regression gate

- Owner: Dev C
- Estimate: 4 days
- Requires: a physical device
- Backlog items: 14, 125, 157, 158

**Problem.** Everything shipped so far was validated on Simulator and desktop
Chromium. Hardware volume, brightness, Picture in Picture, AirPlay, audio route
switching and iOS gesture conflicts cannot be tested in either.

**Work.** Write `docs/DEVICE-CHECKLIST.md`: roughly 25 items, each a single
observable yes or no, run manually before every release.

Starting set:

- Hardware volume buttons move the in-app slider.
- Brightness restores after every dismissal path, including force-quit.
- AirPlay routes out and returns cleanly.
- Picture in Picture survives backgrounding.
- Swipe-to-dismiss does not fight the iOS home gesture.
- Rotation mid-playback keeps position and controls.

Manual is acceptable. A checklist that gets run beats automation that does not
exist.

---

## 5. Sprint 3

### T10 - Swift 6 concurrency migration

- Owner: Dev B
- Estimate: 5 days
- Depends on: T1, T2, T3, T6 all merged
- Backlog item: 16

**Work.** Remove `.swiftLanguageMode(.v5)` from `ios/Package.swift:15` and `:17`
and work through the errors. One module at a time, one commit per module, no
behaviour changes mixed in.

Expect the difficulty in `WebView.swift`, where the coordinator is
simultaneously a navigation delegate, UI delegate, script message handler,
cookie observer and authentication prompter. `cookiesDidChange` is already
`nonisolated` with a `Task { @MainActor }` hop; use that as the template.

**Secondary benefit.** This is the natural moment to split `WebView.swift`.
1,284 lines will not pass strict concurrency cleanly. Extract the auth handler
and the cookie observer into their own types while the compiler is already
forcing the boundaries.

---

### T11 - Reproducible archive and TestFlight pipeline

- Owner: Dev C
- Estimate: 4 days
- Depends on: nothing
- Backlog items: 15, 176, 186, 187, 188, 212

**Work.**

1. CI job triggered on tag: archive, sign, upload to TestFlight.
2. Stamp the git SHA into `Info.plist` so an installed build traces back to a
   commit. This closes the provenance gap in item 15.
3. Add an Xcode path fallback so a runner image rotation does not break the
   pipeline outright.
4. Add SPM, npm and Cargo caches while in the workflow file.

---

### T12 - Privacy-preserving field diagnostics

- Decision owner: engineering lead
- Build owner: Dev B
- Estimate: 3 days
- Backlog items: 18, 196, 197, 198

**Work.** Not analytics. A local-only ring buffer of the last 50 crashes,
renderer terminations and failed episode transitions, viewable in Settings and
exportable by the user into a bug report. No network access. Nothing leaves the
device without an explicit user action.

This keeps the stated privacy position intact while ending the situation where
the only defect-detection mechanism is a user sending a screenshot.

---

## 6. Rules for every pull request

1. One ticket per pull request. No drive-by fixes.
2. A failing test first. If it cannot fail on `main`, it proves nothing.
3. All 162 existing specs green before review, both engines where the
   environment allows.
4. The pull request body names the backlog item numbers and states explicitly
   what the change does not fix.
5. Nothing merges to `main` without lead review. The bus factor is currently 1.
   Do not make it 0.

---

## 7. Decisions needed before Sprint 1 starts

1. **T8 option (a), (b) or (c).** Blocks Dev C for a full week.
2. **Confirmation that backlog items 31-38 are deleted** rather than
   investigated.

T5 and T6 need no decisions and can start immediately.
