# App Store submission notes

What is settled, and what is still open. Everything under "Open" blocks
submission; nothing under "Settled" does.

## App privacy declarations

Apple's questionnaire asks, per data type, whether it is collected. For this
app the answer is **"Data Not Collected"** for every category, and that answer
is defensible from the architecture rather than from a promise:

| Apple category | Answer | Why |
|---|---|---|
| Contact info, Health, Financial, Location, Contacts, Photos | Not collected | Never requested; no entitlement, no API use. |
| Browsing history | Not collected | Recents are stored locally in `UserDefaults` and never transmitted. There is no server to transmit to. |
| Search history | Not collected | Address-bar searches go straight to the search engine as a normal web request. |
| Identifiers | Not collected | No IDFA, no IDFV use, no account. |
| Usage data, Diagnostics | Not collected | No analytics or crash SDK is linked. |

Supporting facts a reviewer can check:

- No third-party SDKs. The only dependency is the local `CleanPlayer` Swift
  package in this repository.
- No `NSUserTrackingUsageDescription`, because nothing tracks.
- The app makes no network request of its own. Every request originates from a
  page the user navigated to. Filter lists are bundled, not fetched.

## Export compliance

The app uses HTTPS through the system's own networking. It implements no
cryptography of its own beyond SHA-256 hashing of bundled resources for cache
keying, which is not a data-protection use. The standard exemption applies;
confirm the current wording in App Store Connect at submission time.

## Licensing

EasyList / EasyPrivacy rule data ships under CC BY-SA 3.0 with attribution
reachable in-app. Brave Unbreak's compatibility exceptions are compiled into
each of those lists and ship with them, so their MPL-2.0 credit is on the same
screen — the obligation attaches to rule data the app distributes, not just to
the build-time converter. Both are asserted by
`ProtectionUITests.testCompiledInExceptionsAreAttributed`. See `NOTICE.md`.

## Settled

- Privacy policy text (`PRIVACY.md`, and in-app under Settings → About).
- Attribution screen, reachable from Settings.
- Content rules verified to compile and to be in force (`RuleActivationTests`).
- Accessibility: VoiceOver labels on every control, Dynamic Type throughout,
  44pt minimum touch targets.
- UI tests drive the real app through onboarding, Settings, protection status,
  attribution, licences, the protection picker, private browsing and the
  privacy policy.
- iPad: builds and lays out for `TARGETED_DEVICE_FAMILY = 1,2`.

## Closed since this list was written

Verified in `CleanPlayerApp.xcodeproj/project.pbxproj` rather than from memory:

- **Bundle identifier** is `com.saisamardh.cleanplayer`.
- **App icon** ships: `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`, and
  `tools/check-icon.py` guards it in CI.
- **Display name** is `Cliqx` via `INFOPLIST_KEY_CFBundleDisplayName`, matching
  every screen in the app.
- **Code signing** is disabled for the simulator SDK only
  (`CODE_SIGNING_ALLOWED[sdk=iphonesimulator*]`); device builds sign normally.
- **Physical-device testing** has happened — the app is installed and running
  on an iPhone. What is still unmeasured there is listed as ROADMAP item 8.

## Open — must be closed before submission

1. **Marketing version** is `0.1`. Ship `1.0`.
2. **Privacy policy URL.** `PRIVACY.md` needs publishing somewhere with a
   stable URL, and a contact address filling in.
3. **Filter lists cannot update between app releases.** Settings warns after 30
   days, which is honest but not a fix. ROADMAP items 19–20.
4. **No measured success rate for "Watch clean".** ROADMAP item 10 — the one
   number that decides whether the app is good.

## Review risk to prepare for

A browser that blocks advertising is reviewed under guideline 4.7 and, more
awkwardly, 1.1/5.2 if it is presented as a way to reach infringing video. Lead
with the browser-and-privacy framing, not with piracy-adjacent language, and
have the CC BY-SA attribution screen ready to point at.
