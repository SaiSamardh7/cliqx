# Third-party notices

Kept short on purpose: every entry here is something whose licence imposes an
obligation on this project.

## EasyList / EasyPrivacy / Fanboy's Annoyance — filter rules

Source: https://github.com/easylist/easylist (https://easylist.to)

Dual-licensed **GPL-3.0 OR CC BY-SA 3.0**.

This project uses the **CC BY-SA 3.0** option. Two obligations follow, and they
attach to the *generated rule data*, not to the app's own source:

- **Attribution.** The notice below must remain with any distributed rule data
  and stay reachable from the app's Settings screen.
- **Share-alike.** `ios/App/CleanPlayerApp/Resources/rules/*.json.deflate` is a
  derived work of EasyList and must be redistributed under CC BY-SA 3.0.

> Filter rules from EasyList, EasyPrivacy and Fanboy's Annoyance List
> (easylist.to), used under CC BY-SA 3.0.
> https://creativecommons.org/licenses/by-sa/3.0/

Fanboy's Annoyance List already contains the Cookie and Social lists, so those
are not fetched separately.

**Resolved.** The project ships the rule data under CC BY-SA 3.0 and accepts
the share-alike obligation on that data. Concretely:

- `ios/App/CleanPlayerApp/Resources/rules/*.json.deflate` is offered under
  CC BY-SA 3.0. Anyone redistributing it may do so under the same licence.
- The attribution above is reachable in the app at
  **Settings -> About -> Attribution and licences**, which also links to the
  licence text and to the upstream repository.
- The obligation attaches to the rule data only. The app's own source is not a
  derived work of EasyList and is not placed under CC BY-SA by this choice.
- The GPL-3.0 option is deliberately **not** taken, because it would reach
  further than the rule data.

Regenerating the rules with `tools/convert-filters.sh` does not change any of
this; the derived files carry the same licence as before.

## Brave Unbreak — site-compatibility rules

Source: https://github.com/brave/adblock-lists — **MPL-2.0**.

944 exception rules that stop filters breaking specific sites. They are compiled
**into each generated list** rather than shipped as a list of their own: WebKit
applies `ignore-previous-rules` only within the compiled list holding it, so a
separate unbreak list would cancel nothing. Verified in
`RuleActivationTests.testWhetherIgnorePreviousRulesReachesAcrossLists`.

> Site-compatibility exceptions from Brave Unbreak
> (github.com/brave/adblock-lists), used under MPL-2.0.

Because they are compiled in, the app **distributes this rule data** — this is
not the build-tool case below, and the attribution obligation is live. The
notice above is reachable at **Settings -> About -> Attribution and licences**,
alongside the EasyList credit and a link to the MPL-2.0 text, and
`ProtectionUITests.testCompiledInExceptionsAreAttributed` fails if it stops
being reachable. It was missing from that screen until 6 September 2026:
`FilterSource.all` does not include the unbreak source, so nothing rendered it.

## Brave adblock-rust — filter converter

Source: https://github.com/brave/adblock-rust (crate `adblock`) — **MPL-2.0**.

Currently used only by `tools/convert-filters.sh` at build time, so nothing of
it ships.

**If it is embedded in the app** — the planned route to runtime filter updates,
see `docs/FILTER-ENGINE.md` — that is permitted and this section is all that
changes. MPL-2.0 is **file-level** copyleft: §3.2 expressly allows combining
MPL-covered files with proprietary files in a Larger Work and distributing the
result under your own terms. The obligations are to ship the licence text and to
publish source for any MPL file **you modify**. Used unmodified as a dependency,
that is none.

This is not a licensing decision to be taken later; it is this notice plus the
licence text.

## Firefox for iOS, AdGuard for iOS — architectural reference only

- https://github.com/mozilla-mobile/firefox-ios — MPL-2.0
- https://github.com/AdguardTeam/AdguardForiOS — GPL-3.0

Read for how they structure protection levels, per-site controls and list
management. **No code from either is copied into this project.** AdGuard in
particular is GPL-3.0, which would be incompatible with a closed distribution.

## Public Suffix List — site-boundary data

Source: https://publicsuffix.org/list/public_suffix_list.dat — **MPL-2.0**.

The unmodified list is bundled at
`ios/Sources/CleanPlayer/Resources/public_suffix_list.dat.txt`. It is used to
keep unrelated tenants on shared hosting domains such as `github.io` and
`pages.dev` in separate security boundaries.

## VLCKit — media playback

Source: https://code.videolan.org/videolan/VLCKit, consumed as the Swift
package https://github.com/tylerjonesio/vlckit-spm (pinned to 3.6.0 in
`Package.resolved`) — **LGPL-2.1-or-later**.

VLCKit wraps libVLC and plays every local file and every server stream: MKV,
AVI, FLV and the codecs AVFoundation will not open. It is linked into the
shipped binary, so its obligations are live.

LGPL-2.1 §6 allows linking with a work under other terms provided the recipient
can **relink** the result against a modified VLCKit. For an iOS application
that is satisfied by:

- **Licence text.** Shipped with the app and reachable at **Settings -> About
  -> Attribution and licences**.
- **Source.** VLCKit is used unmodified at the pinned version above; its source
  is at the URL above, and this file records the exact revision consumed.
- **Relinking.** The app's own source is MIT and public, so anyone may rebuild
  it against their own VLCKit. `Package.resolved` pins the version they would
  be replacing.

> Media playback by VLCKit (code.videolan.org/videolan/VLCKit), used under
> LGPL-2.1-or-later.

This is the one third-party component **linked into the binary**. It collects
nothing and contacts nothing on its own: it is handed a local file URL or a
stream URL the user's own server issued. `PRIVACY.md` says the app links no
analytics or tracking SDKs, which remains true, and deliberately no longer says
"no third-party SDKs" — that claim was wrong while VLCKit was linked.

## Hand-written rules

`ios/App/CleanPlayerApp/Resources/blocklist.json` was written for this project
and carries no third-party obligation. It is the offline fallback when no
downloaded list is active.

## Which licence covers what

The app's own source is MIT — see [`LICENSE`](LICENSE). That licence does not
extend to the generated filter-rule data in
`ios/App/CleanPlayerApp/Resources/rules/`, which is a derived work of EasyList
and is offered under CC BY-SA 3.0 as set out above.
