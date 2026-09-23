import { defineConfig, devices } from '@playwright/test';

// Both engines, deliberately. Most of the agent's behaviour is spec-level DOM
// work (containing blocks, display:none) and is identical everywhere — but Mode
// B is built on `webkitEnterFullscreen`, which only exists in WebKit. Testing
// the app's highest-coverage playback mode in Chromium alone tested nothing.
export default defineConfig({
  testDir: './tests',
  // WebKit stalls a navigation once or twice in a full run — `page.goto` sits
  // until the test times out. Measured 23 September 2026: the tests that fail
  // pass in isolation every time, it is always WebKit, and it happens at a
  // steady two or three per 406 whether fixtures come from `page.route`
  // interception or a real HTTP server, and with one worker or eight. So it is
  // cumulative pressure on the browser rather than anything the fixtures do —
  // the earlier note here blaming route interception was wrong, and replacing
  // that interception changed the rate not at all.
  //
  // A retry starts a fresh page and reruns the whole assertion, so a stall
  // costs time rather than a false red. The real fix is to stop one WebKit
  // instance carrying 200 specs; see S3-14 in docs/FIX-LIST.md.
  retries: 1,
  use: { trace: 'on-first-retry' },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    { name: 'webkit', use: { ...devices['Desktop Safari'] } },
  ],
});
