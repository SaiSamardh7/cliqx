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
reachable in-app. See `NOTICE.md` — this is settled.

## Settled

- Privacy policy text (`PRIVACY.md`, and in-app under Settings → About).
- Attribution screen, reachable from Settings.
- Content rules verified to compile and to be in force (`RuleActivationTests`).
- Accessibility: VoiceOver labels on every control, Dynamic Type throughout,
  44pt minimum touch targets.
- UI tests drive the real app through onboarding, Settings, protection status,
  attribution and the privacy policy.
- iPad: builds and lays out for `TARGETED_DEVICE_FAMILY = 1,2`.

## Open — must be closed before submission

1. **Bundle identifier** is still `com.example.cleanplayer`. Apple will reject
   a reverse-DNS identifier under `com.example`.
2. **Marketing version** is `0.1`. Ship `1.0`.
3. **App icon** is absent. There is no asset catalogue in the target.
4. **Final display name** is `CleanPlayerApp` (from `PRODUCT_NAME`), while the
   UI says "Cliqx". Pick one.
5. **Privacy policy URL.** `PRIVACY.md` needs publishing somewhere with a
   stable URL, and a contact address filling in.
6. **Code signing** is disabled in the project (`CODE_SIGNING_ALLOWED = NO`),
   which is fine for simulator work and must change for a device build.
7. **Physical-device testing.** The app has never run on real hardware.

## Review risk to prepare for

A browser that blocks advertising is reviewed under guideline 4.7 and, more
awkwardly, 1.1/5.2 if it is presented as a way to reach infringing video. Lead
with the browser-and-privacy framing, not with piracy-adjacent language, and
have the CC BY-SA attribution screen ready to point at.
