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
    expect(await posted(page)).toContainEqual(
      expect.objectContaining({ v: 1, type: 'theaterEnded' }));
  });

  // WebKit draws a full second set of controls inside a viewport-sized <video>
  // that still has `controls` — under the native overlay, which is the same
  // buttons twice. Theater must take the attribute, and give it back.
  test('takes the video\'s own controls for the duration of theater', async ({ page }) => {
    await page.evaluate(() => document.getElementById('v')!.setAttribute('controls', ''));
    await watchClean(page).click();
    await expect(page.locator('#v')).not.toHaveAttribute('controls');

    await page.evaluate(() => __cp.exitTheater());
    await expect(page.locator('#v')).toHaveAttribute('controls', '');
  });

  test('leaves a video that never had controls without them', async ({ page }) => {
    await watchClean(page).click();
    await page.evaluate(() => __cp.exitTheater());
    await expect(page.locator('#v')).not.toHaveAttribute('controls');
  });

  // `paused` flips before any data arrives. The native button must not say
  // "pause" about a black screen.
  test('reports buffering until the video has frames to show', async ({ page }) => {
    await watchClean(page).click();
    // The fixture <video> has no source: play() is requested, nothing loads.
    // The `play` event is a queued task, so poll rather than race it.
    await expect.poll(async () => (await posted(page)).some((m: any) =>
      m.type === 'playback' && m.playing === true && m.buffering === true)).toBe(true);
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

  test('uses the site episode link so an in-place player router can handle Next',
    async ({ page }) => {
      await serve(page, `${HEAD}
        <a id="next" href="/ep/2">Next episode</a>
        <video id="v" playsinline></video>
        <script>
          document.querySelector('#next').addEventListener('click', event => {
            event.preventDefault();
            document.body.dataset.switched = 'yes';
          });
        </script>`);

      expect(await page.evaluate(() => __cp.navigateEpisode(`${location.origin}/ep/2`)))
        .toBe(true);
      expect(await page.locator('body').getAttribute('data-switched')).toBe('yes');
      expect(page.url()).toBe(`${ORIGIN}/ep/1`);
    });

  test('refuses to activate a cross-origin episode target', async ({ page }) => {
    await serve(page, `${HEAD}
      <a id="next" href="https://elsewhere.test/ep/2">Next episode</a>
      <video id="v" playsinline></video>`);

    expect(await page.evaluate(() =>
      __cp.navigateEpisode('https://elsewhere.test/ep/2'))).toBe(false);
    expect(page.url()).toBe(`${ORIGIN}/ep/1`);
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

  // Jellyfin, Emby and Plex are one page each, routed in the hash. Treating
  // every fragment as an in-page anchor made every episode on those servers
  // the same page as the one being watched, so Next was never offered.
  test('a hash route is a different page', async ({ page }) => {
    await serve(page, `${HEAD}
      <a href="#/ep/2">Next episode</a>
      <a href="#/ep/0">Previous episode</a>
      <video id="v" playsinline></video>`, `${ORIGIN}/web/index.html#/ep/1`);

    expect(await page.evaluate(() => __cp.findEpisodes())).toEqual({
      next: `${ORIGIN}/web/index.html#/ep/2`,
      prev: `${ORIGIN}/web/index.html#/ep/0`,
    });
  });

  test('a plain anchor is still not a page', async ({ page }) => {
    await serve(page, `${HEAD}
      <a href="#comments">Next</a>
      <video id="v" playsinline></video>`, `${ORIGIN}/web/index.html#/ep/1`);

    expect(await page.evaluate(() => __cp.findEpisodes().next)).toBeNull();
  });

  test('hash-routed episode lists have neighbours too', async ({ page }) => {
    await serve(page, `${HEAD}
      <video id="v" playsinline style="width:360px;height:200px"></video>
      ${[1, 2, 3].map(n => `<a href="#!/item?ep=${n}">Episode ${n}</a>`).join('')}`,
      `${ORIGIN}/web/index.html#!/item?ep=2`);

    const list = await page.evaluate(() => __cp.episodeList());
    expect(list.map(e => e.current)).toEqual([false, true, false]);
    expect(await page.evaluate(() => __cp.findEpisodes())).toEqual({
      next: `${ORIGIN}/web/index.html#!/item?ep=3`,
      prev: `${ORIGIN}/web/index.html#!/item?ep=1`,
    });
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

    // `source` rides along now; this test is about availability, and the
    // stream kind has a test of its own.
    expect(await posted(page)).toContainEqual(
      expect.objectContaining({ type: 'airplay', available: true }));
    expect(await page.evaluate(() => __cp.showAirPlay())).toBe(true);
    expect(await page.evaluate(() => (window as any).__picked)).toBe(true);
  });

  // Entering theater used to add an availability listener and never remove it,
  // because both handlers were anonymous closures with nothing holding a
  // reference. Enter, leave, enter again and one route report became three —
  // and since `airplayAvailable` is module state, a listener left on an old
  // video could overwrite the answer for the current one.
  const dispatchAvailability = (page: Page) => page.evaluate(() => {
    const e: any = new Event('webkitplaybacktargetavailabilitychanged');
    e.availability = 'available';
    document.querySelector('video')!.dispatchEvent(e);
  });

  // WebKit fires a genuine availability event of its own — "not-available",
  // since no engine under test has a route — so counting from zero would fold
  // the engine's own answer in with the listeners under test. Only what the
  // dispatch itself caused is interesting.
  const forgetPosts = (page: Page) =>
    page.evaluate(() => { (window as any).__posted.length = 0; });

  const availabilityReports = async (page: Page) =>
    (await posted(page)).filter((m: any) => m.type === 'airplay').length;

  test('reports a route once, however many times theater was entered',
    async ({ page }) => {
      await serve(page, PLAYER);

      for (let round = 0; round < 3; round++) {
        await page.evaluate(() => __cp.enterTheater(
          document.querySelector('video') as HTMLVideoElement));
        await page.evaluate(() => __cp.exitTheater());
      }
      await page.evaluate(() => __cp.enterTheater(
        document.querySelector('video') as HTMLVideoElement));

      await forgetPosts(page);
      await dispatchAvailability(page);
      expect(await availabilityReports(page)).toBe(1);
    });

  /// Once theater is over the video is not the one on screen any more, and it
  /// must not still be answering for the app.
  test('a video left behind by theater no longer reports routes',
    async ({ page }) => {
      await serve(page, PLAYER);
      await page.evaluate(() => __cp.enterTheater(
        document.querySelector('video') as HTMLVideoElement));
      await page.evaluate(() => __cp.exitTheater());

      await forgetPosts(page);
      await dispatchAvailability(page);
      expect(await availabilityReports(page)).toBe(0);
    });
});

// A MediaSource has no URL a receiver could fetch, so AirPlay offloads the
// audio and leaves the picture on the phone. WebKit's documented answer is a
// second <source> carrying a real URL, which it switches to when a route is
// picked. The page author is expected to supply it; a browser has to find it.
test.describe('AirPlay source for MSE', () => {
  const asMSE = async (page: Page) => page.evaluate(() => {
    Object.defineProperty(document.querySelector('video')!, 'currentSrc',
                          { get: () => 'blob:https://example.test/abcd' });
  });
  const injected = (page: Page) => page.evaluate(() =>
    document.querySelector('video source.cp-airplay-source')?.getAttribute('src') ?? null);
  // The body has to be read: a resource-timing entry is not recorded until the
  // response completes, and fetch() resolves on headers alone.
  const fetchManifest = (page: Page) => page.evaluate(
    (o) => fetch(o + '/master.m3u8').then((r) => r.text()).catch(() => {}), ORIGIN);

  test('recognises a MediaSource blob, an HLS manifest and a plain file', async ({ page }) => {
    await serve(page, PLAYER);
    await asMSE(page);
    expect(await page.evaluate(() =>
      __cp.sourceKind(document.querySelector('video')!))).toBe('mse');

    expect(await page.evaluate(() => {
      const v = document.createElement('video');
      v.src = 'https://example.test/a.m3u8?token=1';
      return __cp.sourceKind(v);
    })).toBe('hls');

    expect(await page.evaluate(() => {
      const v = document.createElement('video');
      v.src = 'https://example.test/a.mp4';
      return __cp.sourceKind(v);
    })).toBe('file');

    expect(await page.evaluate(() =>
      __cp.sourceKind(document.createElement('video')))).toBe('none');
  });

  test('attaches a discovered manifest as a second source', async ({ page }) => {
    await serve(page, PLAYER);
    await fetchManifest(page);
    await asMSE(page);

    expect(await page.evaluate(() =>
      __cp.attachAirPlaySource(document.querySelector('video')!))).toBe('attached');
    expect(await injected(page)).toContain('/master.m3u8');
  });

  // Observed live on echovideo: `/cdn/<hash>?t.m3u8` is a 191-byte image/jpeg,
  // not a playlist. Testing the whole URL let the query string decide, so the
  // scan attached a decoy image to the video as an AirPlay source — and the
  // diagnostic that exists to explain a failed offload reported success.
  test('judges a manifest by its path, not by its query string',
    async ({ page }) => {
      await serve(page, PLAYER);

      const verdicts = await page.evaluate(() => ({
        decoy: __cp.isManifestURL('https://cdn.test/cdn/abc123?t.m3u8'),
        decoyMidQuery: __cp.isManifestURL('https://cdn.test/x?a=1&f=.m3u8&b=2'),
        real: __cp.isManifestURL('https://cdn.test/hls/master.m3u8'),
        realWithToken: __cp.isManifestURL('https://cdn.test/hls/master.m3u8?t=9'),
        segment: __cp.isManifestURL('https://cdn.test/hls/seg-1.ts'),
        notWeb: __cp.isManifestURL('blob:https://cdn.test/abcd'),
      }));

      expect(verdicts).toEqual({
        decoy: false, decoyMidQuery: false, real: true,
        realWithToken: true, segment: false, notWeb: false,
      });
    });

  test('will not attach a decoy whose query merely ends in .m3u8',
    async ({ page }) => {
      await serve(page, PLAYER);
      await page.evaluate((o) => fetch(o + '/cdn/abc?t.m3u8').then((r) => r.text())
        .catch(() => {}), ORIGIN);
      await asMSE(page);

      expect(await page.evaluate(() =>
        __cp.attachAirPlaySource(document.querySelector('video')!)))
        .toBe('no-candidate');
      expect(await injected(page)).toBeNull();
    });

  // The native side gates the AirPlay button on this. Without it the button
  // opens a picker that puts the sound on the television and leaves the
  // picture on the phone — observed on a real receiver, and the reason the
  // control now explains itself instead.
  test('tells native what kind of stream a route would have to carry',
    async ({ page }) => {
      await serve(page, PLAYER);
      await asMSE(page);
      await page.evaluate(() => __cp.enterTheater(
        document.querySelector('video') as HTMLVideoElement));

      await page.evaluate(() => {
        const e: any = new Event('webkitplaybacktargetavailabilitychanged');
        e.availability = 'available';
        document.querySelector('video')!.dispatchEvent(e);
      });

      const report = (await posted(page)).filter((m: any) => m.type === 'airplay').pop();
      expect(report).toEqual(expect.objectContaining(
        { v: 1, type: 'airplay', available: true, source: 'mse' }));
    });

  // Ranking, not guessing. A manifest with segments behind it was fetched from
  // a directory the player kept returning to; a stray hit was not.
  test('ranks a manifest with siblings above a lone one', async ({ page }) => {
    await serve(page, PLAYER);
    await page.evaluate(async (o) => {
      // One directory the player keeps returning to, one it does not.
      await fetch(o + '/lonely/solo.m3u8').then((r) => r.text()).catch(() => {});
      await fetch(o + '/hls/master.m3u8').then((r) => r.text()).catch(() => {});
      await fetch(o + '/hls/seg-1.ts').then((r) => r.text()).catch(() => {});
      await fetch(o + '/hls/seg-2.ts').then((r) => r.text()).catch(() => {});
    }, ORIGIN);

    const candidates = await page.evaluate(() => __cp.streamCandidates());
    expect(candidates[0]).toContain('/hls/master.m3u8');
    expect(candidates).toContain(`${ORIGIN}/lonely/solo.m3u8`);
  });

  test('does nothing when the page requested no manifest', async ({ page }) => {
    await serve(page, PLAYER);
    await asMSE(page);

    expect(await page.evaluate(() =>
      __cp.attachAirPlaySource(document.querySelector('video')!))).toBe('no-candidate');
    expect(await injected(page)).toBeNull();
  });

  // A src attribute makes WebKit ignore <source> children outright, so
  // attaching one would be theatre. Moving the blob into a child would need
  // load(), which tears down the page's MediaSource session mid-playback.
  test('refuses when the blob is on the src attribute', async ({ page }) => {
    await serve(page, PLAYER);
    await fetchManifest(page);
    await page.evaluate(() => {
      document.querySelector('video')!.src = 'blob:https://example.test/abcd';
    });

    expect(await page.evaluate(() =>
      __cp.attachAirPlaySource(document.querySelector('video')!))).toBe('src-attribute');
    expect(await injected(page)).toBeNull();
  });

  test('leaves a non-MSE video alone', async ({ page }) => {
    await serve(page, PLAYER);
    await fetchManifest(page);

    expect(await page.evaluate(() =>
      __cp.attachAirPlaySource(document.querySelector('video')!))).toBe('not-mse');
  });

  test('attaches on entering theater and cleans up on exit', async ({ page }) => {
    await serve(page, PLAYER);
    await fetchManifest(page);
    await asMSE(page);

    await watchClean(page).click();
    expect(await injected(page)).toContain('/master.m3u8');

    await page.evaluate(() => __cp.exitTheater());
    expect(await injected(page)).toBeNull();
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
      expect(await posted(page)).toContainEqual(
        expect.objectContaining(
          { v: 1, type: 'playback', playing: true, buffering: true }));
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

  test('disables media volume when a cross-origin stream cannot use Web Audio', async ({ page }) => {
    await serve(page, PLAYER);
    await page.evaluate(() => {
      const video = document.querySelector('video')!;
      // An unsafe cross-origin source cannot be routed through Web Audio. A
      // desktop engine may still use its writable media-element volume.
      video.src = 'https://media.example/episode.mp4';
      __cp.enterTheater(video);
    });
    expect(await page.evaluate(() => __cp.setVolume(50))).toBe(false);
    expect(await posted(page)).toContainEqual(expect.objectContaining(
      { v: 1, type: 'volume', percent: 100, boosted: false, available: false }));
  });

  test('all website volume levels use the primed gain node and cap at 200 percent', async ({ page }) => {
    await serve(page, PLAYER);
    await page.evaluate(() => {
      const gain = { gain: { value: 1 }, connect: () => {} };
      (window as any).__gain = gain;
      (window as any).AudioContext = class {
        destination = {};
        state = 'running';
        createMediaElementSource() { return { connect: () => {} }; }
        createGain() { return gain; }
        resume() { return Promise.resolve(); }
      };
      const video = document.querySelector('video')!;
      video.src = `${location.origin}/episode.mp4`;
      __cp.enterTheater(video);
    });

    expect(await page.evaluate(() => __cp.setVolume(50))).toBe(true);
    expect(await page.evaluate(() => (window as any).__gain.gain.value)).toBe(0.5);
    expect(await posted(page)).toContainEqual(expect.objectContaining(
      { v: 1, type: 'volume', percent: 50, boosted: false, available: true }));

    expect(await page.evaluate(() => __cp.setVolume(250))).toBe(true);
    expect(await page.evaluate(() => (window as any).__gain.gain.value)).toBe(2);
    expect(await posted(page)).toContainEqual(expect.objectContaining(
      { v: 1, type: 'volume', percent: 200, boosted: true, available: true }));
  });

  test('does not claim boost when WebKit rejects audio activation', async ({ page }) => {
    await serve(page, PLAYER);
    await page.evaluate(() => {
      const gain = { gain: { value: 1 }, connect: () => {} };
      (window as any).__gain = gain;
      (window as any).AudioContext = class {
        destination = {};
        state = 'suspended';
        createMediaElementSource() { return { connect: () => {} }; }
        createGain() { return gain; }
        resume() { return Promise.reject(new Error('activation denied')); }
      };
      const video = document.querySelector('video')!;
      video.src = `${location.origin}/episode.mp4`;
      __cp.enterTheater(video);
    });

    expect(await page.evaluate(() => __cp.setVolume(175))).toBe(true);
    await expect.poll(() => posted(page)).toContainEqual(expect.objectContaining(
      { v: 1, type: 'volume', percent: 100, boosted: false, available: false }));
    expect(await page.evaluate(() => (window as any).__gain.gain.value)).toBe(1);
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
    expect(ready[0]).toEqual(expect.objectContaining({
      v: 1,
      fid: expect.stringMatching(
        /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i),
      width: expect.any(Number),
      height: expect.any(Number),
      visible: true,
    }));
  });

  test('uses one stable identity per frame', async ({ page }) => {
    await serve(page, PLAYER);
    const mainMessages = await posted(page);
    const mainID = mainMessages[0].fid;
    expect(mainMessages.every((message: any) => message.fid === mainID)).toBe(true);

    await page.evaluate(() => {
      const iframe = document.createElement('iframe');
      iframe.name = 'identity-fixture';
      iframe.srcdoc = '<!doctype html><video></video>';
      document.body.appendChild(iframe);
    });
    const iframe = await page.waitForSelector('iframe[name="identity-fixture"]');
    const child = await iframe.contentFrame();
    if (!child) throw new Error('identity fixture frame did not attach');
    await child.evaluate(() => {
      (window as any).__posted = [];
      (window as any).webkit = {
        messageHandlers: { cp: { postMessage: (message: any) =>
          (window as any).__posted.push(message) } },
      };
    });
    await child.addScriptTag({ content: AGENT });
    const childMessages = await child.evaluate(() => (window as any).__posted);
    const childID = childMessages[0].fid;

    expect(childMessages.every((message: any) => message.fid === childID)).toBe(true);
    expect(childID).not.toBe(mainID);
  });

  test('retires its identity when the document leaves the frame', async ({ page }) => {
    await serve(page, PLAYER);
    const frameID = (await posted(page))[0].fid;

    await page.evaluate(() => dispatchEvent(new Event('pagehide')));

    expect(await posted(page)).toContainEqual(expect.objectContaining({
      v: 1,
      fid: frameID,
      type: 'frameGone',
    }));
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
  test('distinguishes stale playback from a same-frame episode source change',
    async ({ page }) => {
      await serve(page, `${HEAD}<video id="v" src="/episode-1.mp4"></video>`);
      await page.evaluate(() => {
        const video = document.querySelector('video')!;
        __cp.enterTheater(video);
        __cp.armEpisodeTransition();
        video.dispatchEvent(new Event('play'));
      });
      expect((await posted(page)).filter((m: any) => m.type === 'episodeSourceChanged'))
        .toHaveLength(0);
      // Native cannot compare frames, so the armed frame labels its own playback.
      expect(await posted(page)).toContainEqual(
        expect.objectContaining({ type: 'playback', armed: true }));

      await page.evaluate(() => {
        const video = document.querySelector('video')!;
        video.src = '/episode-2.mp4';
        video.dispatchEvent(new Event('loadstart'));
      });
      expect((await posted(page)).filter((m: any) => m.type === 'episodeSourceChanged'))
        .toHaveLength(1);
      // Once the source changed, the frame is no longer the outgoing one.
      await page.evaluate(() => document.querySelector('video')!.dispatchEvent(new Event('play')));
      expect((await posted(page)).filter((m: any) => m.type === 'playback').slice(-1)[0])
        .toEqual(expect.objectContaining(
          { v: 1, type: 'playback', playing: false, buffering: false }));
    });

  test('waits for a video inserted by a delayed AJAX player lifecycle',
    async ({ page }) => {
      await serve(page, `${HEAD}<div id="player"></div>`);
      const resumed = page.evaluate(() => __cp.autoTheater(2000));
      await page.waitForTimeout(250);
      await page.evaluate(() => {
        const video = document.createElement('video');
        video.id = 'ajax-video';
        video.src = '/episode-2.mp4';
        video.style.cssText = 'width:640px;height:360px';
        (video as any).play = () => Promise.resolve();
        document.querySelector('#player')!.replaceChildren(video);
      });
      expect(await resumed).toBe(true);
      expect(await page.evaluate(() => __cp.isTheater())).toBe(true);
    });

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

// A single-page app rebuilds its player between items instead of loading a
// page, so nothing announces the change to native. The staged element simply
// leaves the DOM. Theater used to stay up over nothing — black, with a set of
// controls wired to an element that no longer existed.
test.describe('a player that leaves the document', () => {
  const swap = (page: Page) => page.evaluate(() => {
    document.getElementById('v')!.remove();
    const next = document.createElement('video');
    next.id = 'v2';
    next.setAttribute('playsinline', '');
    next.src = '/b.mp4';
    document.getElementById('trap')!.appendChild(next);
  });

  test('follows the replacement into theater', async ({ page }) => {
    await serve(page, PLAYER);
    await watchClean(page).click();
    await swap(page);
    await expect.poll(() => page.evaluate(
      () => document.getElementById('v2')!.dataset.cpStage)).toBe('1');
    expect(await page.evaluate(() => __cp.isTheater())).toBe(true);
    const kinds = (await posted(page)).map((m: any) => m.type)
      .filter((k: string) => k === 'theater' || k === 'theaterEnded');
    // Ended for the old element, then theater for the new: native banks the
    // old position and re-syncs its chrome, in that order.
    expect(kinds).toEqual(['theater', 'theaterEnded', 'theater']);
  });

  test('gives the page back when nothing replaces it', async ({ page }) => {
    await serve(page, PLAYER);
    await watchClean(page).click();
    await page.evaluate(() => document.getElementById('v')!.remove());
    await page.evaluate(() => __cp.checkStaged(150));
    await expect.poll(() => page.evaluate(() => __cp.isTheater())).toBe(false);
    expect((await posted(page)).filter((m: any) => m.type === 'theaterEnded'))
      .toHaveLength(1);
    // Nothing is left hidden: the page is usable again.
    expect(await page.evaluate(
      () => document.querySelectorAll('[data-cp-hidden]').length)).toBe(0);
  });

  test('waits while the player is only briefly gone', async ({ page }) => {
    await serve(page, PLAYER);
    await watchClean(page).click();
    await page.evaluate(() => document.getElementById('v')!.remove());
    await page.waitForTimeout(400);
    expect(await page.evaluate(() => __cp.isTheater())).toBe(true);
    await page.evaluate(() => {
      const next = document.createElement('video');
      next.id = 'v2';
      next.src = '/b.mp4';
      document.getElementById('trap')!.appendChild(next);
    });
    await expect.poll(() => page.evaluate(
      () => document.getElementById('v2')!.dataset.cpStage)).toBe('1');
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

  // The shape aniwave actually renders, measured on the live site. Every entry
  // is "<number> <title>" linking to /watch/<slug>/ep-<n>; the site's own Prev
  // and Next are script-driven and have no href. The old bare-number fixture
  // above never matched this, which is why the buttons stayed empty there.
  const TITLES = ['Fortune Is Unpredictable and Mutable', 'A Certain Bomb',
    'Yokohama Gangster Paradise', 'The Tragedy of the Fatalist'];
  const SHOW = `${ORIGIN}/watch/bungou-stray-dogs-80525`;
  const ANIWAVE = (current: number, order = [1, 2, 3, 4]) => `${HEAD}
    <video id="v" playsinline style="width:360px;height:200px"></video>
    <div class="ctrl"><span>Prev</span><span>Next</span></div>
    <ul>${order.map(n => `<li><a href="/watch/bungou-stray-dogs-80525/ep-${n}"
      data-num="${n}"><b>${n}</b> <span>${TITLES[n - 1]}</span></a></li>`).join('')}</ul>
    <script>history.replaceState(null, '', '${SHOW}/ep-${current}');<\/script>`;

  test('reads a "number title" list, as aniwave renders it', async ({ page }) => {
    await serve(page, ANIWAVE(2), `${SHOW}/ep-2`);
    const found = await page.evaluate(() => __cp.findEpisodes());
    expect(found.prev).toBe(`${SHOW}/ep-1`);
    expect(found.next).toBe(`${SHOW}/ep-3`);

    const list = await page.evaluate(() => __cp.episodeList());
    expect(list.map((e: any) => e.label)).toEqual([
      '1 Fortune Is Unpredictable and Mutable', '2 A Certain Bomb',
      '3 Yokohama Gangster Paradise', '4 The Tragedy of the Fatalist']);
    expect(list.map((e: any) => e.number)).toEqual([1, 2, 3, 4]);
    expect(list.filter((e: any) => e.current).map((e: any) => e.number)).toEqual([2]);
  });

  test('orders "number title" entries by number when listed newest-first', async ({ page }) => {
    await serve(page, ANIWAVE(2, [4, 3, 2, 1]), `${SHOW}/ep-2`);
    const found = await page.evaluate(() => __cp.findEpisodes());
    expect(found.prev).toBe(`${SHOW}/ep-1`);
    expect(found.next).toBe(`${SHOW}/ep-3`);
  });

  // Episode 11 of the same show: an 81-character title. The list used to
  // reject any name over 60 characters, which left a hole where it should be.
  test('keeps an episode with a long title, truncating the label', async ({ page }) => {
    const long = 'First, an Unsuitable Profession for Her. Second, an Ecstatic Detective Agency';
    await serve(page, `${HEAD}
      <video id="v" playsinline style="width:360px;height:200px"></video>
      <a href="${SHOW}/ep-10">10 Rashomon and the Tiger</a>
      <a href="${SHOW}/ep-11">11 ${long}</a>
      <a href="${SHOW}/ep-12">12 Borne Back Ceaselessly into the Past</a>`, `${SHOW}/ep-10`);
    const list = await page.evaluate(() => __cp.episodeList());
    expect(list.map((e: any) => e.number)).toEqual([10, 11, 12]);
    expect(list[1].label.length).toBeLessThanOrEqual(60);
    expect(list[1].label.startsWith('11 First, an Unsuitable')).toBe(true);
    expect(await page.evaluate(() => __cp.findEpisodes().next)).toBe(`${SHOW}/ep-11`);
  });

  // Title-only labels are enough when the URL carries the number.
  test('takes the number from the URL when the text has none', async ({ page }) => {
    await serve(page, `${HEAD}
      <video id="v" playsinline style="width:360px;height:200px"></video>
      <a href="${ORIGIN}/show?ep=3">The Azure Messenger</a>
      <a href="${ORIGIN}/show?ep=1">Fortune Is Unpredictable</a>
      <a href="${ORIGIN}/show?ep=2">A Certain Bomb</a>`, `${ORIGIN}/show?ep=2`);
    const found = await page.evaluate(() => __cp.findEpisodes());
    expect(found.prev).toBe(`${ORIGIN}/show?ep=1`);
    expect(found.next).toBe(`${ORIGIN}/show?ep=3`);
  });

  // A "Next" link that is a real anchor must not enter the list as an entry
  // labelled "Next" — it is navigation, and findEpisodes already uses it.
  test('does not list the site\'s own Next link as an episode', async ({ page }) => {
    await serve(page, `${HEAD}
      <video id="v" playsinline style="width:360px;height:200px"></video>
      <a href="${SHOW}/ep-3">Next</a>
      ${[1, 2, 3].map(n => `<a href="${SHOW}/ep-${n}">${n} ${TITLES[n - 1]}</a>`).join('')}`,
      `${SHOW}/ep-2`);
    const list = await page.evaluate(() => __cp.episodeList());
    expect(list.map((e: any) => e.label)).toEqual([
      '1 Fortune Is Unpredictable and Mutable', '2 A Certain Bomb',
      '3 Yokohama Gangster Paradise']);
  });

  // Ordinary numbered links that are not episodes stay out.
  test('ignores pagination and comment counts', async ({ page }) => {
    await serve(page, `${HEAD}
      <video id="v" playsinline style="width:360px;height:200px"></video>
      <a href="${ORIGIN}/comments/80525">12 comments</a>
      <a href="${ORIGIN}/list?page=2">Page 2 of 9</a>
      <a href="${ORIGIN}/sleepy-hollow-1999">Sleepy Hollow (1999)</a>`, `${SHOW}/ep-2`);
    expect(await page.evaluate(() => __cp.episodeList())).toEqual([]);
  });

  // Measured live: the episode page carried "#request", "#sign" and "#"
  // anchors — in-page links that resolve to the episode URL, match its shape,
  // and are all "current". Next then pointed at the page the user was on.
  test('ignores in-page anchors on the episode page', async ({ page }) => {
    await serve(page, `${HEAD}
      <video id="v" playsinline style="width:360px;height:200px"></video>
      <a href="#request">Request</a> <a href="#">View all</a> <a href="#sign">Sign in</a>
      ${[1, 2, 3].map(n => `<a href="${SHOW}/ep-${n}">${n} ${TITLES[n - 1]}</a>`).join('')}`,
      `${SHOW}/ep-1`);
    const list = await page.evaluate(() => __cp.episodeList());
    expect(list.map((e: any) => e.label)).toEqual([
      '1 Fortune Is Unpredictable and Mutable', '2 A Certain Bomb',
      '3 Yokohama Gangster Paradise']);
    const found = await page.evaluate(() => __cp.findEpisodes());
    expect(found.next).toBe(`${SHOW}/ep-2`);
    expect(found.prev).toBeNull();
  });

  // A "Watch now" button links to the same episode as the list entry. The
  // list should carry the entry's label, whichever came first in the DOM.
  test('prefers the link whose text names the episode when a page is linked twice', async ({ page }) => {
    await serve(page, `${HEAD}
      <video id="v" playsinline style="width:360px;height:200px"></video>
      <a href="${SHOW}/ep-2">Watch now</a>
      ${[1, 2, 3].map(n => `<a href="${SHOW}/ep-${n}">${n} ${TITLES[n - 1]}</a>`).join('')}`,
      `${SHOW}/ep-1`);
    const list = await page.evaluate(() => __cp.episodeList());
    expect(list.map((e: any) => e.label)).toEqual([
      '2 A Certain Bomb', '1 Fortune Is Unpredictable and Mutable',
      '3 Yokohama Gangster Paradise']);
    expect(await page.evaluate(() => __cp.findEpisodes().next)).toBe(`${SHOW}/ep-2`);
  });

  // Live markup is <b>1</b> newline <span>Title</span>; the label read "1\nTitle".
  test('collapses whitespace inside a label', async ({ page }) => {
    await serve(page, ANIWAVE(1), `${SHOW}/ep-1`);
    const list = await page.evaluate(() => __cp.episodeList());
    expect(list[0].label).toBe('1 Fortune Is Unpredictable and Mutable');
    expect(list.some((e: any) => /\s\s|\n/.test(e.label))).toBe(false);
  });

  // A hash or trailing slash on the address must not unmark the current entry.
  test('marks the current episode through a hash and trailing slash', async ({ page }) => {
    await serve(page, ANIWAVE(3), `${SHOW}/ep-3`);
    await page.evaluate((show) => history.replaceState(null, '', show + '/ep-3/#player'), SHOW);
    const list = await page.evaluate(() => __cp.episodeList());
    expect(list.filter((e: any) => e.current).map((e: any) => e.number)).toEqual([3]);
    expect(await page.evaluate(() => __cp.findEpisodes().next)).toBe(`${SHOW}/ep-4`);
  });
});

test.describe('popup guard fingerprint', () => {
  test('leaves no string-named __cp property in the page world', async ({ page }) => {
    await page.setContent(PLAYER);
    await page.addScriptTag({ content: POPUPGUARD });

    expect(await page.evaluate(() =>
      Object.getOwnPropertyNames(window).filter((name) => name.startsWith('__cp'))))
      .toEqual([]);
  });

  test('reports blocked popups through the versioned bridge', async ({ page }) => {
    await serve(page, PLAYER);
    await page.addScriptTag({ content: POPUPGUARD });

    await page.evaluate(() => window.open('https://advertisement.test'));

    expect(await posted(page)).toContainEqual(expect.objectContaining({
      v: 1,
      fid: expect.any(String),
      type: 'popupBlocked',
    }));
    expect(await page.evaluate(() =>
      Object.prototype.hasOwnProperty.call(window, '__cpPopupsBlocked'))).toBe(false);
  });

  test('does not stack wrappers when injected twice', async ({ page }) => {
    await serve(page, PLAYER);
    await page.addScriptTag({ content: POPUPGUARD });
    await page.addScriptTag({ content: POPUPGUARD });

    await page.evaluate(() => window.open('https://advertisement.test'));

    expect((await posted(page)).filter((message: any) => message.type === 'popupBlocked'))
      .toHaveLength(1);
  });

  test('makes the wrapped window.open resemble the native function', async ({ page }) => {
    await page.setContent(PLAYER);
    await page.addScriptTag({ content: POPUPGUARD });

    expect(await page.evaluate(() => window.open.toString()))
      .toBe('function open() { [native code] }');
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

  // Leaving theater has to undo what entering it did, and `stage()` walks up
  // from the video — so on a shadow-DOM player it marks nodes inside that root.
  // `unstage()` used to query the document alone, which cannot cross the
  // boundary, so every mark survived: the video kept position:fixed, inset:0
  // and a black background while its siblings kept display:none, and native had
  // already dropped the overlay. That is a full-screen black rectangle with no
  // controls and no page — on archive.org, a bundled shortcut.
  const SHADOW_WITH_SIBLING = `${HEAD}
    <div id="page">site chrome</div>
    <player-host id="host"></player-host>
    <script>
      class PlayerHost extends HTMLElement {
        connectedCallback() {
          const root = this.attachShadow({ mode: 'open' });
          root.innerHTML =
            '<div class="wrap"><div id="sib">player chrome</div>' +
            '<video id="inner" playsinline ' +
            'style="width:360px;height:200px"></video></div>';
        }
      }
      customElements.define('player-host', PlayerHost);
    <\/script>`;

  const shadowState = (page: Page) => page.evaluate(() => {
    const root = document.getElementById('host')!.shadowRoot!;
    const sibling = root.querySelector('#sib') as HTMLElement;
    const video = root.querySelector('#inner') as HTMLElement;
    return {
      siblingHidden: sibling.hasAttribute('data-cp-hidden'),
      siblingDisplay: getComputedStyle(sibling).display,
      videoStaged: video.hasAttribute('data-cp-stage'),
      videoPosition: getComputedStyle(video).position,
    };
  });

  test('stages a video that lives inside a shadow root', async ({ page }) => {
    await serve(page, SHADOW_WITH_SIBLING);
    await page.evaluate(() => {
      const root = document.getElementById('host')!.shadowRoot!;
      __cp.enterTheater(root.querySelector('video')!);
    });

    const state = await shadowState(page);
    expect(state.videoStaged).toBe(true);
    expect(state.siblingHidden).toBe(true);
    expect(state.siblingDisplay).toBe('none');
  });

  test('gives the page back when theater ends inside a shadow root',
    async ({ page }) => {
      await serve(page, SHADOW_WITH_SIBLING);
      await page.evaluate(() => {
        const root = document.getElementById('host')!.shadowRoot!;
        __cp.enterTheater(root.querySelector('video')!);
      });
      await page.evaluate(() => __cp.exitTheater());

      const state = await shadowState(page);
      expect(state.videoStaged).toBe(false);
      expect(state.videoPosition).not.toBe('fixed');
      expect(state.siblingHidden).toBe(false);
      expect(state.siblingDisplay).not.toBe('none');
    });

  // Entering theater on a second video has to clear the first one's marks, and
  // `stage()` calls `unstage()` to do it. With the shadow root unreachable the
  // first player stayed staged underneath the second.
  test('re-staging clears the marks left in a shadow root', async ({ page }) => {
    await serve(page, `${SHADOW_WITH_SIBLING}
      <video id="outer" playsinline style="width:400px;height:220px"></video>`);

    await page.evaluate(() => {
      const root = document.getElementById('host')!.shadowRoot!;
      __cp.enterTheater(root.querySelector('video')!);
      __cp.enterTheater(document.getElementById('outer') as HTMLVideoElement);
    });

    const state = await shadowState(page);
    expect(state.videoStaged).toBe(false);
    expect(state.siblingHidden).toBe(false);
  });

  // A shadow host is opaque to querySelector('video'), so the "never hide the
  // thing the user came to watch" guard could not see the player inside it. An
  // absolutely-positioned host over its own video therefore matched every test
  // for an interstitial.
  test('never hides a shadow host holding the video', async ({ page }) => {
    await serve(page, `${HEAD}
      <style>
        #host { position: absolute; inset: 0; background: #000; }
      </style>
      <player-host id="host"></player-host>
      <script>
        class PlayerHost extends HTMLElement {
          connectedCallback() {
            const root = this.attachShadow({ mode: 'open' });
            root.innerHTML = '<video id="inner" playsinline ' +
              'style="width:400px;height:300px"></video>';
          }
        }
        customElements.define('player-host', PlayerHost);
      <\/script>`);

    await page.evaluate(() => __cp.blockOverlays());
    expect(await page.evaluate(() =>
      document.getElementById('host')!.hasAttribute('data-cp-blocked'))).toBe(false);
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

  // Measured on aniwave in the Simulator: <div id="player"> is an absolutely
  // positioned black box that stays EMPTY until a server is picked. The frame
  // guard above had nothing to find yet, the box was hidden as a gate, and the
  // iframe then landed inside display:none — a black player, forever.
  test('spares an empty player placeholder before its iframe arrives', async ({ page }) => {
    await serve(page, `${HEAD}
      <div style="position:relative;padding-bottom:56.25%">
        <div id="player" style="position:absolute;inset:0;background:#000"></div>
      </div>`);
    await expect(page.locator('#player')).toBeVisible();
    // The iframe the site adds later must show.
    await page.evaluate(() => {
      const f = document.createElement('iframe'); f.src = 'about:blank';
      f.style.cssText = 'width:100%;height:100%;border:0';
      document.getElementById('player')!.appendChild(f);
    });
    await expect(page.locator('#player iframe')).toBeVisible();
  });

  // A placeholder WITH text ("Loading player…") is indistinguishable from a
  // gate up front. Once the frame lands in it the guess was wrong; let go.
  test('releases a hidden container once a player iframe lands in it', async ({ page }) => {
    await serve(page, `${HEAD}
      <div style="position:relative;padding-bottom:56.25%">
        <div id="player" style="position:absolute;inset:0;background:#000;color:#fff">
          Loading player, please wait…
        </div>
      </div>`);
    await expect(page.locator('#player')).toBeHidden();
    await page.evaluate(() => {
      const f = document.createElement('iframe'); f.src = 'about:blank';
      f.style.cssText = 'width:100%;height:100%;border:0';
      document.getElementById('player')!.appendChild(f);
    });
    await expect(page.locator('#player')).toBeVisible();
    await expect(page.locator('#player iframe')).toBeVisible();
  });

  // The release is scoped like the frame guard: with a real <video> present,
  // an ad frame arriving inside a hidden interstitial does not free it.
  test('keeps an interstitial hidden when an ad iframe lands in it over a real video', async ({ page }) => {
    await serve(page, MODAL);
    await expect(page.locator('#backdrop')).toBeHidden();
    await page.evaluate(() => {
      const f = document.createElement('iframe'); f.src = 'about:blank';
      document.getElementById('card')!.appendChild(f);
    });
    await page.waitForTimeout(300);
    await expect(page.locator('#card')).toBeHidden();
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

  // Measured on a real Jellyfin server: its login view is a full-viewport
  // positioned element over a poster backdrop — exactly the shape the no-video
  // gate check matches — so the sign-in form was hidden and the page looked
  // broken. A consent gate never asks for a password; a login does.
  test('never hides a sign-in form', async ({ page }) => {
    await serve(page, `${HEAD}
      <div id="login" style="position:absolute;inset:0;background:#222;color:#fff">
        <h1>Please sign in</h1>
        <input type="text" name="user">
        <input type="password" name="pass">
        <button>Sign In</button>
      </div>`);
    await expect(page.locator('#login')).toBeVisible();
    await expect(page.locator('input[type=password]')).toBeVisible();
  });

  test('still catches a full-page gate before any video exists', async ({ page }) => {
    await serve(page, `${HEAD}
      <div id="gate" style="position:fixed;inset:0;z-index:5;background:#fff">
        <p>Checking your browser before visiting the site</p>
        <a href="#">Activate VPN</a>
      </div>`);
    await expect(page.locator('#gate')).toBeHidden();
  });

  // Reported from the phone, watching an episode: a "Is your browser Firefox?
  // / Yes / or choose your browser to continue" card over the still-playing
  // episode. The site puts its player in a cross-origin frame, so this
  // document has no <video> and the no-video branch is what runs — and that
  // branch spared anything HOLDING a frame. The ad card is served in a frame
  // of its own, so querySelector('iframe') found it inside the dimmer and
  // waved the whole dialog through.
  //
  // A responsive embed in the page flow, as every one of these sites has.
  const FRAMED_PLAYER = `
    <div id="embed" style="position:relative;width:100vw;height:50vh">
      <iframe id="player" src="about:blank"
              style="position:absolute;inset:0;width:100%;height:100%;
                     border:0;background:#000"></iframe>
    </div>`;

  const PINNED_DIALOG = `
    <div id="backdrop" style="position:fixed;inset:0;z-index:2147483647;
         background:rgba(0,0,0,.6)">
      <div id="card" style="position:absolute;top:12vh;left:11vw;width:78vw;height:35vh;
           background:#fff"><h2>Is your browser Firefox?</h2><button>Yes</button></div>
    </div>`;

  test('hides a browser-choice dialog whose card is an ad iframe', async ({ page }) => {
    await serve(page, `${HEAD}${FRAMED_PLAYER}
      <div id="backdrop" style="position:fixed;inset:0;z-index:2147483647;
           background:rgba(0,0,0,.6)">
        <iframe id="card" src="about:blank"
                style="position:absolute;top:12vh;left:11vw;width:78vw;height:35vh;
                       border:0;background:#fff"></iframe>
      </div>`);
    await expect(page.locator('#backdrop')).toBeHidden();
    await expect(page.locator('#player')).toBeVisible();
  });

  // The same dialog with no dimmer to catch it by. Pinned to the viewport and
  // centred on IT, so with the episode further down the page it covers none of
  // the player — and it is far shorter than the full-page gate the fallback
  // used to insist on, which is how a card this size stayed on screen.
  test('hides a viewport-pinned card that covers none of the framed player',
    async ({ page }) => {
      await serve(page, `${HEAD}
        <div style="height:60vh"></div>${FRAMED_PLAYER}
        <div id="card" style="position:fixed;top:5vh;left:11vw;width:78vw;height:35vh;
             z-index:2147483647;background:#fff">
          <h2>Is your browser Firefox?</h2><button>Yes</button>
        </div>`);
      await expect(page.locator('#card')).toBeHidden();
      await expect(page.locator('#player')).toBeVisible();
    });

  // Which frame is the player cannot be answered by size. On a phone a card
  // like the one above is BIGGER than a 16:9 embed, so largest-wins hands back
  // the ad — and then the ad is spared and the real player reads as the thing
  // sitting on top of it. What separates them is that the embed scrolls with
  // the page and the ad is pinned to the viewport.
  test('picks the scrolling embed over a larger pinned ad frame', async ({ page }) => {
    await serve(page, `${HEAD}
      <div id="embed" style="position:relative;width:60vw;height:30vh">
        <iframe id="player" src="about:blank"
                style="position:absolute;inset:0;width:100%;height:100%;
                       border:0;background:#000"></iframe>
      </div>
      <iframe id="adframe" src="about:blank"
              style="position:fixed;top:10vh;left:5vw;width:90vw;height:60vh;
                     z-index:2147483647;border:0;background:#fff"></iframe>`);
    await expect(page.locator('#adframe')).toBeHidden();
    await expect(page.locator('#player')).toBeVisible();
  });

  // Over-blocking guard for the pinned-card rule above: site chrome is a band
  // across one edge, and stays.
  test('leaves a cookie bar on a page with a framed player alone', async ({ page }) => {
    await serve(page, `${HEAD}${FRAMED_PLAYER}
      <div id="cookie" style="position:fixed;left:0;bottom:0;width:100vw;height:8vh;
           z-index:5000;background:#eee">
        <p>We use cookies</p><button>OK</button>
      </div>`);
    await expect(page.locator('#cookie')).toBeVisible();
  });

  // The gate guess and its undo are scoped to each other. A container hidden
  // before any frame existed is released when the player lands in it; an
  // overlay hidden while a player frame was already on the page is not that
  // guess, so an ad frame landing inside it cannot free it.
  test('an ad iframe landing in a hidden overlay does not release it', async ({ page }) => {
    await serve(page, `${HEAD}${FRAMED_PLAYER}
      <div id="backdrop" style="position:fixed;inset:0;z-index:2147483647;
           background:rgba(0,0,0,.6)">
        <div id="card" style="position:absolute;top:12vh;left:11vw;width:78vw;height:35vh;
             background:#fff">Is your browser Firefox?</div>
      </div>`);
    await expect(page.locator('#backdrop')).toBeHidden();
    await page.evaluate(() => {
      const f = document.createElement('iframe'); f.src = 'about:blank';
      f.style.cssText = 'width:300px;height:200px;border:0';
      document.getElementById('card')!.appendChild(f);
    });
    await page.waitForTimeout(300);
    await expect(page.locator('#backdrop')).toBeHidden();
    await expect(page.locator('#player')).toBeVisible();
  });

  // --- QA sweep -----------------------------------------------------------
  //
  // The shapes an interstitial can take that the geometry above does not, by
  // itself, see. Each of these got through when it was written.

  const SETTLE = 350;

  test('hides an overlay appended outside <body>', async ({ page }) => {
    await serve(page, `${HEAD}${FRAMED_PLAYER}`);
    // The scan used to be `body *`. Nothing stops a script appending to
    // documentElement, and an ad that does was never even examined.
    await page.evaluate(() => {
      const d = document.createElement('div');
      d.id = 'out';
      d.style.cssText = 'position:fixed;inset:0;z-index:2147483647;background:#fff';
      d.textContent = 'Is your browser Firefox?';
      document.documentElement.appendChild(d);
    });
    await expect(page.locator('#out')).toBeHidden();
  });

  test('hides an overlay rendered inside a shadow root', async ({ page }) => {
    await serve(page, `${HEAD}${FRAMED_PLAYER}`);
    // Neither querySelectorAll nor a MutationObserver crosses a shadow
    // boundary, and elementFromPoint stops at the host, so a dialog rendered
    // by a custom element was invisible three times over.
    await page.evaluate(() => {
      const host = document.createElement('div');
      host.id = 'host';
      host.attachShadow({ mode: 'open' }).innerHTML =
        `<div id="card" style="position:fixed;inset:0;z-index:2147483647;background:#fff">
           Is your browser Firefox? <button>Yes</button></div>`;
      document.body.appendChild(host);
    });
    await page.waitForTimeout(SETTLE);
    expect(await page.evaluate(() => getComputedStyle(
      document.getElementById('host')!.shadowRoot!.getElementById('card')!).display))
      .toBe('none');
  });

  test('hides an interstitial that slides in from off screen', async ({ page }) => {
    await serve(page, `${HEAD}${FRAMED_PLAYER}
      <div id="slide" style="position:fixed;top:120vh;left:11vw;width:78vw;height:35vh;
           z-index:2147483647;background:#fff">Is your browser Firefox? <button>Yes</button></div>`);
    // Parked off screen its centre cannot be hit-tested, so the pass on
    // insertion rightly let it be. It then arrives by a style edit — not a
    // node — which nothing was listening for.
    await expect(page.locator('#slide')).toBeVisible();
    await page.evaluate(() =>
      document.getElementById('slide')!.style.setProperty('top', '12vh'));
    await expect(page.locator('#slide')).toBeHidden();
  });

  test('hides a gate a scroll brings into reach', async ({ page }) => {
    await serve(page, `${HEAD}<div style="height:200vh"></div>${FRAMED_PLAYER}
      <div id="gate" style="position:absolute;top:200vh;left:0;width:100vw;height:60vh;
           z-index:2147483647;background:#fff">Checking your browser <a href="#">Continue</a></div>`);
    await page.evaluate(() => window.scrollTo(0, window.innerHeight * 2.1));
    await expect(page.locator('#gate')).toBeHidden();
  });

  test('re-hides an overlay after the page strips the mark', async ({ page }) => {
    await serve(page, `${HEAD}${FRAMED_PLAYER}${PINNED_DIALOG}`);
    await expect(page.locator('#backdrop')).toBeHidden();
    await page.evaluate(() =>
      document.getElementById('backdrop')!.removeAttribute('data-cp-blocked'));
    await expect(page.locator('#backdrop')).toBeHidden();
  });

  test('hides a sticky overlay parked over the player', async ({ page }) => {
    // Sticky is fixed once it has stuck, and a negative margin parks one over
    // the player from the start. The position gate took fixed and absolute.
    await serve(page, `${HEAD}${FRAMED_PLAYER}
      <div id="sticky" style="position:sticky;top:0;margin-top:-45vh;width:100vw;height:45vh;
           z-index:2147483647;background:#fff">Is your browser Firefox? <button>Yes</button></div>`);
    await expect(page.locator('#sticky')).toBeHidden();
  });

  test('hides an invisible <object> clickjack layer over the video', async ({ page }) => {
    // The same trick as the invisible ad iframe above, in the element that
    // was not on the list.
    await serve(page, `${HEAD}
      <div id="player" style="position:relative;width:360px;height:200px">
        <video id="v" playsinline style="width:360px;height:200px"></video>
        <object id="clickjack" type="text/html" data="about:blank"
                style="position:absolute;inset:0;width:100%;height:100%;
                       opacity:0.01;z-index:10"></object>
      </div>`);
    await expect(page.locator('#clickjack')).toBeHidden();
  });

  test('hides a modal <dialog> interstitial', async ({ page }) => {
    // showModal() flips an attribute. It inserts no node, so no pass ran.
    await serve(page, `${HEAD}${FRAMED_PLAYER}
      <dialog id="dlg" style="width:78vw;height:35vh;background:#fff">
        <h2>Is your browser Firefox?</h2><button>Yes</button>
      </dialog>`);
    await page.evaluate(() => (document.getElementById('dlg') as HTMLDialogElement).showModal());
    await expect(page.locator('#dlg')).toBeHidden();
  });

  test('hides an ad that pins its own display with inline !important', async ({ page }) => {
    // Inline `!important` outranks any author stylesheet, so the mark landed
    // and changed nothing.
    await serve(page, `${HEAD}${FRAMED_PLAYER}
      <div id="ad" style="position:fixed;inset:0;z-index:2147483647;background:#fff;
           display:block !important">Is your browser Firefox? <button>Yes</button></div>`);
    await expect(page.locator('#ad')).toBeHidden();
  });

  test('keeps hiding an ad that re-forces its display on a timer', async ({ page }) => {
    // A marked element is not re-examined, so the ad's next write was the last
    // one. Answered now from the observer rather than on the next pass: a
    // quarter second of ad, several times a second, is the ad winning.
    await serve(page, `${HEAD}${FRAMED_PLAYER}
      <div id="ad" style="position:fixed;inset:0;z-index:2147483647;background:#fff">
        Is your browser Firefox?</div>
      <script>
        setInterval(() => {
          const a = document.getElementById('ad');
          if (a) a.style.setProperty('display', 'block', 'important');
        }, 60);
      </script>`);
    await page.waitForTimeout(900);
    await expect(page.locator('#ad')).toBeHidden();
  });

  test('hides an ad re-inserted after each block', async ({ page }) => {
    await serve(page, `${HEAD}${FRAMED_PLAYER}`);
    for (let i = 0; i < 3; i++) {
      await page.evaluate(() => {
        document.getElementById('ad')?.remove();
        const d = document.createElement('div');
        d.id = 'ad';
        d.style.cssText = 'position:fixed;inset:0;z-index:2147483647;background:#fff';
        d.textContent = 'Is your browser Firefox?';
        document.body.appendChild(d);
      });
      await expect(page.locator('#ad')).toBeHidden();
    }
  });

  test('a decoy thumbnail video does not disarm the blocker', async ({ page }) => {
    // largestVideo has no size floor, so a 16px preview elsewhere on the page
    // is enough to make this document look like it has a player of its own.
    await serve(page, `${HEAD}
      <video id="thumb" playsinline style="width:16px;height:16px"></video>
      ${FRAMED_PLAYER}${PINNED_DIALOG}`);
    await expect(page.locator('#backdrop')).toBeHidden();
  });

  test('hides an ad frame hung off a zero-height anchor', async ({ page }) => {
    // The other half of picking the player by shape: an ad frame absolutely
    // positioned inside its own relative <div>. That wrapper reserves no room,
    // which is exactly what a responsive embed's wrapper exists to do.
    await serve(page, `${HEAD}
      <div id="embed" style="position:relative;width:60vw;height:30vh">
        <iframe id="player" src="about:blank"
                style="position:absolute;inset:0;width:100%;height:100%;
                       border:0;background:#000"></iframe>
      </div>
      <div id="adwrap" style="position:absolute;top:0;left:0;width:100%">
        <iframe id="adframe" src="about:blank"
                style="position:absolute;top:2vh;left:5vw;width:90vw;height:60vh;
                       z-index:2147483647;border:0;background:#fff"></iframe>
      </div>`);
    await expect(page.locator('#adframe')).toBeHidden();
    await expect(page.locator('#player')).toBeVisible();
  });

  // --- and what none of it may touch --------------------------------------

  test('leaves a sticky site header alone', async ({ page }) => {
    await serve(page, `${HEAD}
      <header id="nav" style="position:sticky;top:0;width:100vw;height:9vh;
              background:#222;color:#fff;z-index:99">AnimeSite — Browse</header>
      ${FRAMED_PLAYER}`);
    await page.waitForTimeout(SETTLE);
    await expect(page.locator('#nav')).toBeVisible();
  });

  test('leaves a sticky episode sidebar alone', async ({ page }) => {
    await serve(page, `${HEAD}${FRAMED_PLAYER}
      <aside id="eps" style="position:sticky;top:0;width:30vw;height:100vh;
             background:#111;color:#fff">Episode 1<br>Episode 2</aside>`);
    await page.waitForTimeout(SETTLE);
    await expect(page.locator('#eps')).toBeVisible();
  });

  test('leaves a pinned mini-player holding the real frame alone', async ({ page }) => {
    // Pinning is the interstitial signal, so the one thing a site legitimately
    // pins had better survive it: the frame guard for a page with no player
    // frame of its own is what saves this.
    await serve(page, `${HEAD}<div style="height:200vh"></div>
      <div id="mini" style="position:fixed;right:2vw;bottom:2vh;width:60vw;height:34vh;
           z-index:999;background:#000">
        <iframe id="player" src="about:blank" style="width:100%;height:100%;border:0"></iframe>
      </div>`);
    await page.waitForTimeout(SETTLE);
    await expect(page.locator('#mini')).toBeVisible();
    await expect(page.locator('#player')).toBeVisible();
  });

  test('never hides a sign-in form inside a shadow root', async ({ page }) => {
    // The password guard has to reach into shadow trees too, now that the scan
    // does — otherwise reaching further would have cost a working login.
    await serve(page, `${HEAD}${FRAMED_PLAYER}`);
    await page.evaluate(() => {
      const host = document.createElement('div');
      host.id = 'host';
      host.style.cssText = 'position:fixed;inset:0;z-index:2147483647;background:#222';
      host.attachShadow({ mode: 'open' }).innerHTML =
        `<div id="login" style="position:absolute;inset:0;color:#fff">
           <h1>Please sign in</h1>
           <input type="text"><input type="password"><button>Sign In</button></div>`;
      document.body.appendChild(host);
    });
    await page.waitForTimeout(SETTLE);
    // The host is the positioned box here, so the guard has to see through it
    // into the shadow tree to find the password field.
    await expect(page.locator('#host')).toBeVisible();
    expect(await page.evaluate(() => getComputedStyle(
      document.getElementById('host')!.shadowRoot!.getElementById('login')!).display))
      .not.toBe('none');
  });

  test('the shield gives back a display the blocker had to overrule', async ({ page }) => {
    await serve(page, `${HEAD}${FRAMED_PLAYER}
      <div id="ad" style="position:fixed;inset:0;z-index:2147483647;background:#fff;
           display:block !important">Is your browser Firefox? <button>Yes</button></div>`);
    await expect(page.locator('#ad')).toBeHidden();
    await page.evaluate(() => __cp.setOverlayBlocking(false));
    await expect(page.locator('#ad')).toBeVisible();
    expect(await page.evaluate(() =>
      document.getElementById('ad')!.style.getPropertyValue('display'))).toBe('block');
    await page.evaluate(() => __cp.setOverlayBlocking(true));
    await expect(page.locator('#ad')).toBeHidden();
  });

  test('settles instead of rescanning forever', async ({ page }) => {
    // Every fix above adds a reason to run a pass. They must all come to rest:
    // writing our own mark is itself a mutation, and a pass per frame on a
    // real episode page is the kind of thing that makes one stutter.
    await serve(page, `${HEAD}${FRAMED_PLAYER}
      <div id="ad" style="position:fixed;inset:0;z-index:2147483647;background:#fff">
        Is your browser Firefox?</div>`);
    await expect(page.locator('#ad')).toBeHidden();
    const hits = await page.evaluate(async () => {
      let n = 0;
      const real = document.elementFromPoint.bind(document);
      (document as any).elementFromPoint = (x: number, y: number) => { n++; return real(x, y); };
      await new Promise((r) => setTimeout(r, 1200));
      return n;
    });
    expect(hits).toBeLessThan(20);
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

test.describe('volume routing and AirPlay', () => {
  // `createMediaElementSource` is irreversible for the element's lifetime, and
  // an element routed through Web Audio does not follow AirPlay: the
  // television gets silence. Theater used to build the graph on every entry,
  // so the volume slider nobody touched broke the AirPlay button next to it.
  async function stagedWithAudioSpy(page: Page) {
    await serve(page, PLAYER);
    await page.evaluate(() => {
      (window as any).__routed = 0;
      const Ctor: any = (window as any).AudioContext || (window as any).webkitAudioContext;
      const original = Ctor.prototype.createMediaElementSource;
      Ctor.prototype.createMediaElementSource = function (...args: any[]) {
        (window as any).__routed++;
        return original.apply(this, args);
      };
      const v = document.querySelector('video')! as any;
      v.play = () => Promise.resolve();
    });
    await watchClean(page).click();
  }

  const routed = (page: Page) => page.evaluate(() => (window as any).__routed as number);

  test('entering theater does not route the element through Web Audio',
    async ({ page }) => {
      await stagedWithAudioSpy(page);
      expect(await routed(page)).toBe(0);
    });

  test('setting 100% leaves the element unrouted and reports it as available',
    async ({ page }) => {
      await stagedWithAudioSpy(page);
      await page.evaluate(() => __cp.setVolume(100));
      expect(await routed(page)).toBe(0);
      expect((await posted(page)).filter((m: any) => m.type === 'volume').slice(-1)[0])
        .toEqual(expect.objectContaining({ percent: 100, boosted: false, available: true }));
    });

  test('asking for a different level routes once and only once',
    async ({ page }) => {
      await stagedWithAudioSpy(page);
      await page.evaluate(() => __cp.setVolume(50));
      expect(await routed(page)).toBe(1);
      await page.evaluate(() => __cp.setVolume(150));
      await page.evaluate(() => __cp.setVolume(75));
      expect(await routed(page)).toBe(1);
    });

  test('a cross-origin stream without CORS says the control is unavailable',
    async ({ page }) => {
      await serve(page, PLAYER);
      await page.evaluate(() => {
        const v = document.querySelector('video')! as any;
        Object.defineProperty(v, 'currentSrc',
          { get: () => 'https://elsewhere.test/a.mp4', configurable: true });
        v.play = () => Promise.resolve();
      });
      await watchClean(page).click();
      await page.evaluate(() => __cp.setVolume(150));
      expect((await posted(page)).filter((m: any) => m.type === 'volume').slice(-1)[0])
        .toEqual(expect.objectContaining({ available: false }));
    });
});
