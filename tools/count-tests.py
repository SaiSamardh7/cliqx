#!/usr/bin/env python3
"""Count the test suites, so the README cannot claim a number nobody checked.

The README said 66 XCTest and 198 agent specs long after both had moved. With
--check this fails when the documented counts drift from the source, and with
--write it corrects them — because a check whose only remedy is "go and edit
two files by hand" is a chore that fails the build on every commit that adds
a test, which is most of them.
"""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent


def swift_tests(directory: pathlib.Path) -> int:
    return sum(
        len(re.findall(r"^\s*func test\w*\s*\(", path.read_text(), re.M))
        for path in directory.rglob("*.swift")
    )


def playwright_specs(directory: pathlib.Path) -> int:
    # `test('name', ...)` but not test.describe / test.beforeEach / test.skip.
    return sum(
        len(re.findall(r"(?:^|\s)test\s*\(\s*['\"`]", path.read_text(), re.M))
        for path in directory.glob("*.spec.ts")
    )


def engines() -> int:
    config = (root / "playwright.config.ts").read_text()
    return len(re.findall(r"name:\s*'(\w+)'", config))


package = swift_tests(root / "ios/Tests")
ui = swift_tests(root / "ios/App/CleanPlayerAppUITests")
specs = playwright_specs(root / "tests")
browsers = engines()
total = package + ui + specs * browsers

summary = (
    f"{total} — {package} Swift · {ui} UI · "
    f"{specs * browsers} agent ({specs} specs, {browsers} engines)"
)

DOCUMENTS = ("README.md", "docs/ROADMAP.md")
counts = {"Swift": package, "UI": ui, "agent": specs * browsers}


def rewrite(text: str) -> str:
    """Correct every count and total this file states."""
    text = re.sub(
        r"(\d+)\s+(Swift|UI|agent)\b",
        lambda m: f"{counts[m.group(2)]} {m.group(2)}",
        text,
    )
    # The totals line, and the spec count wherever it is phrased — the README
    # writes "(204 specs across" and the roadmap "(204 specs, two engines)".
    text = re.sub(r"\*\*\d+\*\* —", f"**{total}** —", text)
    text = re.sub(r"\(\d+ specs\b", f"({specs} specs", text)
    # The README badge states the total too, and a badge is the first
    # number anyone reads.
    return re.sub(r"tests-\d+%20passing", f"tests-{total}%20passing", text)


if "--write" in sys.argv:
    changed = []
    for name in DOCUMENTS:
        path = root / name
        before = path.read_text()
        after = rewrite(before)
        if after != before:
            path.write_text(after)
            changed.append(name)
    print(f"{summary}\n" + ("updated: " + ", ".join(changed) if changed
                            else "already correct"))
elif "--check" in sys.argv:
    problems = []
    for name in DOCUMENTS:
        text = (root / name).read_text()
        for claimed, label in re.findall(r"(\d+)\s+(Swift|UI|agent)\b", text):
            if int(claimed) != counts[label]:
                problems.append(f"{name}: says {claimed} {label}, found {counts[label]}")
        # The spec count too. It drifted unnoticed because only the run totals
        # were ever checked, and the two are written differently in each file.
        for claimed in re.findall(r"\((\d+) specs\b", text):
            if int(claimed) != specs:
                problems.append(f"{name}: says {claimed} specs, found {specs}")
        for claimed in re.findall(r"tests-(\d+)%20passing", text):
            if int(claimed) != total:
                problems.append(f"{name}: badge says {claimed}, found {total}")
    if problems:
        sys.exit("\n".join(problems)
                 + f"\n\nCurrent: {summary}"
                 + "\n\nRun `python3 tools/count-tests.py --write` to correct them.")
    print(f"documented counts match: {summary}")
else:
    print(summary)
