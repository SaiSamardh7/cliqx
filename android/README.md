# Cliqx for Android — walking skeleton

An Android port of the browser in [`../ios`](../ios), at the stage where the
risky parts are proven and nothing else is built. It is not a usable browser
yet: there is no chrome, no settings, no player controls, no tabs.

The point of this stage was to answer three questions that would have made the
whole port pointless if any of them came back wrong.

| Question | Answer |
|---|---|
| Does the shared page agent run on Android's engine? | **Yes, with one wrapper.** See [the injection problem](#the-injection-problem). |
| Can requests be blocked without `WKContentRuleList`? | **Yes, per request.** See [blocking](#blocking). |
| Can a resolved stream reach a native player? | **Yes, ExoPlayer.** See [playback](#playback). |

## What is shared, and what is not

`agent.js` is the product — 98KB of theater detection, overlay stripping and
episode discovery — and it is **not forked here**. One copy lives in the iOS
resource folder and Gradle copies it at build time (`syncSharedAgent` in
[`app/build.gradle.kts`](app/build.gradle.kts)), so a fix to the overlay
heuristics lands on both platforms at once. The build fails rather than shipping
an APK that injects nothing.

The agent posts to `window.webkit.messageHandlers.cp` because it was written for
WKWebView. Rather than change that call site and fork the file,
[`bridge-shim.js`](app/src/main/assets/bridge-shim.js) supplies that shape on
top of Android's `addJavascriptInterface`. `popupguard.js` is shared unchanged —
it guards its webkit-prefixed calls with `typeof` checks already.

```
agent.js, popupguard.js   ← shared verbatim with iOS, copied at build time
blocklist.json            ← shared verbatim
bridge-shim.js            ← Android only: supplies the WebKit message shape
agent-bootstrap.js        ← Android only: see below
BridgeMessage.kt          ← port of BridgeMessage.swift, same validation limits
```

## The injection problem

The one thing that did not just work, and the most useful finding from this
stage.

`agent.js` finishes its setup with `watchRoot(document.documentElement)`
(line 2255) **before** it assigns `window.__cp` (line 2275). Injected at true
document start in Chromium, `document.documentElement` is `null` — the parser
has not created `<html>` yet — so `WeakSet.add(null)` throws, the agent's IIFE
unwinds, and `window.__cp` is never assigned. Every feature is then silently
absent, which is indistinguishable from the app simply not working.

WebKit creates the root element *before* running `atDocumentStart` scripts, so
**iOS never hits this and needs no change.** It is a genuine engine difference,
not a bug the iOS app has been getting away with.

[`agent-bootstrap.js`](app/src/main/assets/agent-bootstrap.js) wraps the agent
and starts it on the parser's first tick instead. Deferring costs nothing —
everything the agent does needs a DOM to look at. `popupguard.js` is *not*
deferred: it replaces `window.open` and `HTMLElement.prototype.click`, needs no
DOM, and must beat the page's own scripts.

> [!NOTE]
> **The better fix is one line in `agent.js`** — make `watchRoot` ignore a root
> that is not an object, the way the file already tolerates `crypto.randomUUID`
> being undefined on a LAN http origin. That would delete this wrapper and make
> iOS more robust against the same class of failure. It is deliberately not
> applied here, because `agent.js` ships in an iOS release that is mid-flight
> and that is a call for whoever owns that release.

Both behaviours are pinned by
[`tests/android-bridge.spec.ts`](../tests/android-bridge.spec.ts): one spec
asserts the wrapped agent starts, and one asserts the *bare* agent still does
not. If a future `agent.js` survives document start on its own, the second spec
fails and the wrapper can be deleted.

## Blocking

**Android WebView has no content-blocking API at any API level.** There is no
equivalent of `WKContentRuleList`, so the compiled `.deflate` rule files in
`ios/App/CleanPlayerApp/Resources/rules/` are useless here. Blocking happens per
request in `shouldInterceptRequest`, on a background thread, in the hot path of
every page load.

[`ContentRuleEngine`](app/src/main/java/com/saisamardh/cliqx/blocking/ContentRuleEngine.kt)
reads the same `blocklist.json` the iOS app carries, honouring the subset that
file uses: `url-filter`, `if-domain`/`unless-domain`, `third-party` load types,
and `block` versus `ignore-previous-rules` with later rules winning.

A blocked request returns an **empty 200**, not an error — some players retry
network failures forever.

This does not scale to the full 183,732 rules, and is not meant to. WebKit
compiles those to a DFA; a list of `Regex` walked per request would not hold up.
That is why [`RuleEngine`](app/src/main/java/com/saisamardh/cliqx/blocking/RuleEngine.kt)
is an interface: the real engine is [adblock-rust][abr] over JNI, which consumes
**ABP text directly** — the same input `tools/filter-convert` already starts
from, so the source lists stay shared too.

[abr]: https://github.com/brave/adblock-rust

## Playback

`webkitEnterFullscreen` has no Android counterpart, and this is where the iOS
README's "architectural" claim is genuinely right about the *mechanism*. The
replacement is a different design rather than a shim: the resolved stream URL is
handed to ExoPlayer and the page keeps playing nothing. That needs no
cooperation from the page at all.

What it loses is every source that cannot be reduced to a URL ExoPlayer can
open: DRM, and the blob/MSE sources the agent can see but not hand over. On iOS
those still play, because the page's own `<video>` is what goes full screen.
**This is the real functional gap between the two platforms, and porting more
code will not close it.**

## Known gaps

Ranked by how much they would hurt.

1. **No content worlds.** Android WebView runs all injected scripts in the page
   world, so `window.__cp` is visible to the page and `addJavascriptInterface`
   is reachable from any frame, including a hostile ad frame. On iOS the agent
   hides in a named `WKContentWorld`. `AgentBridge` is written for this — one
   string-only entry point, everything validated — but a page can still read or
   clobber `window.__cp`. There is no API that fixes this.
2. **Third-party detection is wrong for multi-label suffixes.** iOS resolves
   against the bundled Public Suffix List; `ContentRuleEngine` compares the last
   two labels, so it would call `bbc.co.uk` and `itv.co.uk` first-party to each
   other. Harmless for the skeleton's domain-anchored list, **required before
   this meets any real list.** The PSL file is already in the repo at
   `ios/Sources/CleanPlayer/Resources/public_suffix_list.dat.txt`.
3. **Only `blocklist.json` is loaded**, not the four real lists. See
   [blocking](#blocking).
4. **No cleartext to a LAN media server.** iOS allows one with
   `NSAllowsLocalNetworking`; Android's network security config has no
   counterpart, because `<domain>` matches a hostname and has no CIDR form.
   The entries that looked like they covered `10/8` and `192.168/16` matched
   only those literal network addresses, so they permitted nothing and have been
   removed — see the note in
   [`network_security_config.xml`](app/src/main/res/xml/network_security_config.xml).
   Reaching a user-entered server needs cleartext permitted in the config and
   non-private hosts refused in code; that belongs with the Jellyfin feature,
   which does not exist here yet.
5. **No UI.** `MainActivity` is a WebView, a `PlayerView` and log statements.
   The ~14,700 lines of SwiftUI in `ios/Sources/CleanPlayer` have no counterpart
   yet; the ~2,900 lines of Apple-free logic there are a mechanical Kotlin port
   and the obvious next step.
6. **No PiP, Cast, subtitles or episode navigation**, though the agent already
   exposes all of it and `MediaSession` is on the classpath.
7. **`firstUrl` extracts a stream with a regex.** A placeholder for decoding the
   agent's candidate list properly.

## Building

`:app:assembleDebug` and `:app:testDebugUnitTest` both pass: the Kotlin
compiles, the APK carries the shared agent, and 21 Robolectric unit tests cover
the bridge decoder and the rule engine. The JavaScript is verified separately —
the eight specs in `tests/android-bridge.spec.ts` run against Chromium, the
engine Android WebView uses.

Nothing here has run on a device or emulator yet. No AVD or system image is
installed, so the one claim still untested is the runtime one: that the agent
reaches the host and logs `Agent is live in frame …`.

```bash
brew install --cask temurin android-commandlinetools android-platform-tools
```

Then accept the licences and fetch the platform:

```bash
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
yes | sdkmanager --licenses && sdkmanager "platforms;android-35" "build-tools;35.0.0"
```

Point Gradle at it and generate the wrapper (the wrapper JAR is not checked in).
This has to be a Gradle **8.11.1** — `gradle wrapper` rewrites
`distributionUrl` to whatever version generates it, and AGP 8.7.3 does not run
on Gradle 9, which is what Homebrew installs:

```bash
cd android && echo "sdk.dir=$ANDROID_HOME" > local.properties && gradle wrapper
```

Then build and test:

```bash
cd android && ./gradlew :app:assembleDebug :app:testDebugUnitTest
```

The JavaScript specs run from the repository root, and cover both platforms:

```bash
npx playwright test tests/android-bridge.spec.ts
```

## If this gets built out

The root README's "iOS only" note has been reworded: it now points here and
says what this is and is not. The claim that the approach was architecturally
iOS-only was half right — the *implementation* is WebKit-bound, the *approach*
is not, and this module is the evidence.

The `platform iOS 17+` badge was deliberately left alone. iOS is still the only
platform you can install and use; a badge implying otherwise would overstate a
skeleton with no UI that has never run on hardware. It should change when there
is something a person can actually run.
