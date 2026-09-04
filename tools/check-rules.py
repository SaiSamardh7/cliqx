#!/usr/bin/env python3
"""Checks the shipped rule data without needing WebKit or a simulator.

Two things, both of which fail silently in the app if they break:

1. The payload matches its manifest. The manifest's generatedSha256 keys
   WebKit's compiled-list cache, so a payload that has drifted from it makes
   the app reuse a compile of rules it is no longer shipping.

2. Real ad and tracker URLs are actually blocked. A conversion that quietly
   produced a list full of exceptions, or dropped the network rules, would
   still compile and still report a large rule count.
"""
import hashlib, json, pathlib, re, sys, zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
RULES = ROOT / "ios/App/CleanPlayerApp/Resources/rules"
HANDWRITTEN = ROOT / "ios/App/CleanPlayerApp/Resources/blocklist.json"

# A page domain no exception in the lists is scoped to, standing in for
# "an ordinary site the user is watching video on".
PAGE = "somevideosite.test"

# Third-party requests an ad-funded video page typically makes.
PROBES = [
    ("https://securepubads.g.doubleclick.net/tag/js/gpt.js", "script"),
    ("https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js", "script"),
    ("https://www.googletagservices.com/tag/js/gpt.js", "script"),
    ("https://s.amazon-adsystem.com/aax2/apstag.js", "script"),
    ("https://ib.adnxs.com/ttj?id=123", "script"),
    ("https://static.criteo.net/js/ld/ld.js", "script"),
    ("https://cdn.taboola.com/libtrc/x/loader.js", "script"),
    ("https://widgets.outbrain.com/outbrain.js", "script"),
    ("https://ads.pubmatic.com/AdServer/js/gshowad.js", "script"),
    ("https://fastlane.rubiconproject.com/a/api/fastlane.json", "raw"),
    ("https://www.google-analytics.com/analytics.js", "script"),
    ("https://connect.facebook.net/en_US/fbevents.js", "script"),
    ("https://www.googletagmanager.com/gtm.js?id=GTM-1", "script"),
    ("https://sb.scorecardresearch.com/beacon.js", "script"),
    ("https://exoclick.com/ads.js", "script"),
    ("https://a.popads.net/pop.js", "script"),
    ("https://static.adsterra.com/sw.js", "script"),
    ("https://doubleclick.net/pagead/ads?x=1", "image"),
    # Observed live on a real streaming site. Random-word domains on
    # throwaway TLDs rotate faster than any filter list ships, so these are
    # covered by TLD rather than by name.
    ("https://bagpipewraxle.qpon/cuid/?f=x", "raw"),
    ("https://vo.shacklerocklet.com/rl7aQHjpOAnll1/136833", "script"),
]

# The other half of the TLD rules: what they must never touch. Blocking a
# whole TLD is broad, so the guard against over-blocking is a test, not care.
ALLOWED = [
    ("https://cdnjs.cloudflare.com/ajax/libs/jquery/3.6.0/jquery.min.js", "script"),
    ("https://challenges.cloudflare.com/turnstile/v0/api.js", "script"),
    ("https://fonts.gstatic.com/s/inter/v1/x.woff2", "font"),
    ("https://fonts.googleapis.com/css2?family=Inter", "style-sheet"),
    ("https://i.ytimg.com/vi/x/hqdefault.jpg", "image"),
    ("https://player.vimeo.com/video/12345", "document"),
]


def load_rules(failures):
    rules = json.loads(HANDWRITTEN.read_text())
    manifest = json.loads((RULES / "manifest.json").read_text())
    for name, source in manifest["sources"].items():
        packed = RULES / f"{source['generated']}.deflate"
        if not packed.exists():
            failures.append(f"{name}: {packed.name} missing")
            continue
        raw = zlib.decompress(packed.read_bytes(), -15)
        digest = hashlib.sha256(raw).hexdigest()
        if digest != source["generatedSha256"]:
            failures.append(f"{name}: sha256 {digest} != manifest "
                            f"{source['generatedSha256']}")
        parsed = json.loads(raw)
        if len(parsed) != source["ruleCount"]:
            failures.append(f"{name}: {len(parsed)} rules != manifest "
                            f"{source['ruleCount']}")
        print(f"  {name}: {len(parsed):,} rules, sha256 ok")
        rules += parsed
    return rules


def applies(trigger, url, resource_type):
    """Approximates WebKit's matching closely enough to catch a broken list.

    if-domain is about the *page*, not the request — an exception scoped to
    some other site must not count as unblocking this one. Getting that wrong
    makes a healthy list look full of holes.
    """
    if "if-domain" in trigger:
        return False
    for domain in trigger.get("unless-domain", []):
        if PAGE.endswith(domain.lstrip("*").lstrip(".")):
            return False
    if resource_type not in trigger.get("resource-type", [resource_type]):
        return False
    if "third-party" not in trigger.get("load-type", ["third-party"]):
        return False
    pattern = trigger.get("url-filter", "")
    literals = [t for t in re.split(r"[^a-zA-Z0-9._-]+", pattern) if len(t) >= 4]
    if literals and not any(t in url for t in literals):
        return False       # cheap reject before the expensive regex
    try:
        return bool(re.search(pattern, url))
    except re.error:
        return False       # WebKit's dialect, not Python's; ignore


def main():
    failures = []
    print("Rule data:")
    rules = load_rules(failures)

    blocks = [r["trigger"] for r in rules if r["action"]["type"] == "block"]
    excepts = [r["trigger"] for r in rules
               if r["action"]["type"] == "ignore-previous-rules"]
    print(f"\nBlocking, as seen from https://{PAGE}/ "
          f"({len(blocks):,} block rules, {len(excepts):,} exceptions):")

    for url, kind in PROBES:
        host = url.split("/")[2]
        blocked = any(applies(t, url, kind) for t in blocks)
        exempt = any(applies(t, url, kind) for t in excepts)
        if blocked and not exempt:
            print(f"  blocked      {host}")
        else:
            reason = "exempted by ignore-previous-rules" if blocked else "no matching rule"
            print(f"  LEAKS        {host}  ({reason})")
            failures.append(f"{host} is not blocked: {reason}")

    print("\nMust stay reachable (over-blocking guard):")
    for url, kind in ALLOWED:
        host = url.split("/")[2]
        blocked = any(applies(t, url, kind) for t in blocks)
        exempt = any(applies(t, url, kind) for t in excepts)
        if blocked and not exempt:
            print(f"  OVER-BLOCKED {host}")
            failures.append(f"{host} is blocked but must not be")
        else:
            print(f"  allowed      {host}")

    if failures:
        print("\n" + "\n".join(failures), file=sys.stderr)
        return 1
    print(f"\nAll {len(PROBES)} probes blocked, "
          f"all {len(ALLOWED)} allowed hosts reachable.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
