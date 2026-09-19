# Theater-First Player Architecture

Revision of "iOS Clean Web Video Player — Feasibility and Build Research" (2026-09-01).

Target: iOS 17+ / Swift 6 / SwiftUI. Dependencies: none.

---

## The one structural problem

The proposed architecture has a single output: pull a direct media URL out of the DOM and hand it to `AVPlayer`. Everything that fails that test lands in a branch labelled *"explain that it must play in the webpage."*

That branch is not an edge case. It is most of the web. Any site using Media Source Extensions — which is nearly every serious player, because that is how adaptive bitrate switching works in a browser — exposes only a `blob:` URL on the `<video>` element. The real segment URLs never touch the DOM. The research doc states this correctly and then builds the architecture as if it were a footnote.

So the plan's Phase 0 spends a week building the path that works least often, and defers the path that works always. You would demo it against a hand-picked HLS fixture, then watch it fall back to a plain `WKWebView` on the first real site you try.

The fix is not more extraction cleverness. There is no supported way to see WebKit's media traffic, and pursuing one leads directly into the private-API and circumvention territory the doc rightly rules out. The fix is to **stop treating "plays in the page" as failure** and make it the product.

---

## What changes

Rather than a validator that admits or rejects, a resolver that always returns *a* clean playback mode — the best one this particular video supports.

```text
CURRENT PLAN                          REVISED

   Page loads                            Page loads
        |                                     |
        v                                     v
 Extract media URL                    Discover videos
        |                              (all frames)
        v                                     |
   Scheme check                               v
    /        \                          Mode resolver
   v          v                        /      |      \
AVPlayer   Back to page               v       v       v
           (untouched,          A · AVPlayer  B · WebKit FS  C · Theater
            ad-ridden)             (best)     (near-native)  (universal)
                                      \       |       /
 direct     blob · MSE · DRM ·         \      |      /
 https      header-gated · iframe       v     v     v
 only                                Clean, ad-free playback
```

The revised path degrades experience quality, never availability. Mode C is reachable for every video the browser can play at all, so there is no branch that returns the user to an untouched page.

---

## The three modes

The resolver tries A, falls back to B, lands on C. Coverage runs the other way — C catches everything, A catches a slice. Coverage labels are qualitative, not measured.

### A · Native handoff — coverage: narrow

`AVURLAsset` → `AVPlayerItem` → `AVPlayerViewController`

Real `AVPlayer`. Background audio, system PiP, AirPlay offload, playback speed, native track selection, gesture scrubbing. Requires a direct HTTPS URL that survives outside the page context — plain progressive MP4, or an HLS manifest whose segments and keys are reachable with the cookies you can legally copy across.

### B · WebKit native fullscreen — coverage: most

`HTMLVideoElement.webkitEnterFullscreen()`

One JavaScript call hands the video to WebKit's own fullscreen player — Apple's controls, PiP button, AirPlay route picker, subtitle menu. The media never leaves the page, so **blob:, MSE, expiring tokens, Referer gates and even DRM all keep working**: the page's own fetch stack is still doing the loading. This is the single highest-leverage line of code in the project and the research doc does not mention it.

### C · Theater mode — coverage: universal

In-page ancestor neutralisation + overlay suppression.

Leave the video exactly where it is in the DOM and dismantle the page around it: hide every sibling up the ancestor chain, strip the transforms and `overflow` rules that trap it, kill overlays, and promote it to the full viewport. Inline playback, your own controls, no ads. Works for anything the browser can render.

---

Notice what this does to the product story. The thing that makes it a real app — not a `WKWebView` wrapper, which is the Guideline 4.2 trap — is now the page-hygiene engine, which runs on every site. The `AVPlayer` handoff becomes a bonus on top, not the load-bearing feature.

---

## Revised coverage

The original table's "cannot hand off" and "fragile" rows all resolve to a working mode here.

| Source type | Mode | Result |
|---|---|---|
| Public HTTPS HLS | A | Full native player. |
| Public compatible MP4 | A | Full native player, if codec is Apple-supported. |
| HLS behind ordinary cookies | A | Copy applicable cookies via `AVURLAssetHTTPCookiesKey`; cross-host segments may still need B. |
| Referer / User-Agent gated | A → B | Resource-loader delegate supplies the headers the browser would have sent. Falls to B if it still 403s. |
| Signed, expiring URL | B | Stays in-page, so the page re-signs on its own schedule. Do not attempt A. |
| `blob:` or MSE player | B | Native fullscreen UI over the page's own media pipeline. Near-parity with A. |
| Nested cross-origin iframe | B / C | Frame-targeted script evaluation; theater mode promotes the iframe itself. |
| FairPlay / DRM | B | Plays normally — WebKit holds the EME session. Nothing decrypted, intercepted, or bypassed. |
| Unsupported codec (AV1, VP9) | C | Whatever WebKit can render; A would fail outright. |
| Server-side stitched ads | — | Still unblockable in any mode. No architecture fixes this. |

---

## Five technical unlocks

Public API throughout. No private WebKit, no circumvention.

### 1 · Custom scheme + resource loader kills the "fragile" rows

The doc calls Referer and custom-header checks "fragile / unsupported" and warns against undocumented asset header options. It is right about the undocumented options, and wrong that there is no supported route. Rewrite the scheme, take over loading yourself, and you control every request byte.

```text
DIRECT — FAILS

  AVURLAsset  ──── GET · no Referer, no cookies ────X────>  Origin CDN
  https://cdn/x.m3u8                          403 · origin check


VIA RESOURCE LOADER — WORKS

  AVURLAsset  ──>  Resource loader  ──>  URLSession  ──>  Origin CDN
  clean://cdn/x.m3u8    delegate                              200
                          |                  |
                   rewrites segment    adds Referer, UA, cookies
                        URLs           follows redirects
```

The custom scheme is what forces `AVFoundation` to ask your delegate for bytes instead of fetching them itself. That single added hop is where headers, cookies and redirect handling become yours.

```swift
// The resource loader holds its delegate WEAKLY. Store it, or playback
// stalls the moment the delegate deallocates.
private let loader = ManifestLoader(pageOrigin: origin, userAgent: ua)

guard var comps = URLComponents(url: manifestURL, resolvingAgainstBaseURL: false)
else { return fallbackToModeB() }          // page-supplied URL: never force-unwrap
comps.scheme = "cleanplayer"
guard let staged = comps.url else { return fallbackToModeB() }

let asset = AVURLAsset(url: staged)
asset.resourceLoader.setDelegate(loader, queue: loader.queue)

// --- ManifestLoader -------------------------------------------------------

func resourceLoader(
  _ rl: AVAssetResourceLoader,
  shouldWaitForLoadingOfRequestedResource req: AVAssetResourceLoadingRequest
) -> Bool {
  guard var real = req.request.url.flatMap({
          URLComponents(url: $0, resolvingAgainstBaseURL: false)
        }),
        let origin = { real.scheme = "https"; return real.url }()
  else { return false }

  var r = URLRequest(url: origin)
  r.setValue(pageOrigin, forHTTPHeaderField: "Referer")
  r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
  // ... plus cookies scoped to this host, taken from WKHTTPCookieStore

  let task = session.dataTask(with: r) { [weak self] data, resp, err in
    self?.tasks[req] = nil
    // Without an explicit failure AVPlayer waits forever on a dead request.
    guard let data, let http = resp as? HTTPURLResponse, http.statusCode == 200
    else { req.finishLoading(with: err ?? URLError(.badServerResponse)); return }

    // AVFoundation refuses to proceed until content information is filled in.
    req.response = http
    req.contentInformationRequest?.contentType = http.mimeType
    req.contentInformationRequest?.contentLength = Int64(data.count)
    req.contentInformationRequest?.isByteRangeAccessSupported = false

    req.dataRequest?.respond(with: self?.rewrite(data) ?? data)
    req.finishLoading()
  }
  tasks[req] = task                          // seek/teardown must cancel these
  task.resume()
  return true
}

func resourceLoader(_ rl: AVAssetResourceLoader,
                    didCancel req: AVAssetResourceLoadingRequest) {
  tasks[req]?.cancel()
  tasks[req] = nil
}
```

> **Two real costs.** AirPlay *offload* breaks — the receiver cannot resolve `cleanplayer://`, so you get mirroring instead of true offload. And progressive MP4 needs you to implement byte-range responses by hand, which HLS does not. Ship this for HLS only, and only after Modes B and C are solid.

> **Where the legal line sits.** Sending the `Referer` the browser itself would have sent is replicating a normal request. Stripping, forging, or replaying an authentication token is not. Keep the delegate strictly in the first category and this stays clean under both §1201 and Guideline 5.2.

### 2 · `webkitEnterFullscreen()` is your near-native player

Mode B costs almost nothing and covers most of what Mode A cannot. The one constraint: iOS requires a user gesture, and `evaluateJavaScript` from native code does not carry one. So don't drive it from a SwiftUI button — inject the button into the page, where the tap is a genuine gesture.

```js
// Tested implementation: web/agent.js
function attachButton(video) {
  // A MutationObserver fires constantly. Without this guard you stack a new
  // button on the video every time the page mutates.
  if (!video || video.dataset.cpBtn || !video.parentElement) return;
  video.dataset.cpBtn = '1';

  const btn = document.createElement('button');
  btn.type = 'button';              // inside a <form>, the default is submit
  btn.className = '__cp_btn';
  btn.setAttribute('data-cp-keep', '');   // so theater mode does not hide it
  btn.textContent = 'Watch clean';
  btn.addEventListener('click', (e) => {
    e.preventDefault();             // page may wrap the video in an <a>
    e.stopPropagation();
    watchClean(video);
  });
  video.parentElement.appendChild(btn);
}

function watchClean(video) {
  // webkitEnterFullscreen is a silent no-op before metadata arrives.
  if (typeof video.webkitEnterFullscreen === 'function' &&
      video.readyState >= 1 /* HAVE_METADATA */) {
    try { video.webkitEnterFullscreen(); return 'B'; } catch (_) {}
  }
  return enterTheater(video) ? 'C' : 'none';
}
```

Configure the web view so inline playback and autoplay behave predictably before any of this matters:

```swift
let cfg = WKWebViewConfiguration()
cfg.allowsInlineMediaPlayback = true
cfg.mediaTypesRequiringUserActionForPlayback = []
cfg.allowsPictureInPictureMediaPlayback = true
```

### 3 · Content worlds and frame-targeted evaluation

The doc's security guidance stops at "don't concatenate untrusted data into JavaScript strings." That is necessary but it misses the actual mechanism: `WKContentWorld`. Inject into a named world and the page cannot see your functions, cannot monkey-patch your bridge, and cannot forge messages to your handler.

It also fixes the iframe problem the doc files under "best effort." Each frame reports itself; you then evaluate scripts *into that specific frame*:

```swift
let world = WKContentWorld.world(name: "CleanPlayer")

cfg.userContentController.addUserScript(
  WKUserScript(source: agentJS,
               injectionTime: .atDocumentStart,
               forMainFrameOnly: false,   // every frame, including cross-origin
               in: world)
)

// add(_:contentWorld:name:) is the plain handler. addScriptMessageHandler(...)
// is the *WithReply* overload and will not accept a WKScriptMessageHandler.
// The controller retains the handler strongly, so passing `self` here leaks
// the whole browser: self -> webView -> config -> controller -> self.
cfg.userContentController.add(WeakBridge(self), contentWorld: world, name: "cp")

// message.frameInfo identifies which frame the video lives in ...
func userContentController(_ ucc: WKUserContentController,
                           didReceive message: WKScriptMessage) {
  registry.record(message.body, frame: message.frameInfo)
}

// ... and you can act on exactly that frame later. A WKFrameInfo is only
// valid for the load it came from; a stale one throws rather than silently
// no-opping, so handle the error.
// Note the label: the second parameter is `in:` as well, not `contentWorld:`.
webView.evaluateJavaScript("window.__cp.enterTheater()",
                           in: targetFrame,
                           in: world) { result in
  if case .failure(let e) = result { self.fallbackToWholePage(e) }
}
```

### 4 · Neutralise ancestors — never reparent the video

The obvious theater-mode implementation is to move the `<video>` into a clean container. Do not. The HTML spec requires a media element removed from its document to pause, so reparenting stops playback and, on an MSE player, tears down the buffer. You lose the very sources Mode C exists to serve.

Instead leave the element untouched and walk up its ancestor chain, hiding siblings and stripping the properties that create containing blocks:

```js
// Tested implementation: web/agent.js
function enterTheater(video) {
  if (!video || !video.isConnected) return false;
  exitTheater();                    // only one stage at a time

  // Element stays exactly where it is — playback is never interrupted.
  let node = video;
  while (node.parentElement) {
    const parent = node.parentElement;
    for (const sib of parent.children) {
      // Skip our own controls, or theater hides the only way out.
      if (sib !== node && !sib.hasAttribute('data-cp-keep')) {
        sib.dataset.cpHidden = '1';
      }
    }
    // transform / filter / perspective / contain each create a containing
    // block, which would trap the stage's position:fixed inside them.
    parent.dataset.cpUntrap = '1';
    node = parent;
  }

  video.dataset.cpStage = '1';
  document.documentElement.dataset.cpTheater = '1';
  return true;
}

function exitTheater() {
  for (const el of document.querySelectorAll(
    '[data-cp-hidden],[data-cp-untrap],[data-cp-stage]'
  )) {
    delete el.dataset.cpHidden;
    delete el.dataset.cpUntrap;
    delete el.dataset.cpStage;
  }
  delete document.documentElement.dataset.cpTheater;
}
```

Pair it with a stylesheet injected once, so exiting is a single attribute removal rather than an unwind of inline styles:

```css
[data-cp-hidden]:not([data-cp-keep]) { display: none !important; }

[data-cp-untrap] { transform: none !important; filter: none !important;
                   contain: none !important; perspective: none !important;
                   overflow: visible !important; clip-path: none !important; }

[data-cp-stage]  { position: fixed !important; inset: 0 !important;
                   /* <video> is a replaced element: with width:auto an
                      absolutely-positioned box takes its INTRINSIC size and
                      ignores the right offset, so inset:0 alone does not
                      stretch it. Percentages resolve against the viewport and
                      avoid the iOS 100vh URL-bar overhang. */
                   width: 100% !important; height: 100% !important;
                   object-fit: contain !important;   /* or the video distorts */
                   max-width: none !important; max-height: none !important;
                   z-index: 2147483646 !important; background: #000 !important; }

[data-cp-theater] { overflow: hidden !important; }
```

### 5 · Page hygiene is the feature, so build it properly

On the sites this app exists for, the damage is not network ads — `WKContentRuleList` handles those declaratively. It is popunders, click-jacking overlays, and first-tap redirects. Four separate mechanisms:

- **Popups.** Return `nil` from `webView(_:createWebViewWith:for:windowFeatures:)` unless the navigation was `.linkActivated` and a real touch landed within the last few hundred milliseconds — track that with a `UIGestureRecognizer` on the web view that never cancels touches.
- **Redirect hijacks.** In `decidePolicyFor`, cancel main-frame navigations that are neither `.linkActivated` nor `.backForward` when no recent gesture exists.
- **Cosmetic overlays.** `WKContentRuleList` supports `css-display-none`, which handles known selectors for free. For the rest, a `MutationObserver` that removes any element whose `z-index` exceeds the video's and whose bounding box covers it.
- **Rule list cost.** Compilation is expensive and lists are large. Compile once, key by identifier, and always try `lookUpContentRuleList` before `compileContentRuleList`. Split large lists into several smaller ones rather than one giant blob.

```swift
// WKWebViewConfiguration is COPIED when the web view is initialised. Adding a
// rule list to the original `cfg` afterwards silently does nothing — always go
// through webView.configuration once the view exists.
let ucc = webView.configuration.userContentController

store.lookUpContentRuleList(forIdentifier: "cp-block-v3") { list, _ in
  if let list { ucc.add(list); return }
  store.compileContentRuleList(forIdentifier: "cp-block-v3",
                               encodedContentRuleList: json) { list, error in
    if let list { ucc.add(list) }
    else { log("rule list unavailable, browsing unfiltered: \(error as Any)") }
  }
}
```

---

## What to drop, defer, or reconsider

### Drop from the MVP

- **The candidate sheet as a primary surface.** A list of detected media URLs is a developer tool. Users want one button on the video. Keep the sheet behind a long-press for the multi-video case.
- **Tabs.** Real cost, no relation to the thesis. A single web view plus back/forward carries Phase 0–2 fine.
- **Every listed dependency.** The doc's own recommendation is "none in the initial vertical slice," and nothing here changes that. `M3U8Decoder` becomes relevant only if you build the resource-loader rewriter, and even then a regex over segment lines is smaller than the dependency.

### Reconsider

The doc asserts there is no supported network-visibility API. Since iOS 17 there is a partial one: `WKWebsiteDataStore.proxyConfiguration` routes web view traffic through a proxy you configure. It gives you *host-level* visibility and dynamic blocking beyond what static rule lists allow. It does **not** give you URLs or bodies for HTTPS — that would need a MITM root certificate, which you cannot install silently and should not attempt. Useful as a Phase 3 blocking upgrade; useless for media extraction. Verify the API surface against current documentation before planning around it.

### Keep exactly as written

The exclusion list — no downloads, no DRM circumvention, no paywall bypass, no private APIs, no bundled source catalog — is correct and this architecture does not strain it. If anything it strains it less, because Modes B and C never touch the media URL at all.

---

## Revised delivery order

The original plan front-loads the hardest, least-general work. Reverse it: each phase ships something demonstrably better than the last, on real sites, not fixtures.

### Phase 0 — Shell + theater mode (~3 days)

Single `WKWebView`, address bar, back/forward. Injected agent in a named content world, all frames. Video discovery, injected button, Mode C.

*Exit test:* pick five sites you actually use. Theater mode should work on all five. If it doesn't, the bug is in ancestor neutralisation and it's worth fixing before anything else.

### Phase 1 — Mode B + page hygiene (~1 week)

`webkitEnterFullscreen` path with Mode C fallback. Popup suppression, redirect gating, overlay killer, cached content rule lists with a per-site off switch.

*Exit test:* the same five sites, tapped carelessly, produce no popunders and no interstitial redirects.

### Phase 2 — Mode A, plain URLs only (~2 weeks)

Direct `AVURLAsset` handoff for unauthenticated HTTPS HLS and MP4. Cookie selection via `AVURLAssetHTTPCookiesKey`. Background audio, PiP, AirPlay, track selection. No resource loader yet.

*Exit test:* a failed handoff silently falls back to Mode B with no visible error and no interruption.

### Phase 3 — Resource loader + hardening (optional)

Header-gated HLS through the custom-scheme delegate. Private mode, history controls, accessibility pass, privacy disclosures. Proxy-based dynamic blocking if it proves worth the complexity.

---

## Why this is also the safer posture

Usually a technical decision trades against a legal one. Here they align, which is worth naming explicitly.

URL extraction is the part that looks like circumvention. You are reaching past a site's delivery mechanism to obtain the media stream directly — even when it's technically lawful, it is the behaviour that invites the Guideline 5.2 question and the §1201 argument. Modes B and C never do that. **Theater mode is Reader Mode for video:** the page loaded normally, the user authenticated normally, every access control the site applied is still applied. You restyled a document the user legitimately retrieved.

That reframing helps on three fronts at once. Guideline 4.2 — the page-hygiene engine is substantial native work, not a wrapper. Guideline 5.2 — nothing is extracted, decrypted, or re-hosted. And the App Review conversation gets simpler, because "a browser with a distraction-free video view" is a category reviewers already understand.

None of this changes the doc's bottom line, which was right: **go** for a neutral privacy browser, **no-go** for anything marketed as an extractor for specific unauthorised sites. The architecture above just makes the "go" version considerably more useful than the original plan would have.

---

## Verify before you build

Claims here that deserve a check against current documentation:

- **`webkitEnterFullscreen` gesture requirements.** Confirm current iOS behaviour, including whether a native-to-JS bridged call ever satisfies the gesture requirement. The whole Mode B design assumes it does not.
- **`WKWebsiteDataStore.proxyConfiguration`.** Availability, entitlement requirements, and whether App Review treats a bundled local proxy as ordinary. Do not commit to Phase 3 on recollection alone.
- **Content rule list ceilings.** Current per-list rule limit and compile time on the oldest device you intend to support. Chunk accordingly.
- **Reparenting behaviour.** Confirm on-device that ancestor neutralisation genuinely preserves MSE playback where reparenting breaks it. Test with a live adaptive stream, not a static MP4.
- **Cookie scope for HLS.** Whether segment and key hosts differ from the manifest host on your actual test sources. This determines how often Mode A survives past the manifest.

---

Estimates are engineering estimates. API details should be checked against current Apple documentation before implementation.

---

## Audit record (ponytail pass)

The code above began as illustrative sketches. This pass treated them as real
code and fixed what was actually broken. The JavaScript is now extracted to
`web/agent.js` and covered by `tests/theater.spec.ts` (5 tests, Chromium).

**Verified by test — these were real, and one was only found by running it:**

| Bug | Effect |
|---|---|
| `inset:0` cannot stretch a `<video>` | Replaced elements resolve `width:auto` to intrinsic size and drop the right offset. The stage stayed 300px wide. Caught by the test, not by reading. |
| No idempotence guard on button attach | `MutationObserver` stacked a new button on every page mutation. |
| `<button>` defaults to `type="submit"` | Inside a `<form>`, tapping "Watch clean" submitted the page. |
| Injected button was hidden by theater mode | It is a sibling of the video, so the first loop iteration hid the only exit control. |
| No `exitTheater` | Attributes were set and never reversed; theater mode was one-way. |
| Missing `object-fit: contain` | Video stretched to viewport aspect ratio. |
| `100vw` / `100vh` | Replaced with percentages of the fixed containing block; verify on device. |

**Verified by test — Swift, `ios/` package, 13 XCTest cases on the iOS 17 simulator:**

| Bug | Effect |
|---|---|
| `AVAssetResourceLoader` holds its delegate weakly | Delegate deallocates immediately and playback stalls with no error. `testResourceLoaderDoesNotRetainItsDelegate` demonstrates the weak hold; `testPlayerSessionRetainsTheLoader` proves the fix. |
| Force-unwrapped `URLComponents` / `.url` | Crash on malformed page-supplied URLs. `MediaURL` now rejects `blob:`, `data:`, `file:`, `javascript:` and plain `http:` at the trust boundary. |
| No failure path in the loader callback | `AVPlayer` waited forever. Now finishes with an error on transport failure and on any non-2xx. |
| `contentInformationRequest` never populated | AVFoundation will not proceed without content type and length. Test asserts the order `info → respond → finish`. |
| No `didCancel` handler | Requests leaked on every seek and teardown. |
| `addScriptMessageHandler(_:contentWorld:name:)` | The *WithReply* overload; does not accept a plain handler. Corrected to `add(_:contentWorld:name:)` — proven by the package compiling. |
| `userContentController.add(self, ...)` retains strongly | Retain cycle leaked the browser. `WeakScriptBridge` breaks it. |

**One claim from the previous pass was wrong.** I asserted that adding a rule
list to the original `WKWebViewConfiguration` after the web view exists is a
silent no-op because the configuration is copied at init. The configuration *is*
copied, but the copy is **shallow** — `webView.configuration.userContentController`
is the *same object* as `cfg.userContentController`, so late additions do reach
the live web view. `testConfigurationCopyStillSharesTheUserContentController`
asserts both halves. `BrowserSetup` still routes through `webView.configuration`,
but for clarity, not correctness.

Run the checks:

```bash
npx playwright test                 # 5 tests, DOM agent
```

```bash
cd ios && xcodebuild test -scheme CleanPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Sources live in `ios/Sources/CleanPlayer/`; open `ios/Package.swift` in Xcode.

---

## The app

`ios/App/CleanPlayerApp.xcodeproj` — a SwiftUI shell that consumes the
`CleanPlayer` package as a local dependency. Verified running on the iPhone 17
Pro simulator.

- **Home** (`HomeView`) — search/address field, shortcut tiles, and recents
  persisted to `UserDefaults`. Shortcuts are neutral, openly licensed sources
  for exercising the player; no third-party catalogue, artwork, or marks are
  bundled, and tile monograms are drawn from the title rather than any logo.
- **Browser** (`BrowserView`) — the origin stays visible with a lock indicator,
  since that is the user's only defence against a page claiming to be somewhere
  else. Back / forward / reload / home.
- **Popup control** — `createWebViewWith` returns nil, so popunders never open a
  window. A genuine `.linkActivated` tap still navigates, in the current view.
- **Scheme gating** — `decidePolicyFor` allows only http, https and about, so no
  unexpected scheme is ever handed to another app.
- **Agent injection** — `agent.js` ships as a bundle resource and is injected at
  documentStart into the `CleanPlayer` content world, in every frame.

Build and run:

```bash
cd ios/App && xcodebuild build -project CleanPlayerApp.xcodeproj \
  -scheme CleanPlayerApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Not built yet: tabs and private mode (deliberately out of scope), the Mode A
handoff UI, and content rule lists — `BrowserSetup.applyRuleList` exists and is
tested, but no filter list is wired to it.

---

## Player controls and the frame-targeting fix

### The bug

`evaluateJavaScript(in: nil)` addresses the **main frame**. A video is usually
staged inside the site's player **iframe**, so every native call reached a
different `window.__cp` than the one holding the staged video — and returned
success having done nothing. That is why "Exit theater" appeared to work and
changed nothing.

There was no content-world bug. Instrumented logs confirmed the world resolves
(`typeof __cp in world -> object`), is correctly isolated from the page world
(`in page -> undefined`), and that the script-message bridge delivers. An
earlier report to the contrary was wrong.

### The fix

The two halves of the feature need **opposite** frames, which is the whole point:

- **Theater actions** (`exitTheater`, `showAirPlay`) go to the frame that staged
  the video, captured from `WKScriptMessage.frameInfo` on the `theater` message
  and held in `theaterFrame`.
- **Episode discovery** goes to the **main frame**, because next/previous links
  live in the top-level page, not inside the player iframe.
- **Episode navigation** is done natively with `webView.load()`, not by
  scripting a frame. The URL came from page content, so it is re-validated
  against the current host before use, and no user gesture is needed.
- `theaterFrame` is cleared on every provisional navigation; the handle dies
  with its document.

### Controls are native, not injected

Nothing the page draws appears above a full-viewport staged `<video>` on iOS
WebKit — verified last pass with a plain `div` at inline `position:fixed;
z-index:2147483647` attached at the document root, which was equally invisible.
So the bar was removed from the agent entirely and rebuilt as SwiftUI over the
web view: Close, Previous, Next, AirPlay. Buttons appear only when the
capability exists, so there are no dead controls.

### Verified by test — 14 Playwright, 13 XCTest

Including the exact bridge payloads the native chrome depends on (`theater`,
`theaterEnded`, `airplay`), episode discovery precedence (`rel` over text),
same-origin refusal, self-link refusal, orphaned-button sweeping, and recovery
when a player swaps its `<video>` out.

### AirPlay and MSE — measured on device

Answered on an iPhone 15 Pro against a live receiver, which the Simulator
cannot do. The gesture worry was unfounded: `webkitShowPlaybackTargetPicker()`
returns true and opens the picker from a native `evaluateJavaScript` call, with
no user gesture. WebKit exposes the whole API in a `WKWebView`
(`picker=function`, `x-webkit-airplay=allow`).

What does not work is offload, and the reason is the stream, not the call.
`webkitplaybacktargetavailabilitychanged` never fires and
`webkitcurrentplaybacktargetiswirelesschanged` never fires, because the site
plays through Media Source Extensions. **MSE and AirPlay are incompatible by
construction**: a receiver needs a URL it can fetch, and a `blob:` handle to a
`SourceBuffer` means nothing outside this process. The audio session still
routes, which is why the symptom is sound on the TV and picture on the phone.

WebKit's own answer is a second `<source>` carrying an AirPlay-capable URL,
which it switches to when a route is picked — see
[How to use Media Source Extensions with AirPlay][mse-airplay]. That guidance
addresses the page author, who knows the URL. A browser has to discover it, so
the agent reads it out of resource timing rather than patching the page's fetch
stack, and appends it as a second `<source>`.

This works only where the page put the blob in a `<source>` child. A `src`
attribute makes WebKit ignore `<source>` children outright, and moving the blob
into a child requires `load()`, which tears down the page's MediaSource session
mid-playback — so that case is refused rather than fixed, and reported as
`src-attribute`. Sites in that shape need Mode A, a real `AVPlayer` holding a
direct URL, which is the only path to true offload for them.

[mse-airplay]: https://webkit.org/blog/15036/how-to-use-media-source-extensions-with-airplay/

### Not verified on device

The native control bar has **not** been seen working on a real page yet.

---

## Interstitial and ad blocking

Reported symptom: a full-screen "Checking your browser before visiting the
site — Activate VPN" panel, assumed to be a popup ad.

**It is not a popup.** `createWebViewWith` blocks `window.open`, which these
never use. They are ordinary DOM elements inside the page, so popup blocking
could never have touched them. That particular panel is also not a security
check — it is a fake-verification interstitial used to drive affiliate VPN
installs, and the pattern is common on popunder ad networks.

Two separate gaps, now closed:

### 1. No blocking was running at all

`BrowserSetup.applyRuleList` was written and unit-tested but **never called
anywhere**. Nothing was ever compiled or attached. It is now applied at web view
creation with `Resources/blocklist.json` — 32 self-authored rules covering
well-known third-party ad, tracker and popunder networks.

Self-authored deliberately: EasyList, AdGuard and similar carry licence and
redistribution terms that would attach to the app. A short hand-written list
avoids that entirely, at the cost of coverage.

### 2. Overlays that arrive as page DOM

Network rules cannot stop an interstitial the site itself renders. The agent now
blocks by **shape** rather than by selector: a positioned element, `z-index`
≥ 1000, covering at least 60% × 50% of the viewport, that is not ours and does
not contain a `<video>`. Selector lists for named sites go stale on every
redeploy; the shape does not.

Blocked elements are hidden (`data-cp-blocked`), never removed — removal breaks
page scripts far more often. Scrolling is restored, since interstitials usually
lock it behind themselves.

### The escape hatch matters

Blocking by shape *will* sometimes catch a real dialog — a cookie consent, a
login prompt. The toolbar shield toggles it per session and badges how many
overlays were hidden. Toggling reaches every frame that reported a block, not
just the main frame, because interstitials are frequently inside an ad iframe.

### Tested — 6 of the checks assert what it must NOT hide

A small cookie notice survives, an element wrapping the video survives, and the
app's own controls survive. Those are the failure modes that make a blocker
worse than useless.

### Limits

Blocking is cat-and-mouse and this list is short. Server-side stitched ads remain
impossible to block in any mode, as noted in the coverage table. Not yet
verified on device.

---

## Popup blocking, and what Brave is actually good for here

### Licence first

The iOS code is not in `brave/brave-browser` (that repo is builds and issues) —
it is in `brave-core` under `ios/brave-ios`, and it is **MPL-2.0**. That is
file-level copyleft: copy a file in and that file stays MPL and must be
disclosed. `adblock-rust` is MPL-2.0 too, and `brave/adblock-lists` carries its
own terms. So nothing here is copied. The approach was studied and the code
written from scratch.

Worth knowing: on iOS every browser is a `WKWebView`, so Brave cannot use its
Rust engine for network blocking the way desktop Brave does. It compiles filter
lists to `WKContentRuleList` — the same public API already used here. There is
no privileged technique to borrow.

### The transferable idea: gate `window.open` on real link activation

`WKUIDelegate.createWebViewWith` only sees popups that reach native. The
stronger move is to replace `window.open` in the page and refuse calls that did
not come from the user activating a link.

"A click happened recently" is not enough — a popunder fires from a handler
bound to the whole document, so the timing looks identical to a real click. The
signal that separates them is whether the current event's target is inside an
`a[href]`. `Resources/popupguard.js` does that, and also refuses `.click()` on a
detached `target="_blank"` anchor, which is the other common popunder shape.

Blocked calls return a **stub window**, not `null`. Returning null makes page
scripts throw, which breaks the page more visibly than the ad did.

**Honest limitation:** this must run in the page's own content world, because an
isolated world cannot replace a global the page calls. That means the page can
see it and undo it. There is no way around that on `WKWebView`.

### Also fixed: the entry button had disappeared entirely

`attachButton` marked the *video* with a boolean and never checked whether the
button still existed. Once anything removed a button — the orphan sweep, or the
page re-rendering — that video stayed marked as done and never got another one.
Diagnostic on a real page read `videos: 199, buttons: 0`.

It now tracks the button element itself and re-attaches when it is missing.
The 199 also prompted a size gate: pages embed dozens of thumbnail `<video>`
elements, and only something at least 200×100 gets a control.

---

## Overlay heuristic, second attempt

The "install a VPN to continue watching" dialog walked straight through the
first version. Both of its gates were the wrong signal:

- `z-index >= 1000` — meaningless inside a player's own stacking context, where
  `z-index: 10` is normal.
- near-full-screen coverage — an interstitial is a *centred card*, much smaller
  than the viewport.

### Ask whether something is on top of the video

The user-visible complaint is "something is covering what I came to watch", so
that is what the rule now tests: one `document.elementFromPoint` hit test at the
video's centre per pass. If the candidate is that element or contains it, and it
covers at least 30% of the video's box, it is an obstruction. No z-index
guesswork.

That test also spares the player's own control bar for free — a bottom bar
overlaps the video but never its centre.

Two further guards keep false positives down: an element with no background, no
image and no content is left alone (that is how players catch taps, and hiding
it breaks play/pause), and anything containing a `<video>` is never touched.

### The bigger bug found while testing this

`ensureStyle()` was only ever called from `attachButton`. On any page without a
playable video the stylesheet was **never injected**, so `data-cp-blocked` was an
inert attribute and blocking did nothing at all — precisely on the full-page
"verify your browser" gates it was written for. This also explains the `styled:
0` seen in the on-device diagnostic. The stylesheet is now injected up front and
again at the top of `blockOverlays`.

### Peeling layers

An interstitial is a card on a dimmed backdrop, and only whichever is topmost is
caught in a pass. Blocking now peels up to three layers, so the dimmer does not
survive the card.

### Tested — 5 of the 9 assert what it must NOT hide

Player controls, a cookie notice that is not over the video, the container
holding the video, an invisible gesture layer, and the app's own controls.
Those are the failure modes that make a blocker worse than the ads.

---

## Overlay heuristic, third attempt: the page with no video of its own

Reported from the phone, mid-episode: a card reading *"Is your browser Firefox?
/ Yes / or choose your browser to continue / Cancel"*, sitting over the episode
while it played. A browser-choice smartlink — the same affiliate family as the
fake VPN dialog, wearing a different costume.

The hit test above never ran on it. It aims at a `<video>`, and on the sites
this app exists for the main frame has no `<video>` at all: the player is a
cross-origin iframe. That document took the *other* branch, which had none of
the second attempt's machinery and still guessed from size — plus one guard
that turned out to be the whole bug.

### The frame guard was immunising the ads

A responsive embed is `position: absolute` at 100% of its wrapper with a black
background, which is exactly the shape the size gate read as a full-page gate.
Rather than hide the player, the branch spared anything that was, or *held*, a
frame:

```js
if (el.tagName === 'IFRAME' || el.querySelector('iframe')) return false;
```

`querySelector` searches the whole subtree, and these dialogs are served in a
frame of their own. So the ad's iframe, sitting inside the dimmer, handed the
dimmer a free pass — and the card went with it. The guard written to protect
players was protecting every framed ad on the page.

### Which frame is the player cannot be answered by size

The obvious repair — spare the *biggest* frame instead of any frame — fails on a
phone, where a browser-choice card is larger than a 16:9 embed below it.
Largest-wins returns the ad, spares it, and reads the real player as the thing
on top of it.

What separates them is not size but behaviour: **a player embed scrolls with the
page; an interstitial is pinned to the viewport.** No site pins its own player
there. `playerFrame()` is therefore the largest frame with no `position: fixed`
ancestor, and only that frame and its holders are spared.

### The player frame then stands in for the video

With the player identified, the branch asks the second attempt's question after
all — is this painted over the player? — instead of guessing from size. Two
shapes count, and both then face one `elementFromPoint` hit test at the
candidate's own centre:

- it covers at least 30% of the player's box; or
- it is `position: fixed` and covers at least half the viewport's width and a
  quarter of its height.

The second is what the reported card needed. Centred on the *viewport* while a
16:9 embed sits lower down the page, it covered none of the player's middle and
was nowhere near the full-page coverage the old gate demanded. Site chrome is a
band across one edge — a header, a footer, a cookie bar — and is far too short
for either test.

The hit test is per candidate here, where the video branch does one per pass.
The coverage gates run first and leave a handful of candidates at most.

### Scoping the undo

`releaseFramedBlocks` exists because a container hidden as a gate may turn out
to be a player placeholder once the frame lands in it. It, too, released on
*any* frame, so an ad dialog could free itself with its own iframe. Blocks now
record which guess they were — `data-cp-blocked="gate"` before a player frame
existed, `"overlay"` after — and only gates are released, and only for a frame
that scrolls with the page.

It cannot reuse `playerFrame()`: the container is `display: none`, so the frame
inside it measures 0×0 and fails the size floor, which would leave the player
hidden permanently — the exact deadlock the function exists to break.

### Tested — 3 of the 5 new specs assert what it must NOT hide

The player frame under a pinned card, a player frame smaller than the ad frame
covering it, and a cookie bar on a page with a framed player.

---

## QA sweep: the shapes the geometry does not see

Fixing the browser-choice dialog answered *where* an interstitial sits. It said
nothing about the ways one can avoid being looked at in the first place. A
deliberate pass at that found eleven, of which one was already covered.

### Never examined

- **Outside `<body>`.** The scan was `body *`. Nothing stops a script appending
  to `documentElement`, and an ad that did was not a candidate at all.
- **Inside a shadow root.** `querySelectorAll` does not cross a shadow
  boundary, a `MutationObserver` does not either, and `elementFromPoint` stops
  at the host. A dialog rendered by a custom element was invisible three times
  over. The scan now descends, hit tests descend with it, containment is
  checked across boundaries, and each shadow root found is put under the same
  observer.
- **`position: sticky`.** Fixed once it has stuck, and a negative margin parks
  one over the player from the start. The position gate took `fixed` and
  `absolute` only.
- **`<object>` and `<embed>`.** `hasVisibleSurface` treats a frame as a surface
  whatever it appears to contain, because a transparent ad frame is still an ad
  frame. Only `<iframe>` was on the list.

### Never woken

The observer watched `childList` alone, so anything arriving by another route
landed in silence:

- a `<dialog>` interstitial, which opens by attribute;
- an ad already in the markup, shown by flipping its inline display — the
  ordinary way it is done;
- an overlay parked off screen, whose centre cannot be hit-tested until it
  slides in;
- a scroll or a rotation, which moves everything without mutating anything.

`open` and `style` are now watched, along with `data-cp-blocked` so a page that
strips the mark is answered, and scroll, resize and orientation wake a pass.
Those all run in a slow lane throttled to 250ms: a pass walks the DOM and reads
a computed style per element, and one per frame through a scroll is how a page
comes to stutter.

### Marked, and still on screen

Two ways the mark landed and changed nothing. A document stylesheet does not
reach inside a shadow root, and an inline `display: … !important` on the ad
outranks any author rule. So after marking, the blocker asks what the browser
actually computed, and only where the mark failed to land overrules the
element's own style — parking the value it displaced so the shield can give it
back.

An ad that re-sets its display on a timer needed one more thing: a marked
element is not re-examined, so its next write was the last one. That is
answered straight from the observer rather than on the next pass — a quarter
second of ad, several times a second, is the ad winning.

### Which frame is the player, again

An interstitial need not be pinned; some are absolutely positioned over a
scroll-locked page, and one bigger than the embed would be crowned the player
and spared. A responsive embed is absolute *inside a wrapper that reserves its
box* — the padding-bottom trick, and the whole technique. An overlay is
positioned against the page, or hung off a zero-height anchor. The wrapper now
has to cover the frame it holds.

### Reaching further cost something, and it is paid for

Scanning shadow trees meant the "never hide a login" guard had to reach into
them too, or a sign-in rendered by a web component would read as a large
positioned box with nothing to mark it as one. Password fields are collected
once per pass, deep, and containment is checked across shadow boundaries —
cheaper per candidate than the `querySelector` it replaces, and free on the
pages that have no password field at all.

### Tested — 6 of the 19 new specs assert what it must NOT hide

A sticky site header, a sticky episode sidebar, a pinned mini-player holding
the real frame, a sign-in inside a shadow root, the shield handing back a
display the blocker had to overrule, and the whole thing coming to rest instead
of rescanning forever. Pass cost was measured before and after on a
4,000-element page: 12.4ms against 11.8ms, so reaching further is not what
costs — the per-element computed style always did, and the note above
`blockOverlays` still stands.

---

## Filter-list infrastructure (partial)

Work against the "Stronger Ad Blocking" checklist. **Not finished** — that list
is multi-week. What exists, what is blocked, and what is untouched:

### The checklist's premise was wrong

Its "Current App Status" claims several protections already exist. Audited
against the source, these do **not**:

| Claimed | Reality |
|---|---|
| Per-site protection controls | **Now present.** Persisted exceptions with host canonicalisation, applied in `decidePolicyFor`. |
| Private browsing | **Now present.** Non-persistent `WKWebsiteDataStore`, toggled in Settings. |
| Fake VPN-dialog detection | Absent as such. There is a *generic* geometric overlay blocker, not VPN-specific logic. |
| Cross-origin ad iframe removal | Absent. |
| Touch interception for deceptive buttons | Absent. |

Real: content rules, popup/new-window cancellation, scheme rejection, overlay
removal, global toggle. Section 8 ("preserve existing protections") therefore
lists several things there is nothing to preserve.

### Done, with tests (12 new XCTest cases)

- **`FilterSource`** — identity, URL, repository, licence, attribution, rule
  group, expected content type, size cap, enabled state. **`FilterState`** —
  last update, checksum, `ETag`, `Last-Modified`, list version.
- **`FilterListUpdater`** — HTTPS only, ~weekly cadence, conditional requests,
  30s timeout, and refusal of oversized (declared *and* actual), empty,
  wrong-typed, or non-filter-list responses. SHA-256 checksums. Atomic
  write via temp file + `replaceItemAt`, so an interrupted update leaves the
  previous list intact and no `.partial` files behind. `async`, so it never
  blocks startup.
- **`ProtectionLevel`** (off / standard) and **`RuleGroup`** with the
  group-per-level mapping. A `strict` level was removed: no bundled list had
  the `popups` or `annoyances` groups it selected, so it was identical to
  `standard` while the UI promised extra blocking.

### The converter has been run

`tools/convert-filters.sh` has been executed and `rules/manifest.json` records
the result: EasyList at 77,360 rules and EasyPrivacy at 55,903, both converted
by `cargo 1.98.0`. The earlier note that it had "never been compiled or
executed" was already stale when written and is corrected here.

### Multi-list compilation and activation — done

`RuleCatalog` + `RuleListController`:

- The catalog is built from `rules/manifest.json` (700 bytes), so the compiled
  identifier for each list is known without reading the 14MB payload. The
  identifier embeds the content hash, so regenerated rules cannot silently
  reuse a stale compile.
- Activation compiles cheapest-first. The 36 hand-written rules are in force in
  milliseconds; EasyList takes about 10 seconds on a cold first launch and is
  then cached, so later launches cost a lookup.
- Nothing is detached until its replacement is in hand. A failed compile leaves
  the working lists attached and reports `.degraded`, rather than leaving the
  user unprotected.
- Compiles from superseded rule generations are purged from the store.
- Rules ship raw-DEFLATE compressed: 14.2MB becomes 1.27MB, and the app bundle
  went from 15MB to 2.9MB. Inflation happens only on a cache miss.

`ProtectionLevel`, `RuleGroup` and per-site exceptions are wired into the app
and exposed in Settings.

### What blocking actually covers

`tools/check-rules.py` verifies, without WebKit, that 18 real ad and tracker
URLs are blocked when browsing an ordinary site — honouring `if-domain`,
`unless-domain`, `resource-type` and `load-type`, because an exception scoped
to another site must not count as unblocking this one. CI runs it.

Known limits, none of them fixable by adding rules:

- **First-party ads.** EasyList's third-party rules cannot catch an ad served
  from the same origin as the video. Cosmetic rules hide some of it.
- **The first ~10 seconds after install**, while EasyList compiles, only the
  36 hand-written rules are in force.
- **A page already open when compilation finishes** keeps the rules it loaded
  with until it is reloaded.
- **The shield badge counts overlays and popups only.** `WKContentRuleList`
  reports nothing when it blocks a request, so network blocks are uncountable.
  The label says so rather than implying a total.
- **The overlay blocker must never touch a `<video>`.** A staged video matches
  every test `looksLikeInterstitial` applies: theater gives it
  `position: fixed`, full-screen size and an opaque background, and it is
  topmost at its own centre by definition. So the next mutation pass hid the
  video theater exists to show — decoded, playing, `display: none`. The guards
  there covered *containers* of a video, never the element itself.

  This corrects an earlier note that blamed the black frame on the stream.
  Apple's HLS example rendered because it went to WebKit *native fullscreen*,
  never exercising the inline path, so it proved nothing about theater.
  Instrumenting the device found it in one screenshot; two rounds of reasoning
  from symptoms had not.

- **`evaluateJavaScript(in: nil)` reaches only the main frame.** On the sites
  this app is for, the video is in a cross-origin iframe and the main frame has
  no `<video>` at all — so resuming theater after an episode change was asking
  the wrong document and silently timing out. Each frame now announces itself
  once, and native addresses the `WKFrameInfo` that comes with the message.
- **`ignore-previous-rules` does not cross compiled lists.** WebKit evaluates
  each list independently, so a compatibility exception only cancels rules in
  the list holding it. Brave's unbreak rules are therefore parsed into the same
  `FilterSet` as the rules they undo, not shipped as a list of their own —
  asserted by `testWhetherIgnorePreviousRulesReachesAcrossLists`. It is also why
  a per-site exception detaches every list rather than layering an allow rule.
- **The 150,000-rule cap is per compiled list, not total.** Four lists at
  183,950 are fine; the largest is 77,963. Merging them into one JSON is the
  only way to hit the ceiling, and a test guards against it.
- **Ad frames away from the video** that no list knows about stay visible.
  Blocking unknown cross-origin frames wholesale would break embedded players,
  which is the product. Frames *over* the video are caught geometrically,
  including invisible clickjacking layers.

### A rule that never compiled

`blocklist.json`'s last rule combined an alternation group with a preceding
optional group, which WebKit's content-blocker regex engine rejects. Because
compilation is all-or-nothing per list, **the entire hand-written list failed —
and it was the only list the app applied.** The old code logged the error and
carried on, so the app ran with no content blocking at all and nothing said so.
Expanded into one rule per domain (32 → 36 rules) and covered by a test.

### Licensing — settled

EasyList is GPL-3.0 **or** CC BY-SA 3.0. The project takes CC BY-SA 3.0 and
accepts share-alike on the generated rule data only, with attribution reachable
at **Settings → About → Attribution and licences**. See `NOTICE.md`.

### Still open: runtime list refresh

`FilterListUpdater` is written, tested and **deliberately not wired to the
active rules**, because wiring it as-is would not work:

- It fetches ABP-syntax `.txt` lists.
- The app can only consume pre-converted WebKit content-blocker JSON.
- The converter is `adblock-rust`, a **build-time** tool that is not linked
  into the app.

So a downloaded list cannot become an active rule list on device. Two ways
forward, both decisions rather than code:

1. **Host converted JSON.** Point the sources at pre-converted `.json` and
   adapt the updater's shape check. Needs somewhere to host it.
2. **Embed the converter.** Links `adblock-rust` (MPL-2.0) into the app, which
   changes the licensing position in `NOTICE.md`.

Until one is chosen, Settings shows each list's version and how long ago the
rules were generated, and warns outright once they pass 30 days. Protection
that quietly decays behind an "Active" label is the failure being prevented.

