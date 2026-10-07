import { createServer, type Server } from 'node:http';
import { test, expect, type Page } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const AGENT = readFileSync(
  path.join(here, '..', 'ios', 'App', 'CleanPlayerApp', 'Resources', 'agent.js'), 'utf8');

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

async function serve(page: Page, html: string) {
  currentHtml = html;
  await page.goto(`${ORIGIN}/watch`, { waitUntil: 'domcontentloaded' });
  await page.evaluate(() => {
    (window as any).__posted = [];
    (window as any).webkit = {
      messageHandlers: { cp: { postMessage: (m: any) => (window as any).__posted.push(m) } },
    };
  });
  await page.addScriptTag({ content: AGENT });
}

/// "<videos found>/<Watch clean controls offered>".
///
/// Counted with a walk that crosses shadow boundaries, because
/// `document.querySelectorAll` does not — and a button attached inside a
/// shadow root is exactly what is being checked. Only the PRIMARY button is
/// counted: WebKit also gets the "Open in the system player" one, since it is
/// the engine that has `webkitEnterFullscreen`, and counting both would make
/// these assertions mean something different per engine.
const buttons = (page: Page) =>
  page.evaluate(() => {
    const count = (root: DocumentFragment | Document): number => {
      let n = root.querySelectorAll('.__cp_btn:not([data-cp-secondary])').length;
      for (const el of root.querySelectorAll('*')) {
        if (el.shadowRoot) n += count(el.shadowRoot);
      }
      return n;
    };
    return __cp.allVideos().length + '/' + count(document);
  });

test.describe('finding the video', () => {
  test('a player that is laid out only after load still gets a button', async ({ page }) => {
    await serve(page, `<!doctype html><meta charset="utf-8">
      <div id="host"><video id="v" style="width:0;height:0"></video></div>`);
    expect(await buttons(page)).toBe('1/0');          // boxless: nothing offered
    await page.evaluate(() => {
      const v = document.getElementById('v') as HTMLVideoElement;
      v.style.width = '320px';
      v.style.height = '180px';
    });
    await expect.poll(() => buttons(page), { timeout: 4000 }).toBe('1/1');
  });

  test('a portrait player is not mistaken for a thumbnail', async ({ page }) => {
    await serve(page, `<!doctype html><meta charset="utf-8">
      <video id="v" style="width:300px;height:534px"></video>`);
    await page.evaluate(() => __cp.scan());
    expect(await buttons(page)).toBe('1/1');
  });

  test('a player inside a dialog is found', async ({ page }) => {
    await serve(page, `<!doctype html><meta charset="utf-8">
      <dialog id="d" open><video id="v" style="width:320px;height:180px"></video></dialog>`);
    await page.evaluate(() => __cp.scan());
    expect(await buttons(page)).toBe('1/1');
  });

  // Attaching a shadow root to an element already in the document mutates
  // NOTHING in the light tree, and a MutationObserver does not cross the
  // boundary — so nothing schedules a pass and the player is found by the
  // walk but never offered a button.
  //
  // `settle` matters. This suite injects the agent with `addScriptTag`, which
  // appends a <script> and so schedules a pass of its own; that pass lands
  // after the root is built and hides the fault. The app injects a
  // WKUserScript at documentStart and adds no element, so it has no such
  // pass. Without the wait these tests pass against a broken agent.
  const settle = (page: Page) => page.waitForTimeout(1200);

  const mountInShadowRoot = (page: Page) => page.evaluate(() => {
    const root = document.getElementById('host')!.attachShadow({ mode: 'open' });
    const v = document.createElement('video');
    v.style.width = '320px';
    v.style.height = '180px';
    root.appendChild(v);
  });

  test('a player mounted into a shadow root after load is found', async ({ page }) => {
    await serve(page, `<!doctype html><meta charset="utf-8"><div id="host"></div>`);
    await settle(page);
    await mountInShadowRoot(page);
    await expect.poll(() => buttons(page), { timeout: 5000 }).toBe('1/1');
  });

  test('a player mounted into a shadow root is found with blocking off too',
    async ({ page }) => {
      await serve(page, `<!doctype html><meta charset="utf-8"><div id="host"></div>`);
      await page.evaluate(() => __cp.setOverlayBlocking(false));
      await settle(page);
      await mountInShadowRoot(page);
      await expect.poll(() => buttons(page), { timeout: 5000 }).toBe('1/1');
    });

  test('resuming does not stage an advertisement that is bigger than the player',
    async ({ page }) => {
      await serve(page, `<!doctype html><meta charset="utf-8">
        <video id="ad" style="width:640px;height:480px"></video>
        <video id="player" src="/movie.mp4" style="width:400px;height:225px"></video>`);
      const staged = await page.evaluate(() => {
        const v = __cp.resumeCandidate(9999) as HTMLVideoElement | null;
        return v ? v.id : 'none';
      });
      expect(staged).toBe('player');
    });
});
