import { createServer, type Server } from 'node:http';
import { test, expect, type Page } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

// Proves the Android bridge shim on the engine Android WebView actually uses.
//
// Android WebView is Chromium, so a Chromium run exercises the same JavaScript
// the device will. Scripts go in through `addInitScript`, which runs before the
// page's own scripts — the closest Playwright equivalent to
// `WebViewCompat.addDocumentStartJavaScript`, and a stricter test than the
// `addScriptTag` the other specs use, because it catches an agent that depends
// on the DOM already existing.
//
// What this cannot cover is `addJavascriptInterface` itself, which is replaced
// by a stub of the same shape. Green here means "the shim and the agent agree",
// not "the APK works".
const here = path.dirname(fileURLToPath(import.meta.url));
const read = (...parts: string[]) =>
  readFileSync(path.join(here, '..', ...parts), 'utf8');

const SHIM = read('android', 'app', 'src', 'main', 'assets', 'bridge-shim.js');
const BOOTSTRAP = read('android', 'app', 'src', 'main', 'assets', 'agent-bootstrap.js');
const RAW_AGENT = read('ios', 'App', 'CleanPlayerApp', 'Resources', 'agent.js');
const POPUPGUARD = read('ios', 'App', 'CleanPlayerApp', 'Resources', 'popupguard.js');

// The exact substitution CliqxWebView performs, so these specs exercise the
// script the APK injects rather than something assembled differently here.
const PLACEHOLDER = '/*{{AGENT}}*/';
if (!BOOTSTRAP.includes(PLACEHOLDER)) {
  throw new Error(
    `agent-bootstrap.js has no ${PLACEHOLDER} marker; CliqxWebView would ` +
    'inject nothing and these specs would be testing a different script.');
}
const AGENT = BOOTSTRAP.replace(PLACEHOLDER, RAW_AGENT);

/** Stands in for the @JavascriptInterface object: same name, shape and arity. */
const NATIVE_STUB = `
  window.__cliqxReceived = [];
  window.__cliqxNative = { post: (s) => window.__cliqxReceived.push(s) };
`;

// A real origin rather than about:blank or a data: URL. Both of those leave
// `document.documentElement` null when a document-start script runs, which the
// agent does not survive; see android/README.md. A device loads real pages.
let ORIGIN = '';
let currentHtml = '';
let server: Server;

test.beforeAll(async () => {
  server = createServer((request, response) => {
    if (request.url === '/favicon.ico') {
      response.writeHead(404, { 'Content-Length': '0', Connection: 'close' });
      response.end();
      return;
    }
    const body = Buffer.from(currentHtml, 'utf8');
    response.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      'Content-Length': String(body.byteLength),
      Connection: 'close',
    });
    response.end(body);
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  if (address === null || typeof address === 'string') throw new Error('no port');
  ORIGIN = `http://127.0.0.1:${address.port}`;
});

test.afterAll(async () => {
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

/** Injects at document start, in the order the Android host injects them. */
async function serve(page: Page, html: string, scripts: string) {
  currentHtml = html;
  await page.addInitScript(scripts);
  await page.goto(`${ORIGIN}/watch`, { waitUntil: 'domcontentloaded' });
}

const received = (page: Page) =>
  page.evaluate(() => (window as any).__cliqxReceived ?? []);

test.describe('android bridge shim', () => {
  test.skip(({ browserName }) => browserName !== 'chromium',
    'Android WebView is Chromium; on WebKit the shim is intentionally inert.');

  test('the agent reaches a native stub through the shim', async ({ page }) => {
    await serve(page, '<video src="/v.mp4"></video>', NATIVE_STUB + SHIM + AGENT);

    await expect.poll(async () => (await received(page)).length).toBeGreaterThan(0);

    const payloads = (await received(page)).map((s: string) => JSON.parse(s));
    // Every payload must satisfy what BridgeMessage.kt will accept, or the
    // Kotlin decoder drops it and the app looks broken for no visible reason.
    for (const payload of payloads) {
      expect(payload.v, 'protocol version the Kotlin decoder requires').toBe(1);
      expect(typeof payload.type, 'type is a string').toBe('string');
      expect(typeof payload.fid, 'frame id travels with every message')
        .toBe('string');
    }
  });

  test('a document-start injection leaves the agent alive', async ({ page }) => {
    // The regression this exists for: injected at true document start, the
    // bare agent calls watchRoot(document.documentElement) with null, because
    // Chromium has not created <html> yet. WeakSet.add(null) throws, the IIFE
    // unwinds, and `window.__cp` is never assigned — every feature silently
    // absent. The bootstrap wrapper is what makes this pass.
    await serve(page, '<video src="/v.mp4"></video>', NATIVE_STUB + SHIM + AGENT);
    expect(await page.evaluate(() => typeof (window as any).__cp)).toBe('object');
  });

  test('the bare agent is what the bootstrap is protecting against', async ({ page }) => {
    // Pins the reason the wrapper exists. If a future agent.js survives
    // document-start on its own, this fails and the wrapper can be deleted.
    await serve(page, '<video src="/v.mp4"></video>', NATIVE_STUB + SHIM + RAW_AGENT);
    expect(await page.evaluate(() => typeof (window as any).__cp),
      'unwrapped agent still cannot start before <html> exists').toBe('undefined');
  });

  test('the agent still exposes the surface the Android host calls', async ({ page }) => {
    await serve(page, '<p>no video here</p>', NATIVE_STUB + SHIM + AGENT);

    // The names MainActivity calls through callAgent(), plus the ones the
    // player chrome needs next. A rename upstream fails here rather than at
    // runtime on a device.
    const missing = await page.evaluate(() => {
      const cp = (window as any).__cp;
      if (!cp) return ['__cp itself'];
      return ['streamCandidates', 'handoffCandidates', 'enterTheater',
              'exitTheater', 'togglePlay', 'seek', 'textTracks',
              'findEpisodes', 'blockOverlays', 'largestVideo', 'scan']
        .filter((name) => typeof cp[name] !== 'function');
    });
    expect(missing, 'agent surface the Android host depends on').toEqual([]);
  });

  test('popupguard reports a blocked popup through the shim', async ({ page }) => {
    await serve(page, '<p>page</p>', NATIVE_STUB + SHIM + AGENT + POPUPGUARD);

    // No real link activation, so this is exactly the popunder case.
    const stub = await page.evaluate(() => {
      const w = window.open('https://example.com/ad');
      return { closed: w?.closed, href: w?.location?.href };
    });
    // A dead stub rather than null, so page scripts keep running.
    expect(stub.closed, 'window.open returns a dead stub').toBe(true);
    expect(stub.href).toBe('');

    await expect.poll(async () =>
      (await received(page)).map((s: string) => JSON.parse(s).type),
    ).toContain('popupBlocked');
  });

  test('the shim does not clobber an existing webkit object', async ({ page }) => {
    await serve(page, '<p>page</p>',
      'window.webkit = { messageHandlers: { other: {} } };' + NATIVE_STUB + SHIM);

    const shape = await page.evaluate(() => ({
      keptOther: !!(window as any).webkit.messageHandlers.other,
      addedCp: typeof (window as any).webkit.messageHandlers.cp?.postMessage,
    }));
    expect(shape.keptOther, 'a page already using webkit.* keeps it').toBe(true);
    expect(shape.addedCp).toBe('function');
  });

  test('a missing native object degrades quietly', async ({ page }) => {
    // When the bridge fails to attach, the shim must define nothing: the
    // agent's own post() is optional-chained, so no bridge has to mean no
    // messages rather than an exception that takes window.__cp with it.
    await serve(page, '<video src="/v.mp4"></video>', SHIM + AGENT);

    expect(await page.evaluate(() => typeof (window as any).__cp),
      'agent survives an unattached bridge').toBe('object');
    expect(await page.evaluate(() => (window as any).webkit?.messageHandlers?.cp),
      'shim installs nothing without a native object').toBeUndefined();
  });

  test('a payload the Kotlin decoder rejects is never sent', async ({ page }) => {
    await serve(page, '<video src="/v.mp4"></video>', NATIVE_STUB + SHIM + AGENT);
    await expect.poll(async () => (await received(page)).length).toBeGreaterThan(0);

    // Mirrors BridgeMessage.MAX_STRING_LENGTH and the finite-number checks.
    for (const raw of await received(page)) {
      expect(raw.length).toBeLessThanOrEqual(1 << 20);
      const payload = JSON.parse(raw);
      for (const [key, value] of Object.entries(payload)) {
        if (typeof value === 'number') {
          expect(Number.isFinite(value), `${key} is finite`).toBe(true);
        }
        if (typeof value === 'string') {
          expect(value.length, `${key} within string limit`)
            .toBeLessThanOrEqual(2048);
        }
      }
    }
  });
});
