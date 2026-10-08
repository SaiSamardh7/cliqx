# Contributing to Cliqx

Issues and pull requests are welcome. This file is short on purpose; the parts
that matter are the ones CI enforces.

## Before you open a pull request

Run both suites. There is no shortcut, and `swift test` is not one — see
[`docs/BUILDING.md`](docs/BUILDING.md) for why it cannot work here.

```bash
cd ios && xcodebuild test -scheme CleanPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

npm ci && npx playwright install chromium webkit && npx playwright test
```

## The four things CI will fail you on

| Check | Tool | Why it exists |
|---|---|---|
| Test counts in `README.md` match the suites | `tools/count-tests.py --check` | They were wrong for two weeks |
| `VERSION` matches every build configuration | `tools/check-version.py` | Two configs said 0.1, two said 1.0 |
| App icon is present and has no alpha channel | `tools/check-icon.py` | Both failure modes build cleanly and only fail at upload |
| Rule manifest `generatedSha256` matches the payload | Swift suite | It keys WebKit's compiled-list cache |

If you add tests, update the counts in the README. The check is there so the
number in the badge is a fact rather than a claim.

## What a good change looks like

- **One concern per pull request.** The blocking engine, the page agent and the
  native player fail in different ways and are reviewed differently.
- **A failing test first, for anything behavioural.** Every heuristic in this
  repo was wrong at least once; the fixtures are how we know which way.
- **A real page in `tests/fixtures/` for anything the agent gets wrong.** A site
  that defeats the overlay heuristic is worth more than a description of it.
- **Match the surrounding style.** Comments here explain *why*, usually by
  naming the thing that broke. Keep that.

## Scope

Cliqx is **iOS only**, and that is architectural. The approach is built on
`WKContentWorld`, `WKContentRuleList` and `webkitEnterFullscreen`. Pull requests
porting it to Android, web or desktop will be declined — there is no version of
this that ports, and pretending otherwise would waste your time.

Cliqx does not host, index, provide or link to media. It opens sites you
navigate to. Changes that turn it into a content directory are out of scope.

## Filter rules

Do not hand-edit anything under `ios/App/CleanPlayerApp/Resources/rules/`. It is
generated:

```bash
./tools/convert-filters.sh      # needs a Rust toolchain
```

That data is a derived work of EasyList under CC BY-SA 3.0, not MIT — see
[`NOTICE.md`](NOTICE.md).

## Commit messages

Present tense, describing what the change does to the product rather than to the
files. When a change closes an item in [`docs/FIX-LIST.md`](docs/FIX-LIST.md),
put the ID in the message (`S2-07: …`) and delete the row, so that file stays a
to-do list rather than a history.

## Reporting a security problem

Not here. See [`SECURITY.md`](SECURITY.md).

## Licence

Contributions are accepted under the [MIT licence](LICENSE), except for
generated filter data, which stays CC BY-SA 3.0.
