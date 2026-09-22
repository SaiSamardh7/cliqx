import { test, expect, type Frame, type Page } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const AGENT = readFileSync(
  path.join(here, '..', 'ios', 'App', 'CleanPlayerApp', 'Resources', 'agent.js'), 'utf8');
const ORIGIN = 'https://hostile-frames.test';

async function loadDocument(target: Page | Frame, html = '<video></video>') {
  if ('route' in target) {
    await target.route(`${ORIGIN}/**`, (route) =>
      route.fulfill({ contentType: 'text/html', body: html }));
    await target.goto(`${ORIGIN}/watch`);
  }
  await target.evaluate(() => {
    (window as any).__posted = [];
    (window as any).webkit = {
      messageHandlers: {
        cp: { postMessage: (message: unknown) => (window as any).__posted.push(message) },
      },
    };
  });
  await target.addScriptTag({ content: AGENT });
}

const posted = (target: Page | Frame) =>
  target.evaluate(() => (window as any).__posted as Array<Record<string, unknown>>);

async function addHostileFrame(page: Page): Promise<Frame> {
  await page.evaluate(() => {
    const frame = document.createElement('iframe');
    frame.name = 'hostile-advertisement';
    frame.srcdoc = '<!doctype html><video></video>';
    document.body.appendChild(frame);
  });
  const handle = await page.waitForSelector('iframe[name="hostile-advertisement"]');
  const frame = await handle.contentFrame();
  if (!frame) throw new Error('hostile frame did not attach');
  await loadDocument(frame);
  return frame;
}

test.describe('hostile frame bridge fixtures', () => {
  // Authorization, decoding, and aggregation are asserted against the real
  // Swift boundary in HostileFrameTests. These browser cases prove each attack
  // fixture can actually be emitted by an independent document.
  test.beforeEach(({ page }) => loadDocument(page));

  test('an advertisement frame has a different identity when it claims theater', async ({ page }) => {
    const mainID = (await posted(page))[0].fid;
    const hostile = await addHostileFrame(page);
    const hostileID = (await posted(hostile))[0].fid;

    await hostile.evaluate((fid) =>
      (window as any).webkit.messageHandlers.cp.postMessage({
        v: 1, fid, type: 'theater', airplay: false, pip: false,
      }), hostileID);

    expect(hostileID).not.toBe(mainID);
    expect(await posted(hostile)).toContainEqual(expect.objectContaining({
      fid: hostileID, type: 'theater',
    }));
  });

  test('a spectator frame can attempt to forge ended', async ({ page }) => {
    const hostile = await addHostileFrame(page);
    const hostileID = (await posted(hostile))[0].fid;

    await hostile.evaluate((fid) =>
      (window as any).webkit.messageHandlers.cp.postMessage({ v: 1, fid, type: 'ended' }),
    hostileID);

    expect(await posted(hostile)).toContainEqual({ v: 1, fid: hostileID, type: 'ended' });
  });

  test('a frame can flood ten thousand blocked reports', async ({ page }) => {
    const hostile = await addHostileFrame(page);
    const hostileID = (await posted(hostile))[0].fid;

    await hostile.evaluate((fid) => {
      const bridge = (window as any).webkit.messageHandlers.cp;
      for (let index = 0; index < 10_000; index += 1) {
        bridge.postMessage({ v: 1, fid, type: 'blocked', count: index % 2 });
      }
    }, hostileID);

    expect((await posted(hostile)).filter((message) => message.type === 'blocked'))
      .toHaveLength(10_000);
  });

  test('a frame can deliver a one-megabyte string field', async ({ page }) => {
    const hostile = await addHostileFrame(page);
    const hostileID = (await posted(hostile))[0].fid;

    await hostile.evaluate((fid) =>
      (window as any).webkit.messageHandlers.cp.postMessage({
        v: 1, fid, type: 'airplay', available: true, source: 'x'.repeat(1_048_576),
      }), hostileID);

    const message = (await posted(hostile)).at(-1)!;
    expect((message.source as string).length).toBe(1_048_576);
  });

  test('a navigating frame retires the identity whose count native owns', async ({ page }) => {
    const hostile = await addHostileFrame(page);
    const hostileID = (await posted(hostile))[0].fid;

    await hostile.evaluate(() => dispatchEvent(new Event('pagehide')));

    expect(await posted(hostile)).toContainEqual({
      v: 1, fid: hostileID, type: 'frameGone',
    });
  });

  test('version fixtures target a real version-one frame identity', async ({ page }) => {
    const hostile = await addHostileFrame(page);
    const ready = (await posted(hostile))[0];

    expect(ready).toEqual(expect.objectContaining({ v: 1, fid: expect.any(String) }));
    const missing = { fid: ready.fid, type: 'blocked', count: 1 };
    const unknown = { v: 99, fid: ready.fid, type: 'blocked', count: 1 };
    expect(missing).not.toHaveProperty('v');
    expect(unknown.v).toBe(99);
  });
});

test.describe('insecure origins', () => {
  // A home server on the LAN is plain http, which is NOT a secure context:
  // `crypto.randomUUID` is undefined there. Calling it unguarded threw out of
  // the agent's IIFE, so window.__cp never existed and Watch clean, overlay
  // blocking and the whole bridge were missing on exactly the pages this app
  // exists for. Every other fixture here is https and saw none of it.
  const LAN = 'http://192.168.1.170:8096';

  test('the agent installs and identifies its frame over plain http',
    async ({ page }) => {
      await page.route(`${LAN}/**`, (route) =>
        route.fulfill({ contentType: 'text/html', body: '<video></video>' }));
      await page.goto(`${LAN}/web/`);
      expect(await page.evaluate(() => window.isSecureContext)).toBe(false);

      await page.evaluate(() => {
        (window as any).__posted = [];
        (window as any).webkit = {
          messageHandlers: {
            cp: { postMessage: (m: unknown) => (window as any).__posted.push(m) },
          },
        };
      });
      await page.addScriptTag({ content: AGENT });

      expect(await page.evaluate(() => typeof (window as any).__cp)).toBe('object');
      const ready = (await posted(page))[0];
      expect(ready).toMatchObject({ v: 1, type: 'ready' });
      expect(ready.fid).toMatch(
        /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
    });
});
