## What this changes

<!-- The product behaviour, not the files. One concern per PR. -->

## Why

<!-- If it fixes something from docs/FIX-LIST.md, put the ID here (S2-07) and
     delete the row in that file. -->

## How it was verified

- [ ] `xcodebuild test -scheme CleanPlayer` passes on a simulator destination
- [ ] `npx playwright test` passes in **both** Chromium and WebKit
- [ ] Test counts in `README.md` updated if I added or removed tests
- [ ] Tried on a device, or noted below that I could not

<!-- For anything behavioural: which test fails without this change? -->

## Scope check

- [ ] This does not hand-edit generated rules under `Resources/rules/`
- [ ] This does not add a network request the app makes on its own
- [ ] This does not add an analytics, tracking or crash-reporting dependency
