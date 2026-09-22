# Cliqx — the 9/10 fix list

_Generated 21 September 2026 from a full read of the repo against the 15-section
release checklist. Every ❌ and ⚠️ from that audit is here, ordered by severity._

**Severity**

- **S1 — Fix before anyone else installs it.** Security defects, claims that are
  false, data loss, and App Store blockers. Small, well-defined, mostly one file each.
- **S2 — Fix before 1.0.** Bugs users will hit in the first hour, missing core
  capability, robustness gaps. Medium size.
- **S3 — Fix to earn the 9.** Architecture, tests, accessibility, localization,
  CI/ops, measurement. Larger, less urgent, mostly parallelisable.
- **Gate — Not code.** Verification on hardware, people and process. Do last.

Tick the box, keep the ID in the commit message (`S1-04: …`), and delete the
row when it lands so the file stays a to-do list, not a history.

**Status, 22 September 2026.** S1 is done except S1-12, which is a privacy
policy URL and a contact address — yours to supply, not mine to invent. The S2
audio group (01, 02, 03, 05, 06) has landed; S2-04 is folded into S2-02, since
the volume control no longer touches system volume at all. The episode group
(07, 08, 10, 11, 12, 13) has landed too. S2-09 is still open: the agent and
native still disagree about what "same site" means.

---

## S1 — Fix before anyone else installs it

### Security

- [x] **S1-01 Permanent HTTP credentials for any RFC1918/link-local host.**
  `isOwnHost` returns true for every private IP, so a NAS password typed once is
  auto-replayed in Basic auth to whatever holds that IP on the next Wi-Fi.
  [BrowserModel.swift:256](../ios/App/CleanPlayerApp/BrowserModel.swift:256),
  [WebView.swift:1053](../ios/App/CleanPlayerApp/WebView.swift:1053).
  *Do:* `isOwnHost` = pinned only. *Done when:* package test asserts an
  unpinned `192.168.1.1` challenge gets `.forSession`.
- [x] **S1-02 Session cookies made persistent for pinned hosts.** Server said
  "die on close"; app rewrites with 30-day expiry, including auth/CSRF cookies.
  [WebView.swift:1081](../ios/App/CleanPlayerApp/WebView.swift:1081).
  *Do:* opt-in "Stay signed in" toggle per pinned site; skip cookies with
  `Secure`+`HttpOnly` unless opted in; keep every original attribute.
  *Done when:* test rebuilds a cookie and diff of `properties` is only `expires`.
- [x] **S1-03 "Is this Jellyfin?" passes when `ProductName` is nil**, then POSTs
  the password. [Jellyfin.swift:176](../ios/App/CleanPlayerApp/Jellyfin.swift:176).
  *Do:* `?? false`, and require `Id` + `Version` present.
- [x] **S1-04 Page controls a number in native UI.** `window.__cpPopupsBlocked`
  is page-writable and displayed. [WebView.swift:1293](../ios/App/CleanPlayerApp/WebView.swift:1293).
  *Do:* count only native-held popups, or move the counter to the isolated world
  and have the page-world guard report via a nonce'd `postMessage`. Clamp ≥ 0.
- [x] **S1-05 Any frame can write player state.** `time`, `playback`, `volume`,
  `tracks`, `video`, `airplay` are accepted from every frame of the current web
  view, not just `theaterFrame`. [WebView.swift:1310](../ios/App/CleanPlayerApp/WebView.swift:1310).
  *Do:* for those message kinds, require `message.frameInfo` to match
  `theaterFrame` (isMainFrame + request.url). *Done when:* Playwright spec with
  an ad iframe posting `time` does not move the seek bar.
- [x] **S1-06 Link-local (`169.254.x`) treated as trusted local.**
  [AddressResolver.swift:65](../ios/Sources/CleanPlayer/AddressResolver.swift:65).
  *Do:* drop `(169, 254)` from the trusted set; keep it http-default only.
- [x] **S1-07 Page-derived strings rendered unbounded in native UI** — scheme,
  host, realm, source/track labels, page title.
  [WebView.swift:930](../ios/App/CleanPlayerApp/WebView.swift:930), `case "video"`,
  `case "tracks"`. *Do:* one `sanitizedForUI(_:)` helper: ≤ 120 chars, strip
  bidi controls (U+202A–202E, U+2066–2069), collapse whitespace. Apply everywhere.

### Claims that are false

- [x] **S1-08 VLCKit is a third-party SDK and is declared nowhere.**
  [PRIVACY.md:33](../PRIVACY.md:33), [README.md:13](../README.md:13),
  [NOTICE.md](../NOTICE.md), [docs/APP-STORE.md](APP-STORE.md).
  *Do:* NOTICE entry (LGPL-2.1+, relink obligation, source URL, pinned version);
  reword "no third-party SDKs" → "no analytics or tracking SDKs; VLCKit for playback".
- [x] **S1-09 Privacy policy says rules are never fetched; the binary links a
  downloader.** [PRIVACY.md:41](../PRIVACY.md:41), [FilterListUpdater.swift](../ios/Sources/CleanPlayer/FilterListUpdater.swift).
  *Do:* either wire it (see S2-30) and update the policy, or delete the updater
  and its tests. Not both.
- [x] **S1-10 README says `DEVELOPMENT_TEAM` is committed empty; it isn't.**
  [project.pbxproj:226](../ios/App/CleanPlayerApp.xcodeproj/project.pbxproj:226), `:257`.
  *Do:* pick a policy, apply to all four configs, fix README.
- [x] **S1-11 Two `MARKETING_VERSION`s (0.1 and 1.0).**
  [project.pbxproj:240](../ios/App/CleanPlayerApp.xcodeproj/project.pbxproj:240), `:338`.
  *Do:* one value, driven from a `VERSION` file; `JellyfinAPI.version` reads it.
- [ ] **S1-12 Privacy policy has no contact address and no public URL.**
  [PRIVACY.md:56](../PRIVACY.md:56). *Do:* address + host the page; put URL in APP-STORE.md.
- [x] **S1-13 Test counts in README/ROADMAP are wrong** (says 66 XCTest / 198
  specs; repo has 126 / 165×2). *Do:* `tools/count-tests.sh` writes them; CI diffs.

### Crashes and data loss

- [x] **S1-14 Force-unwraps in the network layer.** `URLComponents(...)!`,
  `parts.url!`. [Jellyfin.swift:284-286](../ios/App/CleanPlayerApp/Jellyfin.swift:284).
  *Do:* return `nil`/throw `Failure.badURL`.
- [x] **S1-15 `try!` in a security helper.**
  [EpisodeTransition.swift:49](../ios/Sources/CleanPlayer/EpisodeTransition.swift:49).
  *Do:* `try?` + fallback to a hand-escaped literal.
- [x] **S1-16 Corrupt store = silently empty library.** `try? decode` in
  `BrowserModel.init`, `MediaLibrary.init`, `JellyfinServers.init`.
  *Do:* on decode failure, move the blob to `<key>.corrupt-<date>` and log; never
  overwrite it with `[]` on the next `persist()`.
- [x] **S1-17 Keychain write is delete-then-add.**
  [Jellyfin.swift:389](../ios/App/CleanPlayerApp/Jellyfin.swift:389).
  *Do:* `SecItemUpdate`, add on `errSecItemNotFound`.
- [x] **S1-18 Simulator Keychain shim stores tokens in UserDefaults and is keyed
  on target, not `DEBUG`.** [Jellyfin.swift:361](../ios/App/CleanPlayerApp/Jellyfin.swift:361).
  *Do:* `protocol TokenStore` injected into `JellyfinServers`; real Keychain in
  the app, in-memory fake in tests. Delete the `#if`.
- [x] **S1-19 JS `alert()`/`confirm()`/`prompt()`/auth prompt never complete if
  the presenter is busy** — WebKit's synchronous dialog then freezes the frame.
  [WebView.swift:1421](../ios/App/CleanPlayerApp/WebView.swift:1421).
  *Do:* a `DialogQueue` that waits for `presentedViewController == nil`; every
  completion handler is guaranteed to be called exactly once.

---

## S2 — Fix before 1.0

### Audio and media session

- [x] **S2-01 Audio session is never deactivated.** No `setActive(false)` in the
  codebase; other apps' audio never resumes. [MediaSession.swift](../ios/Sources/CleanPlayer/MediaSession.swift).
  *Do:* `MediaSession.deactivate()` with `.notifyOthersOnDeactivation`, called
  from `exitTheater`, `ServerEngine.close`, local player close.
- [x] **S2-02 Web Audio boost breaks AirPlay and background audio.**
  `createMediaElementSource` is irreversible for the element. [agent.js:406](../ios/App/CleanPlayerApp/Resources/agent.js:406).
  *Do:* only create the context when the user goes > 100; grey out 101–200 while
  `airplayAvailable` or in PiP; tear down on `unstage`; document the trade-off
  in the volume menu.
- [x] **S2-03 No interruption / route-change handling.** No
  `AVAudioSession.interruptionNotification` or `routeChangeNotification`.
  *Do:* pause on interruption begin and on headphones-unplug (`oldDeviceUnavailable`);
  resume on `shouldResume`.
- [ ] **S2-04 `MPVolumeView` private-subview slider hack.**
  [WebView.swift:16](../ios/App/CleanPlayerApp/WebView.swift:16).
  *Do:* decide: (a) drop 0–100 for web and show only boost, or (b) keep system
  volume but drive it through `MPVolumeView` as a real (hidden) view with
  `setVolumeThumbImage`-free interaction. No `subviews` walking.
- [x] **S2-05 Hearing-safety warning on first boost > 100.** One-time alert,
  remembered in settings.
- [x] **S2-06 Brightness not restored after playback.**
  [PlayerOverlay.swift:190](../ios/App/CleanPlayerApp/PlayerOverlay.swift:190), LocalMedia.
  *Do:* remember `UIScreen.main.brightness` on theater enter; restore on exit
  unless the user changed it outside the gesture.

### Episode discovery and resume

- [x] **S2-07 Pagination links become "Next episode" and auto-advance.**
  `NEXT_RE = /\bnext\b/i`, `EPISODE_RE` matches bare numbers.
  [agent.js:1067](../ios/App/CleanPlayerApp/Resources/agent.js:1067).
  *Do:* the up-next countdown requires an *episode signal* (`rel=next`, a
  numbered list ≥ 2, or a site control). Text-only matches populate the button
  but never the countdown. Fixture: docs page with "Next »".
- [x] **S2-08 `resumeKey` strips `t`, `ref`, `si`, `start` globally**, merging
  distinct pages. [AddressResolver.swift:119](../ios/Sources/CleanPlayer/AddressResolver.swift:119).
  *Do:* strip `t`/`start`/`time_continue` only when the value looks like seconds
  (`^\d+s?$|^\d+m\d+s$`); never strip `ref`/`si`. Add the false-positive test.
- [ ] **S2-09 `sameOriginURL` uses exact origin; native uses registrable site.**
  [agent.js:1079](../ios/App/CleanPlayerApp/Resources/agent.js:1079),
  [WebView.swift:747](../ios/App/CleanPlayerApp/WebView.swift:747).
  *Do:* one definition. Native re-validation with `HostKey.isSameSite`; agent
  compares `hostname` suffix against a PSL-derived site passed in at injection.
- [x] **S2-10 Warm standby loads the next page with autoplay on, invisibly.**
  Ad frames can play audio; sites may count a view or post progress.
  [WebView.swift:648](../ios/App/CleanPlayerApp/WebView.swift:648).
  *Do:* standby gets its own `WKWebViewConfiguration` copy with
  `mediaTypesRequiringUserActionForPlayback = .all` plus a page-world
  `play()` guard at document start; un-guard on promote.
- [x] **S2-11 Theater hides sibling-rendered subtitles.**
  [agent.js:153](../ios/App/CleanPlayerApp/Resources/agent.js:153).
  *Do:* in `stage()`, keep siblings that look like caption layers
  (`.vjs-text-track-display, .jw-captions, [class*=caption], [class*=subtitle]`
  or a text-only absolutely-positioned overlay inside the player box).
  Fixture with a JW-style caption div.
- [x] **S2-12 Only one of four theater marks is defended.**
  [agent.js:1338](../ios/App/CleanPlayerApp/Resources/agent.js:1338).
  *Do:* add `data-cp-hidden`, `data-cp-stage`, `data-cp-theater` to
  `attributeFilter`; re-assert on removal.
- [x] **S2-13 DRM / protected video gives no message.** *Do:* on `encrypted`
  event or `error.code === MEDIA_ERR_SRC_NOT_SUPPORTED` with EME present, post
  `theaterFailed(reason: 'drm')`; native shows "This site uses DRM Cliqx can't play."

### Browser

- [ ] **S2-14 Address resolution edge cases.** `3.14`, `movie.mkv`,
  `S01E02.1080p` → hosts; `nas:8096` → search.
  [AddressResolver.swift:24-52](../ios/Sources/CleanPlayer/AddressResolver.swift:24).
  *Do:* require a known TLD (bundle the PSL you already ship) or a local
  pattern; treat `word:port` with no dot as a host. Tests for each.
- [ ] **S2-15 Local HTTP needs informed intent.** Silent `http://` default.
  *Do:* first navigation to a cleartext local host shows a one-time sheet
  ("Unencrypted connection to your network — OK for a home server"); remembered
  per host.
- [ ] **S2-16 HTTP credential prompt has no cleartext warning.**
  [WebView.swift:1023](../ios/App/CleanPlayerApp/WebView.swift:1023).
  *Do:* subtitle "Sent unencrypted" when `protectionSpace.protocol == "http"`;
  show the scheme + host + port.
- [ ] **S2-17 Toggling private browsing destroys active playback silently.**
  [BrowserView.swift:31](../ios/App/CleanPlayerApp/BrowserView.swift:31).
  *Do:* if `page.isTheater`, confirm first ("This will stop the video").
- [ ] **S2-18 Downloads silently do nothing.** No `decidePolicyFor
  navigationResponse`, no `WKDownloadDelegate`.
  *Do:* implement both; non-renderable → Save to Files sheet; show progress.
- [ ] **S2-19 Clear website data has no confirmation.**
  [SettingsView.swift:150](../ios/App/CleanPlayerApp/SettingsView.swift:150).
  *Do:* `confirmationDialog`, and reset `clearedData` when the view reappears.
- [ ] **S2-20 Invalid-TLS regression test.** Package test with a `URLProtocol`
  that issues a `ServerTrust` challenge and asserts `.performDefaultHandling`
  (no override path exists — prove it stays that way).

### Recents and progress

- [ ] **S2-21 No way to clear playback progress.** `clearRecents()` leaves
  `episodeProgress`. *Do:* separate "Clear playback history" button; footer
  text says what each button keeps.
- [ ] **S2-22 Removing a series can't remove its hidden history.** *Do:* swipe
  action "Remove and forget progress".
- [ ] **S2-23 Progress and thumbnails have no retention.** *Do:* cap
  `episodeProgress` at 500 entries / 180 days; thumbnails pruned to 100 files
  on launch (LRU by mtime).
- [ ] **S2-24 Web recents cards show no remaining time.**
  [HomeView.swift:347](../ios/App/CleanPlayerApp/HomeView.swift:347).
  *Do:* reuse `PlayerFormatting` for "23 min left".
- [ ] **S2-25 Web progress has no completed flag.** `at > 3` only.
  *Do:* `completed` when ≥ 95 %, hide the bar, don't seek on re-entry.
- [ ] **S2-26 `migrateAndCollapseRecents` rewrites stores on every launch.**
  *Do:* schema version int in each store; migrate once.

### Jellyfin

- [ ] **S2-27 No `PlaybackInfo` negotiation, no transcode fallback.**
  [JellyfinAPI.swift:33](../ios/Sources/CleanPlayer/JellyfinAPI.swift:33).
  *Do:* `POST Items/{id}/PlaybackInfo` → `MediaSourceId`, `PlaySessionId`,
  `SupportsDirectPlay`; use `TranscodingUrl` when direct play is refused or the
  device is on cellular.
- [ ] **S2-28 Progress reports lack `PlaySessionId`/`MediaSourceId`/`CanSeek`.**
  [Jellyfin.swift:236](../ios/App/CleanPlayerApp/Jellyfin.swift:236).
  *Do:* send them; verify Continue Watching on the web client moves.
- [ ] **S2-29 Token expiry is invisible.** `fire()` ignores responses;
  `client.token == nil` → `load()` returns silently.
  *Do:* any 401 → clear token, mark server `needsSignIn`, shelf shows a
  "Sign in again" chip; player shows an error instead of a black screen.
- [ ] **S2-30 Token in `?api_key=` for the VLC stream.**
  *Do:* `VLCMedia.addOptions([":http-header": …])` or `:http-user-agent`
  + `Authorization` header option; keep query only where `<video>` must fetch.
- [ ] **S2-31 No pagination.** [Jellyfin.swift:195](../ios/App/CleanPlayerApp/Jellyfin.swift:195).
  *Do:* `StartIndex`/`Limit` = 100; `LazyVGrid` requests the next page at the
  last row.
- [ ] **S2-32 Raw decode errors shown to users.**
  [Jellyfin.swift:181](../ios/App/CleanPlayerApp/Jellyfin.swift:181).
  *Do:* map `DecodingError` → "That server answered in a way Cliqx doesn't
  understand"; 5xx → "Server error (\(code))".
- [ ] **S2-33 `deviceID` minted in two places.** *Do:* one `DeviceIdentity.id`.
- [ ] **S2-34 `isLocalHost` misses IPv6, `100.64/10`, `.home.arpa`, `.lan`,
  `.internal`.** *Do:* add them; tests for each literal.
- [ ] **S2-35 `latest()` swallows errors per library.**
  [ServerHomeView.swift:138](../ios/App/CleanPlayerApp/ServerHomeView.swift:138).
  *Do:* surface one "Some rows couldn't load" banner with retry.

### Local media

- [ ] **S2-36 Everything plays through VLC.** No AVPlayer path, no PiP, no
  hardware decode for MP4. [LocalMedia.swift:27](../ios/App/CleanPlayerApp/LocalMedia.swift:27).
  *Do:* `AVAsset.isPlayable` probe → `AVPlaybackSource` (already in the package)
  for MP4/MOV/M4V; VLC otherwise. PiP via `AVPictureInPictureController`.
- [ ] **S2-37 VLC keeps decoding video in the background.**
  *Do:* on `didEnterBackground`, `player.drawable = nil` (audio continues);
  restore on foreground.
- [ ] **S2-38 External subtitle import.** *Do:* `fileImporter` for
  `.srt/.vtt/.ass`; `player.addPlaybackSlave(_:type:enforce:)`.
- [ ] **S2-39 Photos temp copies are never deleted.**
  [LocalMedia.swift:223](../ios/App/CleanPlayerApp/LocalMedia.swift:223).
  *Do:* delete on player close; sweep `temporaryDirectory/cliqx-*` on launch.
- [ ] **S2-40 Seek before VLC knows length silently no-ops.**
  [ServerPlayer.swift:132](../ios/App/CleanPlayerApp/ServerPlayer.swift:132).
  *Do:* queue the seek and apply on first `mediaPlayerTimeChanged` with length.
- [ ] **S2-41 `UIScreen.main.bounds` for crop geometry.**
  [ServerPlayer.swift:180](../ios/App/CleanPlayerApp/ServerPlayer.swift:180).
  *Do:* pass the view's size in from `GeometryReader`.

### Controls

- [ ] **S2-42 Configurable skip interval** (5/10/15/30 s) in gesture settings;
  replace every hard-coded `10`.
- [ ] **S2-43 Orientation lock button** in the bar, next to rotate.
- [ ] **S2-44 Audio-track selection for web and server.** Agent: `audioTracks`
  API where WebKit exposes it; ServerEngine: `audioTrackIndexes/Names`.
- [ ] **S2-45 Gesture sensitivity + region width settings** (currently on/off only).
- [ ] **S2-46 Every unsupported control says why.** Menu rows that are hidden
  because the site doesn't expose the capability get a disabled row with
  "Not available on this site" instead of vanishing.

### Protection

- [ ] **S2-47 Rules can't update without an App Store release.**
  *Do (pick one):* host pre-converted `.json.deflate` + signed manifest and wire
  `FilterListUpdater` (change `expectedContentType`, verify manifest SHA-256 →
  `RuleData`, atomic swap through `RuleListController`); or embed a converter
  and accept its licence in NOTICE.
- [ ] **S2-48 Signed manifests + verification.** Ed25519 public key in the
  bundle; refuse unsigned payloads. Depends on S2-47.
- [ ] **S2-49 Streaming size enforcement.** `session.data(for:)` reads the whole
  body before the cap. [FilterListUpdater.swift:85](../ios/Sources/CleanPlayer/FilterListUpdater.swift:85).
  *Do:* `URLSessionDataDelegate` that cancels at `maxBytes`.
- [ ] **S2-50 Retry with backoff + jitter, mirrors, manual "Update now",
  last-updated time and failure state in Settings, stale banner is a button.**
  Depends on S2-47.
- [ ] **S2-51 PSL is a static file with no refresh tool.**
  *Do:* `tools/update-psl.sh` + a CI check that it's < 90 days old.
- [ ] **S2-52 Incremental scanning.** Every pass is `querySelectorAll('*')`.
  [agent.js:1321](../ios/App/CleanPlayerApp/Resources/agent.js:1321).
  *Do:* examine only `addedNodes` (and their subtrees) from the observer
  records; full walk only on `scroll`/`resize`, throttled to 1 Hz.
- [ ] **S2-53 Agent installed in frames that will never need it.**
  *Do:* after first scan, frames with no `<video>`/`<iframe>`/shadow roots
  disconnect their observer and scroll listener; re-arm on `childList` only.
- [ ] **S2-54 Fingerprint globals.** `__cpPopupGuard`, `__cpPopupsBlocked`,
  `#__cp_style`, `data-cp-*`. *Do:* random per-load prefix generated natively
  and injected into both scripts; attribute names derived from it.
- [ ] **S2-55 Auth/payment dialogs must never be hidden.** Add fixtures: a
  Stripe-style iframe, a `<dialog>` login, an OAuth popup; assert untouched.

### Boundary

- [ ] **S2-56 Strict bridge payload validation.** One `BridgeMessage` decoder
  (Codable enum) with ranges: time ≥ 0, duration ≥ 0, rate 0.25–4, volume 0–200,
  height 0–8192, arrays ≤ 50 entries, strings ≤ 120 chars. Reject otherwise.
- [ ] **S2-57 Per-frame blocked-count aggregation.** Keyed by
  `frameInfo.request.url` + `isMainFrame`; sum, don't overwrite.
- [ ] **S2-58 Threat model + `SECURITY.md`.** One page: assets, trust boundaries
  (page world / isolated world / native / server), what each may do, reporting address.

### Privacy

- [ ] **S2-59 HTTPS credential persistence is silent.** *Do:* the Sign In
  button reads "Sign in and remember" for pinned hosts; "Sign in" otherwise.
- [ ] **S2-60 Diagnostics export.** Settings → "Export diagnostics" → share sheet
  with the MetricKit JSON; rotate files (keep 30).
- [ ] **S2-61 Explicit data-protection class** on the progress/history stores
  (`.completeUntilFirstUserAuthentication`) and `isExcludedFromBackup` on thumbnails.
- [ ] **S2-62 Erase thumbnails independently.** Settings button.

---

## S3 — Fix to earn the 9

### Architecture

- [ ] **S3-01 Split `WebView.swift` Coordinator** into: `NavigationPolicy`,
  `AuthPresenter`, `BridgeRouter`, `EpisodeTransitionCoordinator` (state enum,
  in the package), `WatchSession` (resume + thumbnails), `StandbyManager`,
  `RendererRecovery`. Target: no file > 400 lines.
- [ ] **S3-02 Split `PlayerOverlay.swift`** into `TransportBar`, `GestureLayer`,
  `LevelHUDs`, `PlayerMenus`, `UpNextCard`.
- [ ] **S3-03 Modularize `agent.js`** (`theater.js`, `episodes.js`, `blocker.js`,
  `airplay.js`, `bridge.js`) with a tiny build step (esbuild) producing the
  single injected file; ESLint + `checkJs` on the sources.
- [ ] **S3-04 Typed, versioned bridge contract.** `bridge-schema.json` consumed
  by both a Swift `Codable` enum and a JS validator; `protocolVersion` in every
  message; native rejects mismatches.
- [ ] **S3-05 Split `PageState`** so `WebView` observes only `model.current`;
  player state lives in a separate observable the overlay owns.
- [ ] **S3-06 Swift 6 strict concurrency.** Package first, then app; remove all
  `MainActor.assumeIsolated` from KVO by hopping explicitly.
- [ ] **S3-07 Observable persistence failures.** Every `try? … write` returns a
  `Result` surfaced to a `StoreHealth` observable; Settings shows a warning.
- [ ] **S3-08 Storage schema versions + migrations** for recents, pinned,
  progress, servers, media-progress; a `Migrator` with tests.
- [ ] **S3-09 Explicit transition state machine** replacing `resumeTheaterFor`,
  `waitingForStandby`, `resumeOutgoingSourceChanged`, `standbyReady` … booleans.
- [ ] **S3-10 UserDefaults decode off the main actor** at launch.
- [ ] **S3-11 ADRs.** `docs/adr/0001-content-worlds.md` etc., one per decision
  currently buried in ARCHITECTURE.md.
- [ ] **S3-12 `CODEOWNERS`, `CONTRIBUTING.md`, PR template, branch protection
  requiring all four jobs; a second person who can build and release.**

### Tests

- [ ] **S3-13 Playwright on mobile WebKit.** Add a project using
  `devices['iPhone 15']`; run the theater and fullscreen suites there.
- [ ] **S3-14 Real captured fixtures.** `tests/fixtures/sites/<name>/` with
  saved DOM (via Playwright `page.content()`) from the corpus in Gate-01; one
  spec per site asserting extraction + episode discovery.
- [ ] **S3-15 App-target unit tests** (after S3-01): `BridgeRouter`,
  `NavigationPolicy`, `EpisodeTransitionCoordinator`, `report(_:)` messages.
- [ ] **S3-16 XCUITest theater flow** against an in-process `HTTPServer`
  serving fixtures: open → Watch clean → next → close.
- [ ] **S3-17 `retries: 1`** so `trace: 'on-first-retry'` works; replace the 11
  `waitForTimeout`s with `expect.poll` / `waitForFunction`.
- [ ] **S3-18 Verified-gain volume test** (`AnalyserNode` on the destination in
  the WebKit project).
- [ ] **S3-19 Gesture tests per region × orientation** (XCUITest with
  `XCUIDevice.shared.orientation`).
- [ ] **S3-20 Private-browsing lifecycle test**, auth + TLS tests (S2-20),
  accessibility UI tests (`XCUIElement.accessibilityLabel` for every control in
  theater), localization snapshot tests.
- [ ] **S3-21 Device-size matrix** in CI: SE, Pro, Pro Max, iPad; Split View.
- [ ] **S3-22 Coverage** (`-enableCodeCoverage YES`, Playwright coverage API),
  published per PR, ratchet threshold.
- [ ] **S3-23 Flake tracking** (rerun-and-compare job weekly), mutation testing
  (Stryker for the agent; Muter for Swift) on the security helpers.
- [ ] **S3-24 Soak test.** 30-minute Playwright loop cycling episodes; assert
  `performance.memory` and detached-frame count stay flat.

### Accessibility and localization

- [ ] **S3-25 VoiceOver labels + values on every theater control**, including
  seek bar (`accessibilityValue` = "12:03 of 45:00"), speed, quality.
- [ ] **S3-26 Button alternative for brightness** (a slider in the menu).
- [ ] **S3-27 Dynamic Type** via `@ScaledMetric` for bar heights and icon
  sizes; verify AX5 doesn't overlap; landscape too.
- [ ] **S3-28 Reduce Motion** disables curtain fade and countdown ring animation.
- [ ] **S3-29 Voice Control / Switch Control names** (`accessibilityIdentifier`
  + short labels), Accessibility Inspector audit with zero serious findings.
- [ ] **S3-30 String catalog.** Move every literal to `Localizable.xcstrings`;
  `String(localized:)`; plural rules for "n items", "n rules"; RTL run in
  the simulator; one reviewed second language.

### Performance and measurement

- [ ] **S3-31 Measure and record** (in `docs/PERF.md`, per device): cold launch,
  first compile, cached activation, peak compile RSS, heavy-page web RSS,
  1-hour playback battery (web / AVPlayer / VLC), thermal state.
- [ ] **S3-32 DOM-scan CI budget.** Playwright spec on a 10k-node fixture with a
  mutation storm; fail if agent long-tasks > 50 ms/s.
- [ ] **S3-33 Low Power Mode policy** (no standby; no boost context).
- [ ] **S3-34 Memory-warning test** (simulate via `simctl`), cellular/weak-network
  transitions, background/foreground, calls and alarms — scripted checklist in
  `docs/DEVICE-CHECKS.md`, results recorded per build.

### CI, release, operations

- [ ] **S3-35 Xcode selection** via `maxim-lobanov/setup-xcode` with a version
  range; fail loudly with the available list.
- [ ] **S3-36 `timeout-minutes` on every job; `paths-ignore` for docs; concurrency
  key `github.head_ref || github.ref` so push + PR run once.**
- [ ] **S3-37 Caches** for SPM (`SourcePackages`), `.build`, Cargo, Playwright browsers.
- [ ] **S3-38 Dependabot** (npm, cargo, swift, actions); `npm audit`,
  `cargo audit`, `osv-scanner` jobs.
- [ ] **S3-39 Track build time, binary size, test duration** (a small script
  appending to `docs/metrics.csv`, plotted in the README badge row).
- [ ] **S3-40 Release lane.** `VERSION` file → `MARKETING_VERSION`;
  `CURRENT_PROJECT_VERSION` = CI run number; `xcodebuild archive` + export +
  `altool`/`xcrun notarytool` upload to TestFlight on tag; changelog from
  conventional commits; archive + dSYM retained as artifacts; `-exportArchive`
  validation before upload.
- [ ] **S3-41 Rollback / emergency-release runbook** (`docs/RUNBOOK.md`).
- [ ] **S3-42 Protection kill switch** — a bundled "safe rules" list selectable
  from Settings if a generated list breaks the web; remote flag not required.
- [ ] **S3-43 Crash-free / hang-free rate** computed locally from MetricKit
  payloads and shown in Settings → Diagnostics.
- [ ] **S3-44 VLCKit provenance.** Record the xcframework checksum in the repo
  and verify it in CI; or move to VideoLAN's official distribution.
- [ ] **S3-45 Clean the working tree.** Remove `.devcouncil/` and
  `ios/App/DerivedData/` from the checkout; build outside `~/Desktop` as the
  README instructs.

---

## Gate — Not code. Do last, record results.

- [ ] **Gate-01 Corpus.** 10–20 real video sites in `docs/SITE-RESULTS.md`:
  site, mode fired, extraction OK, next/prev OK, false-positive removals,
  what escaped. Target ≥ 80 % extraction, ≤ 1 false positive per site.
- [ ] **Gate-02 Device pass** on iPhone 15 Pro + one older iPhone + iPad:
  next/prev, gestures, 200 % on speaker/headphones/Bluetooth/AirPlay,
  landscape, PiP, background, Split View, Dynamic Island edges.
- [ ] **Gate-03 TestFlight beta**, 25–50 people, ≥ 99.5 % crash-free from
  MetricKit exports.
- [ ] **Gate-04 Zero open S1.**
- [ ] **Gate-05 App Store privacy declaration and accessibility review** match
  the binary; support + privacy pages live; real marketing version set.
- [ ] **Gate-06 Every ROADMAP.md blocker closed.**

---

## Suggested order

1. S1-01 → S1-19 in a single week; each is < 1 day. Ship a TestFlight to yourself.
2. S2 audio (01–06), then episode/resume (07–13), then browser (14–20). These
   are what a first-hour user hits.
3. S2 Jellyfin (27–35) and local media (36–41) — the two features that are
   currently prototypes.
4. S2 protection (47–55) — the update pipeline is the biggest single item in
   the file; start it in parallel with (2) if you have a second pair of hands.
5. S3 architecture (01–12) *before* S3 tests (13–24): the tests need the seams.
6. S3 a11y/l10n, perf, CI in any order.
7. Gates.
