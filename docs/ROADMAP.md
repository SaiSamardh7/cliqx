# Shipping Cliqx — everything left before release

_Verified 4 September 2026 · working tree clean_

The blocking engine is done and proven. What remains is almost entirely
identity, hardware, and one measurement nobody has taken yet.

Grouped by **who can unblock it**, because that is the real constraint — not
priority.

| | |
|---|---|
| Rules active | **183,950** at Strict, 134,397 at Standard, across four lists |
| Ad hosts covered | **~104,182** distinct domains in block rules |
| Tests passing | **213** — 58 Swift · 5 UI · 150 agent (two engines) |
| Commits | **15**, no remote yet |

---

## Blocked on you — 5 items

None of these are engineering problems. Each is a call only you can make, and
four are hard App Store blockers.

### 1. App identity — one field left

Bundle ID is `com.saisamardh.cleanplayer` and signs against your team. The home
screen now reads **Cliqx**, matching every screen inside the app — it
installed as "CleanPlayerApp" until `INFOPLIST_KEY_CFBundleDisplayName` was set.

What is left: `MARKETING_VERSION` is still `0.1`.

**Say the word on 1.0.**

### 2. App icon ✅ done

`Assets.xcassets/AppIcon.appiconset` now ships a 1024×1024 opaque PNG and both
build configurations set `ASSETCATALOG_COMPILER_APPICON_NAME`. Verified in the
built bundle: `CFBundleIconName` is present and the art is in `Assets.car`.

The art is drawn by [`tools/make-icon.py`](../tools/make-icon.py) rather than
checked in as an opaque binary, so it regenerates exactly and is tweaked in one
place. `tools/check-icon.py` runs in CI, because both ways this breaks — a
configuration missing the setting, an icon carrying an alpha channel — build
cleanly and only fail at upload.

### 3. Filter lists can never update

The updater fetches ABP text, the app consumes WebKit JSON, and the converter is
a build-time Rust tool. So rules only change when the app updates. Settings now
warns past 30 days, but the gap is real.

**Choose:** host pre-converted JSON somewhere, or embed `adblock-rust` and accept
MPL-2.0 in `NOTICE.md`.

### 4. Privacy policy has no home

`PRIVACY.md` is written and shown in-app, but the App Store listing needs a
public URL, and the contact line is still a `TODO`.

**Give me:** where it will live, and a contact address.

### 5. Crash reporting conflicts with your privacy claim

Your declaration is "Data Not Collected" for every category, defensible because
there are no third-party SDKs. Adding a crash reporter changes that answer.
MetricKit with an explicit user-initiated export would not.

**Choose:** no crash reporting, on-device MetricKit, or accept the declaration
change.

### 6. A stale duplicate project is still on disk

`~/Desktop/repos/online vedio player ` — note the trailing space — holds
`OnlineVideoPlayer`, the superseded 2-rule version. It is not in git. It is what
the last audit accidentally read.

**Say the word** and I'll delete it. I won't remove your files unasked.

---

## Needs hardware I don't have — 3 items

I can build, test and drive the app in the simulator. I cannot touch a physical
device, and I cannot push to a remote you haven't created.

### 7. No git remote, so CI has never run

Four workflow jobs are written and correct — Swift tests, UI tests, the agent in
two engines, and the ad-coverage check — and **not one has ever executed**,
because there is nowhere to push. This is genuinely the first thing to fix:
nothing else stays verified without it.

**You do:** create the repo and push. Everything else is already wired.

### 8. Measure it on the iPhone

The app now runs there. What is still unmeasured on hardware:

compile time, peak memory under 183,880 rules, cellular behaviour, landscape
theater, and iPad Split View.

**You do:** watch those while using it, and tell me what drags.

### 9. Code signing ✅ done

Scoped to `[sdk=iphonesimulator*]`, so simulator builds stay unsigned — they
must, because the bundle carries `com.apple.provenance` attributes codesign
rejects — while device builds sign against your team. The app is installed and
running on the iPhone.

Device builds must run outside `~/Desktop`, `~/Documents` and `~/Downloads`;
see the README.

---

## The measurement nobody has taken — the real gap

### 10. Ten real video sites, written down, with a denominator

There is currently no success rate for "Watch clean" because nobody has run it
against ten real sites and recorded what happened — which worked, which broke,
which playback mode fired, what escaped the blocker. Until that exists, any
quality claim is a guess.

Everything above is bookkeeping. This is the thing that decides whether the app
is actually good.

**You do:** browse ten sites and note results.
**I do:** turn every failure into a permanent fixture.

---

## Engineering I can do now — 5 items, no input needed

Say the word on any of these and they're done. None are blockers; the first is
the one that most affects real protection.

### 11. A page open during first compile stays under-protected

Rules apply at navigation time. If you open a site during the ~10s cold compile,
that page keeps the 36-rule fallback until you reload — even after all 133,333
land. It should reload itself when the full set arrives.

### 12. Onboarding should state coverage from the manifest

It currently describes blocking in prose. It could read the real domain count out
of `manifest.json`, so the claim can never drift from what actually shipped.

### 13. Nothing is localised

`SWIFT_EMIT_LOC_STRINGS` is on but there is no string catalogue, so every label
is English-only.

### 14. Dark mode and rotation are unverified

Both are implemented through system colours and should be fine, but I have only
ever screenshotted light mode in portrait. Theater mode in landscape especially
deserves a look.

### 15. iPad multitasking is untested

The layout caps its measure and works full-screen. Split View and Stage Manager
have never been exercised.

---

## Filter engine — 6 items, 4 done

From the engine and licence assessment. Items 16, 17, 18 and 21 are **done**;
19 and 20 remain and need a device.

### 16. Add Fanboy's Annoyance ✅ done

Shipped as `annoyances.json`, 49,553 rules, its own compiled list. EasyList
Cookie was **not** added separately: Fanboy's Annoyance already contains the
Cookie and Social lists, so it would have been the same rules twice.

### 17. Fold `brave-unbreak.txt` into every list ✅ done

**The original plan here was wrong.** It said to compile the unbreak list last,
as a list of its own. WebKit applies `ignore-previous-rules` only within the
compiled list that holds it, so a separate unbreak list cancels nothing at all.
Verified by `testWhetherIgnorePreviousRulesReachesAcrossLists`.

Brave's 944 compatibility exceptions are now parsed into the same `FilterSet` as
the rules they undo, so they ship inside `ads.json`, `privacy.json` and
`annoyances.json`. The converter takes several `--input` per `--output` for
exactly this.

Also corrected: `brave-unbreak.txt` lives at the **repo root**. The copy in
`brave-lists/` is a 24-byte stub.

### 18. Restore the Strict level ✅ done

Off / Standard / Strict is back, and Strict is now a real superset: 183,950
rules against Standard's 134,397. Two tests guard it — no two levels may select
the same rule groups, and Strict must add at least one group over Standard.

### 19. Prototype the `adblock` crate on device, behind a flag

Static Rust library plus a thin FFI, converting one list on a background queue.
Measure compile time and peak memory on hardware before committing to it.

**Blocked on:** item 8 (a device build).

### 20. Ship on-device conversion with an "Update Lists" button

Fetch ABP text from EasyList's own servers, convert, validate, compile, swap
atomically. `FilterListUpdater` already does the fetching, validation and atomic
write — this replaces its unusable ABP-to-app path with a real one.

This closes item 3, and it is Brave's approach rather than Mozilla's: Firefox
for iOS solved the same problem by hosting converted rules on Remote Settings,
which needs a server you do not have. EasyList already hosts the text.

**Blocked on:** item 19.

### 21. Add an MPL-2.0 paragraph to NOTICE.md ✅ done

MPL-2.0 is file-level copyleft and §3.2 explicitly permits combining it with
proprietary code in a larger work, so embedding the crate in a closed-source app
is allowed. Ship the licence text and state the crate is unmodified.

Correcting an earlier note in this file: this was paperwork, not a decision.
`NOTICE.md` now states the §3.2 position, and covers Fanboy's Annoyance and
Brave Unbreak.

---

## Order to do it in

This one genuinely is a sequence — each step depends on the one above it.

1. **Push to a remote.** CI starts guarding everything else.
2. **Bundle ID, name, version, icon.** Unblocks any real build.
3. **Device build with signing.** First time on hardware.
4. **Ten-site measurement.** Failures become fixtures.
5. **On-device conversion, 19–20.** Closes the refresh gap for good.
7. **Publish the privacy policy, fill in contact.** Required by the listing.
8. **TestFlight, 25–50 testers.** Where reliability numbers come from.
9. **Hold for the targets.** >99.5% crash-free, >80% Watch clean success, <5%
   protection-disable rate.

---

## Say this, not the other thing

> Blocks over 100,000 known ad and tracker domains, and hides the ad slots they
> leave behind.

True, verifiable, and a bigger number than "blocks all ads" — which is false,
because first-party ads and ads inserted into the video stream are unreachable
from a browser, and one counterexample turns a strong product into a broken
promise.

---

## Already settled

- 133,333 rules compiled, cached and attached
- Disposable-TLD blocking for rotating ad domains
- Atomic activation with rollback
- Content-hash cache keys
- Per-site exceptions, persisted
- Private browsing
- Renderer-crash recovery
- Auth and TLS handling
- Cross-site popup and redirect guards
- Clickjacking iframe layer caught
- Player iframes protected from the blocker
- Onboarding, Settings, attribution
- EasyList licence resolved (CC BY-SA 3.0)
- Privacy policy written
- Accessibility and iPad passes
- Bundle 15 MB → 2.9 MB
- 116 tests across four suites

---

See also: [`ARCHITECTURE.md`](../ARCHITECTURE.md) ·
[`docs/APP-STORE.md`](APP-STORE.md) · [`NOTICE.md`](../NOTICE.md) ·
[`PRIVACY.md`](../PRIVACY.md)
