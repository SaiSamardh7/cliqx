#!/usr/bin/env python3
r"""Count the shipped rules, so the docs cannot claim a number nobody checked.

Four documents stated Strict as 183,950, 183,880 and 133,333 while the bundle
held 183,732, and ARCHITECTURE.md quoted per-list counts that did not match the
manifest it cited in the same sentence. Every one of those numbers reads as
precise, which is exactly why nobody rechecked it.

`check-rules.py` already proves the payload matches its manifest and that real
ad URLs are blocked. This proves the prose matches the payload.

With --check it fails when a documented count has drifted, and with --write it
corrects them, because a check whose only remedy is editing four files by hand
is a chore that fails the build on every conversion.

Each pattern must match at least once. A reword that loses a claim fails here
rather than quietly passing with the claim unchecked.

The number pattern cannot end on a comma, because `[\d,]+` captured the comma
that ended the sentence and --write then deleted it.
"""
import json
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
RULES = root / "ios/App/CleanPlayerApp/Resources/rules"
BLOCKLIST = root / "ios/App/CleanPlayerApp/Resources/blocklist.json"

sources = json.loads((RULES / "manifest.json").read_text())["sources"]
ads = sources["easylist"]["ruleCount"]
privacy = sources["easyprivacy"]["ruleCount"]
annoyances = sources["annoyances"]["ruleCount"]
# Hand-written, so it has no manifest entry; RuleCatalog counts it the same way.
app_specific = len(json.loads(BLOCKLIST.read_text()))

# Which groups each level selects, mirroring RuleGroup.groups(for:). Standard
# omits annoyances; Strict is every group.
standard = ads + privacy + app_specific
strict = standard + annoyances
largest = max(ads, privacy, annoyances)

FIGURES = {
    "strict": strict,
    "standard": standard,
    "ads": ads,
    "privacy": privacy,
    "annoyances": annoyances,
    "largest": largest,
}

# (document, regex with one capturing group, which figure it states). The regex
# is matched against the whole file, so a claim that moves between lines or
# sections still gets checked.
CLAIMS = [
    ("docs/ROADMAP.md", r"\*\*(\d{1,3}(?:,\d{3})*)\*\* at Strict", "strict"),
    ("docs/ROADMAP.md", r"at Strict, (\d{1,3}(?:,\d{3})*) at Standard", "standard"),
    ("docs/ROADMAP.md", r"peak memory under (\d{1,3}(?:,\d{3})*) rules", "strict"),
    ("docs/ROADMAP.md", r"even after all (\d{1,3}(?:,\d{3})*)", "strict"),
    ("docs/ROADMAP.md", r"real superset: (\d{1,3}(?:,\d{3})*)", "strict"),
    ("docs/ROADMAP.md", r"against Standard's (\d{1,3}(?:,\d{3})*)", "standard"),
    ("docs/ROADMAP.md", r"- (\d{1,3}(?:,\d{3})*) rules compiled", "strict"),
    ("docs/ROADMAP.md", r"`annoyances\.json`, (\d{1,3}(?:,\d{3})*) rules", "annoyances"),
    ("README.md", r"(\d{1,3}(?:,\d{3})*) compiled WebKit content rules", "strict"),
    ("README.md", r"\| Standard \| (\d{1,3}(?:,\d{3})*) \|", "standard"),
    ("README.md", r"\| Strict \| \*\*(\d{1,3}(?:,\d{3})*)\*\* \|", "strict"),
    ("docs/FILTER-ENGINE.md", r"\*\*(\d{1,3}(?:,\d{3})*) rules at Strict", "strict"),
    ("docs/FILTER-ENGINE.md", r"at Strict, (\d{1,3}(?:,\d{3})*) at Standard\*\*", "standard"),
    ("docs/FILTER-ENGINE.md", r"At (\d{1,3}(?:,\d{3})*) total", "strict"),
    ("docs/FILTER-ENGINE.md", r"largest is EasyList at (\d{1,3}(?:,\d{3})*)", "largest"),
    ("docs/FILTER-ENGINE.md", r"`annoyances\.json` \((\d{1,3}(?:,\d{3})*) rules\)", "annoyances"),
    ("docs/FILTER-ENGINE.md", r"— (\d{1,3}(?:,\d{3})*) rules against Standard", "strict"),
    ("docs/FILTER-ENGINE.md", r"rules against Standard's (\d{1,3}(?:,\d{3})*)", "standard"),
    ("ARCHITECTURE.md", r"(\d{1,3}(?:,\d{3})*) are fine; the largest", "strict"),
    ("ARCHITECTURE.md", r"the largest is (\d{1,3}(?:,\d{3})*)", "largest"),
    ("ARCHITECTURE.md", r"EasyList at (\d{1,3}(?:,\d{3})*) rules", "ads"),
    ("ARCHITECTURE.md", r"EasyPrivacy at (\d{1,3}(?:,\d{3})*)", "privacy"),
]

summary = (
    f"Strict {strict:,} · Standard {standard:,} — "
    f"ads {ads:,}, privacy {privacy:,}, annoyances {annoyances:,}, "
    f"app-specific {app_specific}"
)


def problems() -> list[str]:
    found = []
    for name, pattern, figure in CLAIMS:
        text = (root / name).read_text()
        matches = re.findall(pattern, text)
        if not matches:
            found.append(f"{name}: no claim matches /{pattern}/ — "
                         f"reworded, or the {figure} count was dropped")
            continue
        want = FIGURES[figure]
        for claimed in matches:
            if int(claimed.replace(",", "")) != want:
                found.append(f"{name}: says {claimed} for {figure}, "
                             f"found {want:,}")
    return found


def write() -> list[str]:
    changed = []
    for name, pattern, figure in CLAIMS:
        path = root / name
        before = path.read_text()
        # Replace only the captured group, so the surrounding phrasing stands.
        after = re.sub(
            pattern,
            lambda m: m.group(0).replace(m.group(1), f"{FIGURES[figure]:,}"),
            before,
        )
        if after != before:
            path.write_text(after)
            if name not in changed:
                changed.append(name)
    return changed


if "--write" in sys.argv:
    changed = write()
    print(f"{summary}\n" + ("updated: " + ", ".join(changed) if changed
                            else "already correct"))
elif "--check" in sys.argv:
    found = problems()
    if found:
        sys.exit("\n".join(found)
                 + f"\n\nCurrent: {summary}"
                 + "\n\nRun `python3 tools/count-rules.py --write` to correct them.")
    print(f"documented rule counts match: {summary}")
else:
    print(summary)
