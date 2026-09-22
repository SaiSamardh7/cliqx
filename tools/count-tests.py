#!/usr/bin/env python3
"""Count the test suites, so the README cannot claim a number nobody checked.

The README said 66 XCTest and 198 agent specs long after both had moved. With
--check this fails when the documented counts drift from the source.
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

if "--check" in sys.argv:
    problems = []
    for name in ("README.md", "docs/ROADMAP.md"):
        text = (root / name).read_text()
        for claimed, label in re.findall(r"(\d+)\s+(Swift|UI|agent)\b", text):
            actual = {"Swift": package, "UI": ui, "agent": specs * browsers}[label]
            if int(claimed) != actual:
                problems.append(f"{name}: says {claimed} {label}, found {actual}")
    if problems:
        sys.exit("\n".join(problems) + f"\n\nCurrent: {summary}")
    print(f"documented counts match: {summary}")
else:
    print(summary)
