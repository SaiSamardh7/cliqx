import { defineConfig, devices } from '@playwright/test';

// Both engines, deliberately. Most of the agent's behaviour is spec-level DOM
// work (containing blocks, display:none) and is identical everywhere — but Mode
// B is built on `webkitEnterFullscreen`, which only exists in WebKit. Testing
// the app's highest-coverage playback mode in Chromium alone tested nothing.
export default defineConfig({
  testDir: './tests',
  // Long WebKit runs occasionally lose a synthetic route during navigation.
  // A retry starts a fresh page and still reruns the complete assertion.
  retries: 1,
  use: { trace: 'on-first-retry' },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    { name: 'webkit', use: { ...devices['Desktop Safari'] } },
  ],
});
