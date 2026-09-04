import { test, expect, type Page } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const POPUPGUARD = readFileSync(
  path.join(here, '..', 'ios', 'App', 'CleanPlayerApp', 'Resources', 'popupguard.js'), 'utf8');
const AGENT = readFileSync(
  path.join(here, '..', 'ios', 'App', 'CleanPlayerApp', 'Resources', 'agent.js'), 'utf8');

const ORIGIN = 'https://example.test';

const HEAD = `<!doctype html>
<meta charset="utf-8">
<style>
  body { margin: 0; }
  .rail { background: #ccc; height: 80px; }
  .trap { transform: translateZ(0); overflow: hidden;
          width: 300px; height: 200px; position: relative; }
  video { width: 300px; height: 200px; background: #333; }
  .overlay { position: absolute; inset: 0; z-index: 9999; background: rgba(255,0,0,.4); }
</style>`;

// The three things that actually break theater on real sites: a transformed
// ancestor (traps position:fixed), a clipping ancestor, and a <form> wrapper.
const PLAYER = `${HEAD}
<div class="rail" id="ad-top">AD</div>
<form id="wrapper" action="/submitted" method="get">
  <div class="trap" id="trap">
    <video id="v" playsinline></video>
    <div class="overlay" id="overlay"></div>
  </div>
</form>
<div class="rail" id="ad-bottom">AD</div>
<script>
  window.__submitted = false;
  document.getElementById('wrapper')
    .addEventListener('submit', (e) => { e.preventDefault(); window.__submitted = true; });
</script>`;

/// Stands in for the WKScriptMessageHandler bridge so the payloads the native
/// chrome depends on are actually asserted.
async function serve(page: Page, html: string, at = `${ORIGIN}/ep/1`) {
  await page.route(`${ORIGIN}/**`, (route) =>
    route.fulfill({ contentType: 'text/html', body: html }));
  await page.goto(at);
  await page.addInitScript(() => {});
  await page.evaluate(() => {
    (window as any).__posted = [];
    (window as any).webkit = {
      messageHandlers: { cp: { postMessage: (m: any) => (window as any).__posted.push(m) } },
    };
  });
  await page.addScriptTag({ content: AGENT });
}

const watchClean = (page: Page) => page.getByRole('button', { name: 'Watch clean' });
const posted = (page: Page) => page.evaluate(() => (window as any).__posted);

test.describe('theater mode', () => {
  test.beforeEach(({ page }) => serve(page, PLAYER));

  test('attaches exactly one button no matter how often the observer fires', async ({ page }) => {
    await page.evaluate(() => { __cp.scan(); __cp.scan(); __cp.scan(); });
    await expect(watchClean(page)).toHaveCount(1);
  });

  test('button click does not submit the surrounding form', async ({ page }) => {
    await watchClean(page).click();
    expect(await page.evaluate(() => window.__submitted)).toBe(false);
  });

  test('escapes a transformed, clipping ancestor', async ({ page }) => {
    expect((await page.locator('#v').boundingBox())!.width).toBeCloseTo(300, 0);
    await watchClean(page).click();

    const viewport = page.viewportSize()!;
    const after = await page.locator('#v').boundingBox();
    expect(after!.width).toBeCloseTo(viewport.width, 0);
    expect(after!.height).toBeCloseTo(viewport.height, 0);
  });

  test('hides page chrome', async ({ page }) => {
    await watchClean(page).click();
    await expect(page.locator('#ad-top')).toBeHidden();
    await expect(page.locator('#ad-bottom')).toBeHidden();
    await expect(page.locator('#overlay')).toBeHidden();
  });

  // Found on commons.wikimedia.org: the player swaps the <video> out after it
  // initialises, leaving the button holding a detached node.
  test('recovers when the page swaps the video element after load', async ({ page }) => {
    await watchClean(page).waitFor();
    await page.evaluate(() => {
      const fresh = document.createElement('video');
      fresh.id = 'v2';
      document.querySelector('#v')!.replaceWith(fresh);
    });

    await expect(watchClean(page)).toHaveCount(1);   // orphan swept, not stacked
    await watchClean(page).click();
    await expect(page.locator('#v2')).toHaveAttribute('data-cp-stage', '1');
  });

  // Regression: the guard used to be a boolean on the video, so once anything
  // removed the button the video stayed marked as done. Every button on the
  // page vanished and never came back.
  test('re-attaches the button if the page removes it', async ({ page }) => {
    await watchClean(page).waitFor();
    // Removal and re-attach are asserted in one step: the MutationObserver
    // heals this so quickly on WebKit that no observer ever sees zero buttons.
    // The invariant that matters is that a scan restores exactly one — the old
    // boolean guard left the video marked done and restored none.
    await page.evaluate(() => {
      document.querySelector('.__cp_btn')!.remove();
      __cp.scan();
    });
    await expect(watchClean(page)).toHaveCount(1);
  });

  test('ignores thumbnail-sized videos', async ({ page }) => {
    await page.evaluate(() => {
      const thumb = document.createElement('video');
      thumb.id = 'thumb';
      thumb.style.cssText = 'width:80px;height:45px';
      document.body.appendChild(thumb);
      __cp.scan();
    });
    expect(await page.evaluate(() =>
      !!(document.getElementById('thumb') as any).__cpBtn)).toBe(false);
  });

  test('exit restores the page exactly as it was', async ({ page }) => {
    await watchClean(page).click();
    await page.evaluate(() => __cp.exitTheater());

    await expect(page.locator('#ad-top')).toBeVisible();
    expect((await page.locator('#v').boundingBox())!.width).toBeCloseTo(300, 0);
    expect(await page.evaluate(() => __cp.isTheater())).toBe(false);
  });

  // The native chrome only appears because of these messages.
  test('reports theater start and end to the native bridge', async ({ page }) => {
    await watchClean(page).click();
    expect(await posted(page)).toContainEqual(
      expect.objectContaining({ type: 'theater' }));

    await page.evaluate(() => __cp.exitTheater());
    expect(await posted(page)).toContainEqual({ type: 'theaterEnded' });
  });
});

test.describe('episode discovery', () => {
  test('hides nothing when the page offers no episode links', async ({ page }) => {
    await serve(page, PLAYER);
    expect(await page.evaluate(() => __cp.findEpisodes()))
      .toEqual({ next: null, prev: null });
  });

  test('prefers rel=next and rel=prev over link text', async ({ page }) => {
    await serve(page, `${HEAD}
      <link rel="next" href="/ep/2">
      <link rel="prev" href="/ep/0">
      <a href="/decoy">Next thing entirely</a>
      <video id="v" playsinline></video>`);

    expect(await page.evaluate(() => __cp.findEpisodes())).toEqual({
      next: `${ORIGIN}/ep/2`, prev: `${ORIGIN}/ep/0`,
    });
  });

  test('falls back to accessible names', async ({ page }) => {
    await serve(page, `${HEAD}
      <a href="/ep/0">Previous Episode</a>
      <a href="/ep/2" aria-label="Next episode">&rarr;</a>
      <video id="v" playsinline></video>`);

    expect(await page.evaluate(() => __cp.findEpisodes())).toEqual({
      next: `${ORIGIN}/ep/2`, prev: `${ORIGIN}/ep/0`,
    });
  });

  test('never follows an episode link off-origin', async ({ page }) => {
    await serve(page, `${HEAD}
      <a href="https://elsewhere.test/ep/2">Next episode</a>
      <video id="v" playsinline></video>`);

    expect(await page.evaluate(() => __cp.findEpisodes().next)).toBeNull();
  });

  test('ignores a self-link', async ({ page }) => {
    await serve(page, `${HEAD}
      <a href="/ep/1">Next episode</a>
      <video id="v" playsinline></video>`);

    expect(await page.evaluate(() => __cp.findEpisodes().next)).toBeNull();
  });
});

test.describe('AirPlay', () => {
  // Availability is not the same thing as support. No engine under test has a
  // real route, so nothing is ever *available* — but WebKit ships
  // webkitShowPlaybackTargetPicker and Chromium does not, so only WebKit can
  // open the picker at all. Asserting false for both only tested Chromium.
  test('stays unavailable until a route is reported', async ({ page }) => {
    await serve(page, PLAYER);
    await watchClean(page).click();

    const theater = (await posted(page)).find((m: any) => m.type === 'theater');
    expect(theater.airplay).toBe(false);
  });

  test('can only open the picker where the engine has one', async ({ page, browserName }) => {
    await serve(page, PLAYER);
    await watchClean(page).click();

    expect(await page.evaluate(() => __cp.showAirPlay()))
      .toBe(browserName === 'webkit');
  });

  test('reports availability changes and opens the picker', async ({ page }) => {
    await serve(page, PLAYER);
    await page.evaluate(() => {
      const v = document.querySelector('video')! as any;
      v.webkitShowPlaybackTargetPicker = () => { (window as any).__picked = true; };
    });
    await watchClean(page).click();

    await page.evaluate(() => {
      const e: any = new Event('webkitplaybacktargetavailabilitychanged');
      e.availability = 'available';
      document.querySelector('video')!.dispatchEvent(e);
    });

    expect(await posted(page)).toContainEqual({ type: 'airplay', available: true });
    expect(await page.evaluate(() => __cp.showAirPlay())).toBe(true);
    expect(await page.evaluate(() => (window as any).__picked)).toBe(true);
  });
});

test.describe('mode selection', () => {
  // Regression: watchClean used to prefer Mode B whenever the video was
  // decodable, which is the normal case on a real streaming site. Mode B hands
  // the screen to Apple's player, which has no next/previous episode, so the
  // native control bar never appeared exactly where it was needed.
  test('Watch clean always stages in-page, even when fullscreen is available',
    async ({ page }) => {
      await serve(page, PLAYER);
      await page.evaluate(() => {
        const v = document.querySelector('video')! as any;
        v.webkitEnterFullscreen = () => { (window as any).__wentFullscreen = true; };
        Object.defineProperty(v, 'readyState', { get: () => 4 });
        Object.defineProperty(v, 'videoWidth', { get: () => 1280 });
      });

      await page.getByRole('button', { name: 'Watch clean' }).click();

      expect(await page.evaluate(() => (window as any).__wentFullscreen)).toBeUndefined();
      expect(await page.evaluate(() => __cp.isTheater())).toBe(true);
      expect(await posted(page)).toContainEqual(
        expect.objectContaining({ type: 'theater' }));
    });

  // Mode B is the app's highest-coverage playback mode and rests entirely on
  // webkitEnterFullscreen, which exists in WebKit and not in Chromium. The
  // button must follow the platform rather than always being offered.
  test('offers the system player exactly where the platform supports it',
    async ({ page, browserName }) => {
      await serve(page, PLAYER);
      await expect(
        page.getByRole('button', { name: 'Open in the system player' })
      ).toHaveCount(browserName === 'webkit' ? 1 : 0);
    });

  test('the system player button uses Mode B, not theater', async ({ page }) => {
    await serve(page, PLAYER);
    await page.evaluate(() => {
      const v = document.querySelector('video')! as any;
      v.webkitEnterFullscreen = () => { (window as any).__wentFullscreen = true; };
      Object.defineProperty(v, 'readyState', { get: () => 4 });
      Object.defineProperty(v, 'videoWidth', { get: () => 1280 });
      __cp.scan();
    });

    expect(await page.evaluate(() => __cp.nativeFullscreen(
      document.querySelector('video')!))).toBe(true);
    expect(await page.evaluate(() => (window as any).__wentFullscreen)).toBe(true);
    expect(await page.evaluate(() => __cp.isTheater())).toBe(false);
  });
});

test.describe('playback control', () => {
  // The bug this closes: theater hides the page, and the page is where the
  // player's own play button is. Staging a paused video left a black screen
  // with a close button and no way at all to start watching.
  test('Watch clean starts a paused video', async ({ page }) => {
    await serve(page, PLAYER);
    await page.evaluate(() => {
      const v = document.querySelector('video')! as any;
      (window as any).__played = false;
      v.play = () => { (window as any).__played = true; return Promise.resolve(); };
    });

    await watchClean(page).click();
    expect(await page.evaluate(() => (window as any).__played)).toBe(true);
  });

  test('reports playback state so the native bar can show play or pause',
    async ({ page }) => {
      await serve(page, PLAYER);
      await watchClean(page).click();

      // Staging reports immediately; the fixture video is paused.
      expect(await posted(page)).toContainEqual(
        expect.objectContaining({ type: 'playback' }));

      await page.evaluate(() => document.querySelector('video')!.dispatchEvent(new Event('play')));
      expect(await posted(page)).toContainEqual({ type: 'playback', playing: true });
    });

  test('togglePlay drives the staged video both ways', async ({ page }) => {
    await serve(page, PLAYER);
    await page.evaluate(() => {
      const v = document.querySelector('video')! as any;
      (window as any).__calls = [];
      v.play = () => { (window as any).__calls.push('play'); return Promise.resolve(); };
      v.pause = () => { (window as any).__calls.push('pause'); };
    });
    await watchClean(page).click();

    await page.evaluate(() => {
      const v = document.querySelector('video')! as any;
      Object.defineProperty(v, 'paused', { get: () => true, configurable: true });
      __cp.togglePlay();
      Object.defineProperty(v, 'paused', { get: () => false, configurable: true });
      __cp.togglePlay();
    });

    expect(await page.evaluate(() => (window as any).__calls))
      .toEqual(expect.arrayContaining(['play', 'pause']));
  });

  test('togglePlay does nothing when no video is staged', async ({ page }) => {
    await serve(page, PLAYER);
    expect(await page.evaluate(() => __cp.togglePlay())).toBe(false);
  });
});

test.describe('frame announcement', () => {
  // Resuming theater after an episode change has to run in the frame holding
  // the video, and on these sites that is a cross-origin iframe. The main frame
  // has no <video> at all, so evaluateJavaScript(in: nil) was asking the wrong
  // document and theater never came back. Each frame now announces itself so
  // native can address it directly.
  test('announces itself once so native can address the frame', async ({ page }) => {
    await serve(page, PLAYER);
    const ready = (await posted(page)).filter((m: any) => m.type === 'ready');
    expect(ready).toHaveLength(1);
  });

  test('autoTheater stages the video in the frame it runs in', async ({ page }) => {
    await serve(page, PLAYER);
    expect(await page.evaluate(() => __cp.autoTheater())).toBe(true);
    expect(await page.evaluate(() => __cp.isTheater())).toBe(true);
  });

  test('autoTheater gives up rather than hanging when there is no video',
    async ({ page }) => {
      await serve(page, `${HEAD}<div id="only">no video here</div>`);
      expect(await page.evaluate(() => __cp.autoTheater(150))).toBe(false);
    });
});

// The episode-change path. Entering theater by hand happens inside a tap, so
// watchClean can rely on the gesture to start playback; resume has no gesture
// and no page the user is looking at, so it has to do both jobs itself.
test.describe('resuming theater after an episode change', () => {
  test('starts playback, so the next episode does not land paused',
    async ({ page }) => {
      await serve(page, PLAYER);
      await page.evaluate(() => {
        const v = document.querySelector('video')! as any;
        v.__played = 0;
        Object.defineProperty(v, 'paused', { get: () => true, configurable: true });
        v.play = () => { v.__played++; return Promise.resolve(); };
      });
      expect(await page.evaluate(() => __cp.autoTheater())).toBe(true);
      expect(await page.evaluate(() => (document.querySelector('video') as any).__played))
        .toBe(1);
    });

  test('tells native when it gives up, so the curtain comes down',
    async ({ page }) => {
      await serve(page, `${HEAD}<div id="only">no video here</div>`);
      await page.evaluate(() => __cp.autoTheater(150));
      expect((await posted(page)).filter((m: any) => m.type === 'theaterFailed'))
        .toHaveLength(1);
    });

  test('says nothing when it succeeds', async ({ page }) => {
    await serve(page, PLAYER);
    await page.evaluate(() => {
      (document.querySelector('video')! as any).play = () => Promise.resolve();
    });
    await page.evaluate(() => __cp.autoTheater());
    expect((await posted(page)).filter((m: any) => m.type === 'theaterFailed'))
      .toHaveLength(0);
  });

  // A player that has not been laid out reports 0x0. Requiring a box meant the
  // poll walked past the video it was armed for and timed out on exactly the
  // page it existed to handle.
  test('a sized video always wins, however long it has been waiting',
    async ({ page }) => {
      await serve(page, `${HEAD}
        <video id="hidden" style="width:0;height:0" src="/a.mp4"></video>
        <div class="trap"><video id="real" playsinline src="/b.mp4"></video></div>`);
      expect(await page.evaluate(() => __cp.resumeCandidate(9999)!.id)).toBe('real');
    });

  test('a boxless video is refused during the grace period', async ({ page }) => {
    await serve(page, `${HEAD}<video id="v" style="width:0;height:0" src="/a.mp4"></video>`);
    expect(await page.evaluate(() => __cp.resumeCandidate(0))).toBe(null);
  });

  test('and accepted once the grace period is over', async ({ page }) => {
    await serve(page, `${HEAD}<video id="v" style="width:0;height:0" src="/a.mp4"></video>`);
    expect(await page.evaluate(() => __cp.resumeCandidate(9999)!.id)).toBe('v');
  });

  // Otherwise the fallback stages whatever <video> the page happens to hold —
  // a hidden preload element, or a thumbnail — and calls it the episode.
  test('never accepts a video with nothing to play', async ({ page }) => {
    await serve(page, `${HEAD}<video id="empty" style="width:0;height:0"></video>`);
    expect(await page.evaluate(() => __cp.resumeCandidate(9999))).toBe(null);
  });
});

test.describe('buttons created while theater is already showing', () => {
  // Resume stages the video as soon as it finds one, which can be before the
  // page has mounted its own player. stage() marks the buttons that exist when
  // it runs, so anything attached afterwards landed on top of the video.
  test('a button attached after staging is hidden too', async ({ page }) => {
    await serve(page, PLAYER);
    await page.evaluate(() => {
      const v = document.querySelector('video')! as any;
      v.play = () => Promise.resolve();
      __cp.enterTheater(v);
      // Whatever removes a button — the orphan sweep, the page's own re-render
      // — the next scan puts one back.
      document.querySelectorAll('.__cp_btn').forEach((b) => b.remove());
      delete v.__cpBtn;
      __cp.scan();
    });
    const fresh = page.getByRole('button', { name: 'Watch clean' });
    await expect(fresh).toBeHidden();
  });

  test('and is shown again once theater ends', async ({ page }) => {
    await serve(page, PLAYER);
    await page.evaluate(() => {
      const v = document.querySelector('video')! as any;
      v.play = () => Promise.resolve();
      __cp.enterTheater(v);
      document.querySelectorAll('.__cp_btn').forEach((b) => b.remove());
      delete v.__cpBtn;
      __cp.scan();
      __cp.exitTheater();
    });
    await expect(page.getByRole('button', { name: 'Watch clean' })).toBeVisible();
  });
});

test.describe('end of playback', () => {
  async function endedPlayer(page: Page) {
    await serve(page, PLAYER);
    await page.evaluate(() => {
      (document.querySelector('video')! as any).play = () => Promise.resolve();
    });
    await watchClean(page).click();
  }

  test('reports ending, so the player can offer the next episode',
    async ({ page }) => {
      await endedPlayer(page);
      await page.evaluate(() =>
        document.querySelector('video')!.dispatchEvent(new Event('ended')));
      expect((await posted(page)).filter((m: any) => m.type === 'ended'))
        .toHaveLength(1);
    });

  // An ordinary pause must not offer the next episode. Only `ended` does.
  test('a pause partway through is not an ending', async ({ page }) => {
    await endedPlayer(page);
    await page.evaluate(() =>
      document.querySelector('video')!.dispatchEvent(new Event('pause')));
    expect((await posted(page)).filter((m: any) => m.type === 'ended')).toHaveLength(0);
  });

  test('stops reporting once theater is left', async ({ page }) => {
    await endedPlayer(page);
    await page.evaluate(() => __cp.exitTheater());
    await page.evaluate(() =>
      document.querySelector('video')!.dispatchEvent(new Event('ended')));
    expect((await posted(page)).filter((m: any) => m.type === 'ended')).toHaveLength(0);
  });
});

test.describe('the blocker must not eat the video', () => {
  // The bug this closes, found by instrumenting a real device: theater staged
  // the video, then the next overlay pass hid it. A staged video matches every
  // test looksLikeInterstitial applies — position:fixed, full-screen, opaque
  // background (staging sets it), topmost at its own centre by definition — so
  // it was decoded, playing, and display:none.
  test('a staged video survives an overlay pass', async ({ page }) => {
    await serve(page, PLAYER);
    await watchClean(page).click();
    await page.evaluate(() => __cp.blockOverlays());

    const state = await page.evaluate(() => {
      const v = document.querySelector('video')!;
      return { display: getComputedStyle(v).display,
               blocked: v.hasAttribute('data-cp-blocked'),
               staged: v.hasAttribute('data-cp-stage') };
    });
    expect(state).toEqual({ display: 'block', blocked: false, staged: true });
  });

  // Repeated passes are what actually happens: the observer fires on every
  // mutation the player makes while it plays.
  test('and survives repeated passes', async ({ page }) => {
    await serve(page, PLAYER);
    await watchClean(page).click();
    await page.evaluate(() => { for (let i = 0; i < 5; i++) __cp.blockOverlays(); });

    await expect(page.locator('video')).toBeVisible();
  });

  // A plain video outside theater is not an interstitial either.
  test('never hides a video element at all', async ({ page }) => {
    await serve(page, PLAYER);
    await page.evaluate(() => {
      const v = document.querySelector('video')! as HTMLElement;
      v.style.cssText = 'position:fixed;inset:0;width:100%;height:100%;background:#000';
      __cp.blockOverlays();
    });
    expect(await page.evaluate(() =>
      document.querySelector('video')!.hasAttribute('data-cp-blocked'))).toBe(false);
  });

  // The overlay blocker still has to work, or this fix traded one hole for
  // another.
  test('still hides a real interstitial over the staged video', async ({ page }) => {
    await serve(page, PLAYER);
    await watchClean(page).click();
    await page.evaluate(() => {
      const gate = document.createElement('div');
      gate.id = 'gate';
      gate.style.cssText = 'position:fixed;inset:0;z-index:2147483647;background:#fff';
      document.body.appendChild(gate);
      __cp.blockOverlays();
    });

    await expect(page.locator('#gate')).toBeHidden();
    await expect(page.locator('video')).toBeVisible();
  });
});

test.describe('inline playback', () => {
  // The bug this closes: on iOS a <video> without playsinline can only render
  // in the platform's fullscreen player. Theater refuses fullscreen — it is
  // already full screen — so the two together gave playback with no picture:
  // audio running, scrubber advancing, black screen.
  test('marks the staged video as playable inline', async ({ page }) => {
    await serve(page, PLAYER);
    await watchClean(page).click();

    const attrs = await page.evaluate(() => {
      const v = document.querySelector('video')!;
      return { inline: v.hasAttribute('playsinline'),
               webkit: v.hasAttribute('webkit-playsinline') };
    });
    expect(attrs).toEqual({ inline: true, webkit: true });
  });

  test('takes back only what it added', async ({ page }) => {
    await serve(page, `${HEAD}
      <video id="v" playsinline style="width:360px;height:200px"></video>`);
    await page.evaluate(() => __cp.enterTheater(document.querySelector('video')!));
    await page.evaluate(() => __cp.exitTheater());

    // The page set playsinline itself, so it survives; webkit-playsinline was
    // ours and goes.
    expect(await page.evaluate(() => {
      const v = document.querySelector('video')!;
      return { inline: v.hasAttribute('playsinline'),
               webkit: v.hasAttribute('webkit-playsinline') };
    })).toEqual({ inline: true, webkit: false });
  });

  test('leaves nothing behind on a video that had neither', async ({ page }) => {
    await serve(page, `${HEAD}
      <video id="v" style="width:360px;height:200px"></video>`);
    await page.evaluate(() => __cp.enterTheater(document.querySelector('video')!));
    await page.evaluate(() => __cp.exitTheater());

    expect(await page.evaluate(() => {
      const v = document.querySelector('video')!;
      return v.hasAttribute('playsinline') || v.hasAttribute('webkit-playsinline');
    })).toBe(false);
  });
});

test.describe('episode neighbours', () => {
  // aniwave draws Prev and Next in its own player bar with JavaScript: no rel
  // attribute, no anchor, and no "next" text anywhere in the DOM. The buttons
  // were not broken — they were never populated. The episode list is right
  // there as ordinary links, so the neighbours come from that.
  const LIST = (current: number) => `${HEAD}
    <video id="v" playsinline style="width:360px;height:200px"></video>
    <div id="eps">
      ${[1, 2, 3, 4].map(n => `<a href="${ORIGIN}/ep-${n}">${n}</a>`).join('')}
    </div>
    <script>history.replaceState(null, '', '${ORIGIN}/ep-${current}');<\/script>`;

  test('finds the neighbours with no rel, anchor name or next text',
    async ({ page }) => {
      await serve(page, LIST(2), `${ORIGIN}/ep-2`);
      const found = await page.evaluate(() => __cp.findEpisodes());
      expect(found.prev).toBe(`${ORIGIN}/ep-1`);
      expect(found.next).toBe(`${ORIGIN}/ep-3`);
    });

  test('offers no previous on the first episode', async ({ page }) => {
    await serve(page, LIST(1), `${ORIGIN}/ep-1`);
    const found = await page.evaluate(() => __cp.findEpisodes());
    expect(found.prev).toBeNull();
    expect(found.next).toBe(`${ORIGIN}/ep-2`);
  });

  test('offers no next on the last episode', async ({ page }) => {
    await serve(page, LIST(4), `${ORIGIN}/ep-4`);
    const found = await page.evaluate(() => __cp.findEpisodes());
    expect(found.next).toBeNull();
    expect(found.prev).toBe(`${ORIGIN}/ep-3`);
  });

  // A site listing newest-first would otherwise hand back reversed neighbours.
  test('orders by episode number, not DOM order', async ({ page }) => {
    await serve(page, `${HEAD}
      <video id="v" playsinline style="width:360px;height:200px"></video>
      ${[4, 3, 2, 1].map(n => `<a href="${ORIGIN}/ep-${n}">${n}</a>`).join('')}`,
      `${ORIGIN}/ep-2`);
    const found = await page.evaluate(() => __cp.findEpisodes());
    expect(found.prev).toBe(`${ORIGIN}/ep-1`);
    expect(found.next).toBe(`${ORIGIN}/ep-3`);
  });

  // rel is authoritative where a site provides it.
  test('prefers an explicit rel over the list', async ({ page }) => {
    await serve(page, `${HEAD}
      <video id="v" playsinline style="width:360px;height:200px"></video>
      <a rel="next" href="${ORIGIN}/special">Continue</a>
      ${[1, 2, 3].map(n => `<a href="${ORIGIN}/ep-${n}">${n}</a>`).join('')}`,
      `${ORIGIN}/ep-2`);
    const found = await page.evaluate(() => __cp.findEpisodes());
    expect(found.next).toBe(`${ORIGIN}/special`);
    expect(found.prev).toBe(`${ORIGIN}/ep-1`);
  });

  // sameOriginHref rejects self-links, which is right for "next episode" and
  // wrong for the list: without the current entry the picker could never show
  // where you are, and the neighbours had nothing to measure from.
  test('keeps the current episode in the list, and marks it', async ({ page }) => {
    await serve(page, LIST(2), `${ORIGIN}/ep-2`);
    const list = await page.evaluate(() => __cp.episodeList());
    expect(list.map((e: any) => e.label)).toEqual(['1', '2', '3', '4']);
    expect(list.filter((e: any) => e.current).map((e: any) => e.label)).toEqual(['2']);
  });

  test('still refuses a self-link as a next episode', async ({ page }) => {
    await serve(page, `${HEAD}
      <video id="v" playsinline style="width:360px;height:200px"></video>
      <a rel="next" href="${ORIGIN}/ep-2">Next</a>`, `${ORIGIN}/ep-2`);
    expect(await page.evaluate(() => __cp.findEpisodes().next)).toBeNull();
  });

  test('stays empty on a page with no episodes at all', async ({ page }) => {
    await serve(page, PLAYER);
    const found = await page.evaluate(() => __cp.findEpisodes());
    expect(found.next).toBeNull();
    expect(found.prev).toBeNull();
  });
});

test.describe('page-initiated fullscreen', () => {
  // WebKit element fullscreen renders above the app's own views, so a page that
  // calls requestFullscreen when playback starts hides the native player chrome
  // entirely — no controls, no status bar. Several mobile players do this on
  // play, and Watch clean starts playback.
  async function guarded(page: Page) {
    await serve(page, PLAYER);
    // The stub stands in for the page's own implementation, so it has to be in
    // place BEFORE the guard wraps it — popupguard installs once and returns
    // early on a second run, exactly as it does in the app.
    await page.evaluate(() => {
      (window as any).__wentFullscreen = 0;
      Element.prototype.requestFullscreen = function () {
        (window as any).__wentFullscreen++;
        return Promise.resolve();
      };
    });
    await page.addScriptTag({ content: POPUPGUARD });
  }

  test('lets the page go fullscreen when theater is not showing', async ({ page }) => {
    await guarded(page);
    await page.evaluate(() => document.querySelector('video')!.requestFullscreen());
    expect(await page.evaluate(() => (window as any).__wentFullscreen)).toBe(1);
  });

  test('refuses fullscreen while theater is showing', async ({ page }) => {
    await guarded(page);
    await page.evaluate(() => {
      document.documentElement.dataset.cpTheater = '1';
      document.querySelector('video')!.requestFullscreen();
    });
    expect(await page.evaluate(() => (window as any).__wentFullscreen)).toBe(0);
  });

  test('gives fullscreen back when theater ends', async ({ page }) => {
    await guarded(page);
    await page.evaluate(() => {
      document.documentElement.dataset.cpTheater = '1';
      document.querySelector('video')!.requestFullscreen();
      delete document.documentElement.dataset.cpTheater;
      document.querySelector('video')!.requestFullscreen();
    });
    expect(await page.evaluate(() => (window as any).__wentFullscreen)).toBe(1);
  });
});

test.describe('players in shadow DOM', () => {
  // archive.org — one of the app's own bundled shortcuts — puts its <video>
  // inside a <play-av> custom element's shadow root. querySelectorAll does not
  // cross that boundary, so the app used to find no video at all there: no
  // Watch clean button, no theater, nothing.
  const SHADOW = `${HEAD}
    <div id="page">site chrome</div>
    <player-host id="host"></player-host>
    <script>
      class PlayerHost extends HTMLElement {
        connectedCallback() {
          const root = this.attachShadow({ mode: 'open' });
          root.innerHTML =
            '<div class="wrap"><video id="inner" playsinline ' +
            'style="width:360px;height:200px"></video></div>';
        }
      }
      customElements.define('player-host', PlayerHost);
    <\/script>`;

  test('finds a video inside an open shadow root', async ({ page }) => {
    await serve(page, SHADOW);
    expect(await page.evaluate(() => __cp.allVideos().length)).toBe(1);
    expect(await page.evaluate(() => __cp.largestVideo()?.id)).toBe('inner');
  });

  // [data-cp-theater] .__cp_btn is an ancestor selector, and an ancestor in the
  // document cannot style a shadow tree — so on a shadow-DOM player the overlay
  // buttons stayed visible on top of the staged video.
  test('hides its overlay buttons in theater even inside a shadow root',
    async ({ page }) => {
      await serve(page, SHADOW);
      await page.evaluate(() => __cp.scan());
      await page.evaluate(() => {
        const root = document.getElementById('host')!.shadowRoot!;
        __cp.enterTheater(root.querySelector('video')!);
      });

      expect(await page.evaluate(() => {
        const root = document.getElementById('host')!.shadowRoot!;
        const btn = root.querySelector('.__cp_btn') as HTMLElement;
        return getComputedStyle(btn).display;
      })).toBe('none');
    });

  test('attaches Watch clean inside the shadow root, with its styles',
    async ({ page }) => {
      await serve(page, SHADOW);
      await page.evaluate(() => __cp.scan());

      const state = await page.evaluate(() => {
        const root = document.getElementById('host')!.shadowRoot!;
        const btn = root.querySelector('.__cp_btn') as HTMLElement | null;
        return {
          attached: !!btn,
          // Style encapsulation means the document stylesheet does not reach
          // in; without a copy the button renders unstyled and unpositioned.
          styled: btn ? getComputedStyle(btn).position : null,
          anchored: (btn?.parentElement as HTMLElement)?.style.position ?? null,
        };
      });

      expect(state.attached).toBe(true);
      expect(state.styled).toBe('absolute');
      expect(state.anchored).toBe('relative');
    });

  // The button is position:absolute. On a static parent it escapes to whatever
  // ancestor is positioned — usually the page corner, looking like no button.
  test('anchors a static parent so the button lands on the video',
    async ({ page }) => {
      await serve(page, `${HEAD}
        <div id="plain"><video id="v" playsinline
             style="width:360px;height:200px"></video></div>`);

      expect(await page.evaluate(() =>
        document.getElementById('plain')!.style.position)).toBe('relative');
    });

  test('gives the borrowed position back when the button goes', async ({ page }) => {
    await serve(page, `${HEAD}
      <div id="plain"><video id="v" playsinline
           style="width:360px;height:200px"></video></div>`);

    expect(await page.evaluate(() => {
      document.getElementById('v')!.remove();
      __cp.scan();
      return document.getElementById('plain')!.style.position;
    })).toBe('');
  });
});

test.describe('transport controls', () => {
  async function staged(page: Page) {
    await serve(page, PLAYER);
    await page.evaluate(() => {
      const v = document.querySelector('video')! as any;
      let t = 0;
      Object.defineProperty(v, 'currentTime',
        { get: () => t, set: (x) => { t = x; }, configurable: true });
      Object.defineProperty(v, 'duration', { get: () => 600, configurable: true });
      v.play = () => Promise.resolve();
    });
    await watchClean(page).click();
  }

  test('reports position, duration and rate for the scrubber', async ({ page }) => {
    await staged(page);
    const time = (await posted(page)).filter((m: any) => m.type === 'time').pop();
    expect(time).toMatchObject({ at: 0, duration: 600, rate: 1 });
  });

  test('seek clamps to the video, never past either end', async ({ page }) => {
    await staged(page);
    expect(await page.evaluate(() => { __cp.seek(9999); return __cp.largestVideo()!.currentTime; }))
      .toBe(600);
    expect(await page.evaluate(() => { __cp.seek(-50); return __cp.largestVideo()!.currentTime; }))
      .toBe(0);
  });

  test('skip moves relative to where playback is', async ({ page }) => {
    await staged(page);
    expect(await page.evaluate(() => {
      __cp.seek(100); __cp.skip(10); __cp.skip(-30);
      return __cp.largestVideo()!.currentTime;
    })).toBe(80);
  });

  // Both are unusable as a duration, but they are not the same thing. Calling
  // an unloaded video "live" mislabels every video before it is played.
  test('tells a live stream apart from one that has not loaded', async ({ page }) => {
    for (const [duration, live] of [[Infinity, true], [NaN, false]] as const) {
      await serve(page, PLAYER);
      await page.evaluate((d) => {
        const v = document.querySelector('video')! as any;
        Object.defineProperty(v, 'duration', { get: () => d, configurable: true });
        v.play = () => Promise.resolve();
      }, duration);
      await watchClean(page).click();

      const time = (await posted(page)).filter((m: any) => m.type === 'time').pop();
      expect(time.duration).toBe(0);
      expect(time.live).toBe(live);
    }
  });

  test('lists only subtitle tracks, and switching disables the others',
    async ({ page }) => {
      await serve(page, PLAYER);
      await page.evaluate(() => {
        const v = document.querySelector('video')! as any;
        const tracks = [
          { kind: 'subtitles', label: 'English', language: 'en', mode: 'disabled' },
          { kind: 'metadata',  label: 'Chapters', language: '',  mode: 'disabled' },
          { kind: 'captions',  label: 'Japanese', language: 'ja', mode: 'disabled' },
        ];
        (tracks as any).length = 3;
        Object.defineProperty(v, 'textTracks', { get: () => tracks, configurable: true });
        v.play = () => Promise.resolve();
      });
      await watchClean(page).click();

      expect(await page.evaluate(() => __cp.textTracks().map((t: any) => t.label)))
        .toEqual(['English', 'Japanese']);

      expect(await page.evaluate(() => {
        __cp.selectTextTrack(2);
        return (__cp.largestVideo() as any).textTracks.map((t: any) => t.mode);
      })).toEqual(['disabled', 'disabled', 'showing']);
    });

  test('setRate drives playbackRate', async ({ page }) => {
    await staged(page);
    expect(await page.evaluate(() => {
      __cp.setRate(1.5);
      return __cp.largestVideo()!.playbackRate;
    })).toBe(1.5);
  });

  test('transport calls do nothing with no staged video', async ({ page }) => {
    await serve(page, PLAYER);
    expect(await page.evaluate(() => __cp.seek(10))).toBe(false);
    expect(await page.evaluate(() => __cp.skip(10))).toBe(false);
    expect(await page.evaluate(() => __cp.setRate(2))).toBe(false);
    expect(await page.evaluate(() => __cp.selectSource(0))).toBe(false);
    expect(await page.evaluate(() => __cp.togglePiP())).toBe(false);
  });
});

test.describe('quality sources', () => {
  // A <source> with no src sits between the two real ones on purpose: it is
  // skipped in the list, so an index into the filtered array would address the
  // wrong element. The reported index has to be the NodeList's.
  const MULTI = `${HEAD}
<div class="trap">
  <video id="v" playsinline>
    <source src="/low.mp4"  type="video/mp4" data-quality="360p">
    <source                 type="video/mp4" data-quality="broken">
    <source src="/high.mp4" type="video/mp4" data-quality="1080p">
  </video>
</div>`;

  async function stagedMulti(page: Page) {
    await serve(page, MULTI);
    await page.evaluate(() => {
      const v = document.querySelector('video')! as any;
      v.play = () => Promise.resolve();
      // jsdom-free stand-in: real load() is async and never resolves for a
      // path this fixture does not serve as media.
      v.load = () => v.dispatchEvent(new Event('loadedmetadata'));
      Object.defineProperty(v, 'currentSrc',
        { get: () => v.getAttribute('src') || location.origin + '/low.mp4',
          configurable: true });
    });
    await watchClean(page).click();
  }

  const sources = (page: Page) => page.evaluate(() =>
    ((window as any).__posted.filter((m: any) => m.type === 'video').pop()
      ?.info?.sources ?? []));

  test('labels every source that has one, and skips the one that does not',
    async ({ page }) => {
      await stagedMulti(page);
      expect((await sources(page)).map((s: any) => s.label))
        .toEqual(['360p', '1080p']);
    });

  test('indexes against the DOM, not the filtered list', async ({ page }) => {
    await stagedMulti(page);
    // 1080p is the THIRD <source>, so its index is 2 even though it is second
    // in the menu. Off-by-one here would switch to the broken entry.
    expect((await sources(page)).map((s: any) => s.index)).toEqual([0, 2]);
  });

  test('marks which source is playing', async ({ page }) => {
    await stagedMulti(page);
    expect((await sources(page)).map((s: any) => s.active)).toEqual([true, false]);
  });

  test('selecting one swaps the src', async ({ page }) => {
    await stagedMulti(page);
    expect(await page.evaluate(() => __cp.selectSource(2))).toBe(true);
    // `.src` reads back resolved, so the attribute lands absolute. That is the
    // value `currentSrc` is later compared against, so it has to stay resolved.
    expect(await page.evaluate(() => __cp.largestVideo()!.getAttribute('src')))
      .toBe(`${ORIGIN}/high.mp4`);
  });

  test('restores position, so switching does not restart the episode',
    async ({ page }) => {
      await stagedMulti(page);
      expect(await page.evaluate(() => {
        const v = __cp.largestVideo()! as any;
        let t = 0;
        Object.defineProperty(v, 'currentTime',
          { get: () => t, set: (x: number) => { t = x; }, configurable: true });
        v.currentTime = 240;
        __cp.selectSource(2);
        return v.currentTime;
      })).toBe(240);
    });

  test('refuses an index the page does not have', async ({ page }) => {
    await stagedMulti(page);
    expect(await page.evaluate(() => __cp.selectSource(1))).toBe(false);   // no src
    expect(await page.evaluate(() => __cp.selectSource(9))).toBe(false);
    expect(await page.evaluate(() => __cp.selectSource(-1))).toBe(false);
  });

  test('is a no-op when the chosen source is already playing', async ({ page }) => {
    await stagedMulti(page);
    expect(await page.evaluate(() => __cp.selectSource(0))).toBe(true);
    expect(await page.evaluate(() => __cp.largestVideo()!.getAttribute('src')))
      .toBe(null);
  });

  // The empty case is what the menu falls back to reporting, so it has to stay
  // empty rather than inventing a row.
  test('reports no sources for a plain video element', async ({ page }) => {
    await serve(page, PLAYER);
    await page.evaluate(() => {
      (document.querySelector('video')! as any).play = () => Promise.resolve();
    });
    await watchClean(page).click();
    expect(await sources(page)).toEqual([]);
  });
});

test.describe('theater in a host page', () => {
  // The failure this fixes: on a site whose player is a cross-origin frame, the
  // frame's own agent stages the video against ITS document and stops there.
  // The host page keeps its header and server list, and the only visible change
  // is the native close button floating over an apparently untouched page.
  const HOST = `${HEAD}
    <div id="header">site header</div>
    <div id="wrap" style="position:relative">
      <iframe id="player" src="about:blank"
              style="width:640px;height:360px;background:#000"></iframe>
    </div>
    <div id="servers">server list</div>`;

  test('stages the player frame and clears the page around it', async ({ page }) => {
    await serve(page, HOST);
    expect(await page.evaluate(() => __cp.hostTheater())).toBe(true);

    await expect(page.locator('#player')).toHaveAttribute('data-cp-stage', '1');
    await expect(page.locator('#header')).toBeHidden();
    await expect(page.locator('#servers')).toBeHidden();
  });

  test('gives the page back when the frame leaves theater', async ({ page }) => {
    await serve(page, HOST);
    await page.evaluate(() => __cp.hostTheater());
    expect(await page.evaluate(() => __cp.unhostTheater())).toBe(true);

    await expect(page.locator('#header')).toBeVisible();
    await expect(page.locator('#servers')).toBeVisible();
    await expect(page.locator('#player')).not.toHaveAttribute('data-cp-stage', '1');
  });

  test('ignores tracking pixels when picking the player frame', async ({ page }) => {
    await serve(page, `${HEAD}
      <iframe id="beacon" src="about:blank" style="width:1px;height:1px"></iframe>
      <iframe id="player" src="about:blank" style="width:640px;height:360px"></iframe>`);

    expect(await page.evaluate(() => __cp.largestFrame()?.id)).toBe('player');
  });

  test('does nothing on a page with no player frame', async ({ page }) => {
    await serve(page, `${HEAD}<div id="only">no frames here</div>`);
    expect(await page.evaluate(() => __cp.hostTheater())).toBe(false);
    await expect(page.locator('#only')).toBeVisible();
  });
});

test.describe('interstitial blocking', () => {
  // The shape that got through: a centred card on a dimmed backdrop, inside the
  // player's own stacking context where z-index: 10 is normal. Both of the old
  // gates (z >= 1000, near-full-screen) missed it.
  const MODAL = `${HEAD}
    <style>
      #player { position: relative; width: 360px; height: 200px; }
      video { width: 360px; height: 200px; }
      #controls { position: absolute; left: 0; right: 0; bottom: 0; height: 28px;
                  z-index: 20; background: #111; }
      #backdrop { position: absolute; inset: 0; z-index: 10;
                  background: rgba(0,0,0,.6); }
      #card { position: absolute; left: 40px; top: 40px; width: 280px; height: 120px;
              z-index: 11; background: #fff; }
    </style>
    <div id="player">
      <video id="v" playsinline></video>
      <div id="backdrop"></div>
      <div id="card">
        <p>Please install Super Fast VPN to continue watching in safe mode.</p>
        <a href="#">Install</a>
      </div>
      <div id="controls">0:00 / 1:37</div>
    </div>
    <div id="cookie" style="position:fixed;left:0;bottom:0;width:100%;height:60px;
         z-index:5000;background:#eee">cookie notice</div>`;

  test('hides a low-z-index modal sitting on the video', async ({ page }) => {
    await serve(page, MODAL);
    await expect(page.locator('#backdrop')).toBeHidden();
  });

  test('leaves the player controls alone', async ({ page }) => {
    await serve(page, MODAL);
    // Overlaps the video, but not its centre — the hit test spares it.
    await expect(page.locator('#controls')).toBeVisible();
  });

  test('leaves a cookie notice that is not over the video alone', async ({ page }) => {
    await serve(page, MODAL);
    await expect(page.locator('#cookie')).toBeVisible();
  });

  test('never hides an element containing the video', async ({ page }) => {
    await serve(page, MODAL);
    await expect(page.locator('#player')).toBeVisible();
    await expect(page.locator('#v')).toBeAttached();
  });

  test('spares an invisible gesture layer', async ({ page }) => {
    await serve(page, `${HEAD}
      <div style="position:relative;width:360px;height:200px">
        <video id="v" playsinline style="width:360px;height:200px"></video>
        <div id="tap" style="position:absolute;inset:0;z-index:9"></div>
      </div>`);
    // No background, no content: this is how players catch taps, and hiding it
    // would break play/pause.
    await expect(page.locator('#tap')).toBeVisible();
  });

  // The worst failure this app can have: the page is blank and the video the
  // user came for is gone. A cross-origin player iframe cannot be seen into, so
  // the "does it contain a video" guard finds nothing, and the standard
  // responsive embed (position:absolute, 100% of its wrapper) is exactly the
  // shape the no-video fallback treats as a full-page gate.
  test('never hides a cross-origin player iframe on a page with no video of its own',
    async ({ page }) => {
      await serve(page, `${HEAD}
        <div style="position:relative;padding-bottom:56.25%">
          <iframe id="player" src="about:blank"
                  style="position:absolute;top:0;left:0;width:100%;height:100%;
                         background:#000">
          </iframe>
        </div>`);
      await expect(page.locator('#player')).toBeVisible();
    });

  // The other half of the iframe rule. Sparing frames applies only where this
  // document has no video of its own; an ad frame painted over a real player
  // must still go, or the fix above would have traded one hole for a bigger one.
  test('still hides an ad iframe painted over the video', async ({ page }) => {
    await serve(page, `${HEAD}
      <div id="player" style="position:relative;width:360px;height:200px">
        <video id="v" playsinline style="width:360px;height:200px"></video>
        <iframe id="adframe" src="about:blank"
                style="position:absolute;inset:0;width:100%;height:100%;
                       background:#fff;z-index:10"></iframe>
      </div>`);
    await expect(page.locator('#adframe')).toBeHidden();
    await expect(page.locator('#player')).toBeVisible();
  });

  // Audit fixture: a fake security modal carrying no text at all, only an
  // image. A text-matching detector misses these entirely; a geometric one
  // should not care.
  test('hides an image-only fake security modal over the video', async ({ page }) => {
    await serve(page, `${HEAD}
      <div id="player" style="position:relative;width:360px;height:200px">
        <video id="v" playsinline style="width:360px;height:200px"></video>
        <div id="modal" style="position:absolute;inset:0;z-index:10;
             background-image:url('data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==')">
        </div>
      </div>`);
    await expect(page.locator('#modal')).toBeHidden();
  });

  // Audit fixture: the clickjacking layer. An invisible cross-origin frame over
  // the video, there to swallow the tap that looks like Play.
  test('hides an invisible ad iframe covering the video', async ({ page }) => {
    await serve(page, `${HEAD}
      <div id="player" style="position:relative;width:360px;height:200px">
        <video id="v" playsinline style="width:360px;height:200px"></video>
        <iframe id="clickjack" src="about:blank"
                style="position:absolute;inset:0;width:100%;height:100%;
                       opacity:0.01;z-index:10"></iframe>
      </div>`);
    await expect(page.locator('#clickjack')).toBeHidden();
  });

  // Audit fixture: over-blocking check. A real sign-in dialog that is not over
  // the video must survive.
  test('leaves a sign-in dialog that is not over the video alone', async ({ page }) => {
    await serve(page, `${HEAD}
      <div id="player" style="position:relative;width:360px;height:200px">
        <video id="v" playsinline style="width:360px;height:200px"></video>
      </div>
      <div id="signin" style="position:fixed;left:0;bottom:0;width:100%;height:180px;
           z-index:5000;background:#fff">
        <p>Sign in to continue</p>
        <input type="email"><button>Sign in</button>
      </div>`);
    await expect(page.locator('#signin')).toBeVisible();
  });

  test('still catches a full-page gate before any video exists', async ({ page }) => {
    await serve(page, `${HEAD}
      <div id="gate" style="position:fixed;inset:0;z-index:5;background:#fff">
        <p>Checking your browser before visiting the site</p>
        <a href="#">Activate VPN</a>
      </div>`);
    await expect(page.locator('#gate')).toBeHidden();
  });

  test('never hides its own controls', async ({ page }) => {
    await serve(page, MODAL);
    await page.evaluate(() => {
      const mine = document.createElement('div');
      mine.setAttribute('data-cp-keep', '');
      mine.id = 'mine';
      mine.style.cssText = 'position:fixed;inset:0;z-index:2147483647;background:#000';
      document.body.appendChild(mine);
      __cp.blockOverlays();
    });
    expect(await page.evaluate(() =>
      document.getElementById('mine')!.hasAttribute('data-cp-blocked'))).toBe(false);
  });

  test('gives scrolling back', async ({ page }) => {
    await serve(page, `${HEAD}
      <style>html, body { overflow: hidden; }</style>
      <div id="gate" style="position:fixed;inset:0;z-index:5;background:#fff">gate</div>`);
    expect(await page.evaluate(() =>
      getComputedStyle(document.documentElement).overflow)).toBe('auto');
  });

  test('reports what it hid, and can be undone', async ({ page }) => {
    await serve(page, MODAL);
    expect((await posted(page)).some((m: any) => m.type === 'blocked' && m.count > 0))
      .toBe(true);

    await page.evaluate(() => __cp.setOverlayBlocking(false));
    await expect(page.locator('#backdrop')).toBeVisible();

    await page.evaluate(() => __cp.setOverlayBlocking(true));
    await expect(page.locator('#backdrop')).toBeHidden();
  });
});
