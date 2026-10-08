# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| 1.0.x | ✅ |
| < 1.0 | ❌ |

Cliqx is pre-release and not yet on the App Store. Until it ships, "supported"
means `main`.

## Reporting a vulnerability

**Please do not open a public issue.**

Use GitHub's private vulnerability reporting:
[**Report a vulnerability**](https://github.com/SaiSamardh7/cliqx/security/advisories/new).
That channel is private to the maintainer until an advisory is published.

What helps:

- The iOS version and device or simulator.
- The page or URL that triggers it, or a minimal reproduction under `tests/fixtures/`.
- What an attacker gets — the impact, not just the mechanism.

Expect an acknowledgement within 7 days. There is one maintainer and no bounty
programme, so please do not expect the response times of a funded security team.

## What is in scope

The attack surface is mostly the boundary between a hostile page and the native
app:

- **Script-world escape.** The page agent runs in a non-main `WKContentWorld`.
  Anything that lets page JavaScript read, reach or impersonate it is in scope.
- **Bridge message forgery.** A page convincing the native side to act on a
  message it did not send — the stream it plays, the site it believes it is on,
  the episode it advances to.
- **Navigation-policy bypass.** Popups that open, or hijacked loads that are
  followed, despite being refused.
- **Filter-rule integrity.** Anything that causes the app to compile rules whose
  `generatedSha256` does not match the shipped payload.
- **Local data exposure.** Recents, Jellyfin credentials, or MetricKit payloads
  leaving the device by any route.

## What is not in scope

- **A site that defeats the blocker.** Ad blocking is adversarial and
  incomplete by nature. Rules that miss are a [bug report](https://github.com/SaiSamardh7/cliqx/issues/new/choose),
  not a vulnerability.
- **Upstream filter-list content.** Report false positives to EasyList.
- **VLCKit vulnerabilities.** Report upstream to VideoLAN; we will track the
  version bump.
- **Anything requiring a jailbroken device or a passcode you already have.**

## Design facts a report can rely on

These are architectural, so a finding that contradicts one of them is
interesting by definition:

- There is no Cliqx account, server or backend. The app makes no network request
  of its own; every request originates from a page the user navigated to.
- No advertising, analytics, tracking or crash-reporting SDK is linked.
- Filter lists are bundled in the binary, not fetched at runtime.
- One third-party library is linked: VLCKit, for on-device decoding
  ([`NOTICE.md`](NOTICE.md)).

Full detail in [`PRIVACY.md`](PRIVACY.md) and
[`docs/APP-STORE.md`](docs/APP-STORE.md).
