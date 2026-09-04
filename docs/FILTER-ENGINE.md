# Choosing Cliqx's filter engine

_Assessment written 3 September 2026. Updated the same day: items 1–3 and 6 of
its own plan are now built, and one of them was built differently than planned._

Six repositories weighed against what this app already does, what it cannot do,
and what each one's licence would cost. **Three conclusions turned out to be
wrong** — two from elsewhere in the repo, and one from this document itself.
All are corrected below.

Current state: **183,950 rules at Strict, 134,397 at Standard**, across four
compiled lists.

## Recommendation

**Embed the `adblock` crate on device — Brave's approach, not Mozilla's.**

It is the only option that closes the update problem without you running any
server, and MPL-2.0 explicitly permits it inside a closed-source app. Firefox
for iOS solved the same problem on 2 September 2026 by hosting converted rules
on Mozilla's Remote Settings; you have no infrastructure to do that. EasyList
already hosts the text lists, so on-device conversion needs no server of yours.

---

## The six, against us

Verdict is relative to this app specifically — a closed-source iOS browser using
`WKContentRuleList`, with no backend.

| Project | Licence | What it gives us | Cost / catch | Verdict |
|---|---|---|---|---|
| **adblock-rust** <br>`brave/adblock-rust`, crate `adblock` | MPL-2.0 | ABP → Apple content-blocker JSON, network *and* cosmetic. Already our build-time converter. | Rust in the iOS build (static lib + FFI). MPL is file-level; §3.2 allows combining with proprietary code. | **Adopt — on device** |
| **EasyList family** <br>`easylist.to` | GPL-3.0 **or** CC BY-SA 3.0 | We ship EasyList + EasyPrivacy. Unused: Fanboy's Annoyance (includes Cookie + Social), EasyList Cookie. | Already settled — CC BY-SA taken, attribution shipped. More lists change nothing legally. | **Adopt more lists** |
| **Firefox for iOS** <br>`mozilla-mobile/firefox-ios` | MPL-2.0 | Shipped iOS ad blocking Sept 2026: EasyList + `WKContentRuleList`, rules delivered via Remote Settings. | Their update model needs a server you don't have. Per-site and statistics patterns are worth reading. | **Study the model** |
| **SafariConverterLib** <br>`AdguardTeam/SafariConverterLib` | GPL-3.0 | Swift converter, AdGuard syntax → Safari JSON + "advanced rules" for a web extension. | GPL would take your whole app with it. Its *documentation* is the valuable part. | **Avoid the code** |
| **AdGuard for iOS** <br>`AdguardTeam/AdguardForiOS` | GPL-3.0 | Reference for multi-blocker splitting, custom lists, per-site controls. | Same GPL problem. Read for architecture, copy nothing. | **Read only** |
| **Brave adblock lists** <br>`brave/adblock-lists` | MPL-2.0 | `brave-unbreak.txt` (site compatibility), social and privacy lists beyond EasyList. | Unbreak rules matter most: they undo over-blocking that kills players. | **Adopt selected** |

---

## Three things that were wrong

### Correction 1 — the licence is not a blocker

`NOTICE.md` and the roadmap said embedding `adblock-rust` "changes the licensing
position", and framed it as a real cost. That overstated it.

MPL-2.0 is **file-level** copyleft, not viral like GPL. Section 3.2 explicitly
permits combining MPL-covered files with proprietary code in a "Larger Work".
Statically linking the crate into a closed-source app is exactly the case the
licence was written to allow.

Obligations: ship the licence text, and publish source for any MPL file **you
modify** — which, using it as a dependency, is none.

**It is a `NOTICE.md` paragraph, not a decision.**

### Correction 2 — we are nowhere near the rule ceiling

WebKit caps a content rule list at **150,000 rules**. At 183,950 total that
would read as over the ceiling. That reading is wrong.

The cap is **per compiled list**, and lists stack — AdGuard for Safari reaches
900,000 by splitting across six content blockers. We compile four separately,
and the largest is EasyList at 77,963: **52% of one list's budget**. A test now
asserts every shipped list stays under the cap.

The one thing not to do is merge them into a single JSON.

### Correction 3 — an unbreak list cannot be its own list

This document's own plan said to compile `brave-unbreak.txt` last, as a separate
list. That would have done nothing.

WebKit applies `ignore-previous-rules` only within the compiled list holding it.
Exceptions shipped in their own list cancel nothing in any other. Verified by
`testWhetherIgnorePreviousRulesReachesAcrossLists`, which is now a permanent
test because the architecture depends on the answer.

Compatibility exceptions have to be parsed into the same `FilterSet` as the
rules they undo. The converter now takes several `--input` per `--output`.

---

## What we are actually facing

Each of these was diagnosed in the running app, not inferred from the reading.

### Open — rules can never refresh

The converter is a build-time Rust tool, so filter lists only change when you
ship a new build. EasyList publishes several times a week. Both browsers that
solved this did so deliberately: Mozilla hosts converted rules; Brave converts
on device and puts an "Update Lists" button in Settings.

_Evidence: `FilterListUpdater.swift` — written, tested, unreachable._

### Partly mitigated — disposable ad domains outrun every list

The domain actually serving ads on the test site was `bagpipewraxle.qpon`, a
generated name on a throwaway TLD calling a user-ID endpoint with the page URL.
No filter list can hold these; they rotate faster than lists ship. Mitigated by
blocking 17 high-abuse TLDs, but that is a floor, not a solution. Brave's lists
plus on-device updates are the real answer.

_Evidence: observed live, now blocked by TLD rule, permanent probe in
`tools/check-rules.py`._

### Closed — annoyance and cookie lists now ship

This was why "Strict" had to be deleted: it selected rule groups no bundled
list populated, so it was byte-identical to Standard while the UI promised more.

Fanboy's Annoyance now ships as `annoyances.json` (49,553 rules) and Strict is
back as a real superset — 183,950 rules against Standard's 134,397. EasyList
Cookie was not added separately; Fanboy's Annoyance already contains it.

_Evidence: `RuleGroup.groups(for:)` — `popups` and `annoyances` had zero lists._

### Closed — unbreak rules now ship, folded into each list

**Correction to this document's own plan.** It said to compile
`brave-unbreak.txt` last, as a separate list. That does nothing: WebKit applies
`ignore-previous-rules` only inside the compiled list holding it, so exceptions
in their own list cancel nothing. Verified by
`testWhetherIgnorePreviousRulesReachesAcrossLists`.

Brave's 944 exceptions are now parsed into the same `FilterSet` as the rules
they undo, and ship inside all three generated lists. Turning protection off for
a whole site is now a last resort rather than the only recovery.

_Evidence: converter takes several `--input` per `--output`; see
`tools/convert-filters.sh`._

### Partly covered — network and cosmetic only, no scriptlets

`WKContentRuleList` can block requests and hide elements. It cannot run
scriptlets or procedural filters (`:has-text`, anti-adblock defusers). AdGuard
reaches those only via a Safari web extension, which a `WKWebView` app cannot
use. Our injected agent covers part of the same ground geometrically.

_Evidence: `agent.js` overlay blocker — the substitute, not an equal._

### Structural — first-party and in-stream ads stay unreachable

Nothing on this list changes that. Firefox's own launch coverage says the same:
their blocker leaves search ads and sponsored content untouched, and "does not
produce an advertising-free browser."

This is why the honest store promise is worth keeping.

---

## What to do

Ordered by payoff per unit of risk. Tracked as items 16–21 in
[`ROADMAP.md`](ROADMAP.md).

1. ~~**Add Fanboy's Annoyance and EasyList Cookie as separate lists.**~~ **Done.**
   Fanboy's Annoyance ships as its own list; Cookie was redundant, as Annoyance
   already contains it.
2. ~~**Add `brave-unbreak.txt`, compiled last.**~~ **Done, differently** — folded
   into every list, because a separate one cancels nothing. See Correction 3.
3. ~~**Restore the Strict level.**~~ **Done.** The test asserting no two
   levels select the same rule groups stays as the guard.
4. **Prototype the crate on device behind a flag.** Static Rust lib, thin FFI,
   convert one list on a background queue. Prove compile time and memory on
   hardware before committing.
5. **Ship the on-device path with an Update Lists button.** Fetch ABP text from
   EasyList's own servers, convert, validate, compile, swap atomically.
   `FilterListUpdater` already does the fetching and the atomic write.
6. ~~**Add a paragraph to `NOTICE.md` for MPL-2.0.**~~ **Done.**

Items 4 and 5 remain. Both need a device build first.

---

## Sources

- [brave/adblock-rust](https://github.com/brave/adblock-rust) — crate `adblock`,
  MPL-2.0, `content-blocking` feature converts ABP to Apple format
- [docs.rs/adblock](https://docs.rs/adblock)
- [AdguardTeam/SafariConverterLib](https://github.com/AdguardTeam/SafariConverterLib)
  — GPL-3.0; source of the 150,000-per-blocker and 6-blocker-split facts
- [brave/adblock-lists](https://github.com/brave/adblock-lists) — MPL-2.0
- [easylist.to](https://easylist.to/) — EasyList, EasyPrivacy, EasyList Cookie,
  Fanboy's Annoyance, Fanboy's Social
- [ghacks — Firefox for iOS ad blocking exits testing](https://www.ghacks.net/2026/09/02/firefox-for-ios-ad-blocking-exits-testing-but-wont-block-firefoxs-own-ads/)
- [Apple Developer Forums — WKContentRuleListStore rule limit](https://developer.apple.com/forums/thread/734111)

See also: [`ROADMAP.md`](ROADMAP.md) · [`../ARCHITECTURE.md`](../ARCHITECTURE.md)
· [`../NOTICE.md`](../NOTICE.md)
