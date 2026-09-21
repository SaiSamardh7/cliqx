// Injected at documentStart into a named WKContentWorld, in every frame.
// Exposes window.__cp for the native side to call via
// evaluateJavaScript(_:in:in:).
//
// Deliberately renders no controls of its own. On iOS WebKit nothing painted by
// the page appears above a full-viewport staged <video> — verified with a plain
// max-z-index probe — so the player chrome is native SwiftUI instead.
(() => {
  'use strict';
  if (window.__cp) return;            // injection repeats per frame

  const STYLE_ID = '__cp_style';
  const BTN_CLASS = '__cp_btn';

  const CSS = `
[data-cp-hidden]:not([data-cp-keep]) { display: none !important; }

[data-cp-untrap] {
  transform: none !important;
  filter: none !important;
  perspective: none !important;
  contain: none !important;
  overflow: visible !important;
  clip-path: none !important;
}

/* <video> is a replaced element: with width:auto an absolutely-positioned box
   takes its INTRINSIC size and ignores the right offset, so inset:0 alone will
   not stretch it. Percentages resolve against the viewport. */
[data-cp-stage] {
  position: fixed !important;
  inset: 0 !important;
  width: 100% !important;
  height: 100% !important;
  object-fit: contain !important;
  max-width: none !important;
  max-height: none !important;
  z-index: 2147483646 !important;
  background: #000 !important;
}

[data-cp-theater] { overflow: hidden !important; }

.${BTN_CLASS} {
  all: unset;
  box-sizing: border-box;
  position: absolute;
  top: 8px;
  left: 8px;
  z-index: 2147483647;
  padding: 8px 14px;
  font: 500 13px/1.2 -apple-system, system-ui, sans-serif;
  color: #fff;
  background: rgba(0,0,0,.72);
  border-radius: 6px;
  cursor: pointer;
}
.${BTN_CLASS}[data-cp-secondary] { left: auto; right: 8px; }
.${BTN_CLASS}[data-cp-staged] { display: none !important; }

[data-cp-blocked] { display: none !important; }

/* Interstitials usually lock scrolling behind themselves. Give it back. */
html[data-cp-unlock], html[data-cp-unlock] body {
  overflow: auto !important;
  position: static !important;
}
`;

  let staged = null;                  // the video currently in theater
  let hosted = null;                  // the player frame this page is staging
  let airplayAvailable = false;
  const FRAME_ID = crypto.randomUUID();

  function frameMetrics() {
    const width = Math.max(0, Math.round(window.innerWidth));
    const height = Math.max(0, Math.round(window.innerHeight));
    return {
      width,
      height,
      visible: document.visibilityState !== 'hidden' && width > 0 && height > 0,
    };
  }

  function post(payload) {
    try {
      window.webkit?.messageHandlers?.cp?.postMessage(
        { ...payload, v: 1, fid: FRAME_ID });
    } catch (_) {}
  }

  // popupguard has to patch the page world, where the named bridge is not
  // visible. A DOM event crosses content worlds without leaving a readable
  // counter or string-named property behind on `window`.
  document.addEventListener('cliqx:popup-blocked', () => {
    post({ type: 'popupBlocked' });
  });

  /// Shadow DOM encapsulates styles, so a stylesheet in the document does not
  /// reach a button appended inside a shadow root. Each root that holds a
  /// player needs its own copy.
  function ensureStyle(root = document) {
    const host = (root === document) ? document : root;
    if (host.getElementById && host.getElementById(STYLE_ID)) return;
    if (root !== document && root.querySelector('#' + STYLE_ID)) return;
    const el = document.createElement('style');
    el.id = STYLE_ID;
    el.textContent = CSS;
    if (root === document) {
      (document.head || document.documentElement).appendChild(el);
    } else {
      root.appendChild(el);
    }
  }

  /// `querySelectorAll` does not cross into shadow DOM, and a growing number of
  /// players are custom elements — archive.org's `<play-av>` among them. Before
  /// this the app found no video at all on those sites: no Watch clean button,
  /// no theater, no player.
  ///
  /// ponytail: walks every element to find hosts, because the DOM offers no
  /// index of shadow roots. Ceiling: O(elements) per scan, and scans are
  /// rAF-throttled. Closed shadow roots stay invisible and always will be.
  function allVideos(root = document) {
    const found = [];
    for (const v of root.querySelectorAll('video')) found.push(v);
    for (const el of root.querySelectorAll('*')) {
      if (el.shadowRoot) {
        for (const v of allVideos(el.shadowRoot)) found.push(v);
      }
    }
    return found;
  }

  /// Same walk, for any selector. `stage()` marks whatever it walks past, and
  /// on a shadow-DOM player that includes nodes inside the root — so anything
  /// that has to find those marks again needs to cross the boundary too.
  function allDeep(selector, root = document) {
    const found = [];
    for (const el of root.querySelectorAll(selector)) found.push(el);
    for (const el of root.querySelectorAll('*')) {
      if (el.shadowRoot) {
        for (const m of allDeep(selector, el.shadowRoot)) found.push(m);
      }
    }
    return found;
  }

  /// The light-DOM elements that stand in for a video living inside a shadow
  /// root: the host, and any host above that one.
  ///
  /// `querySelector('video')` cannot see into a shadow root, so the guard that
  /// keeps the blocker off the player is blind to exactly the players
  /// `allVideos` exists to find. An absolutely-positioned host over its own
  /// video matches every test for an interstitial, so it got hidden.
  function videoHosts() {
    const hosts = [];
    for (const video of allVideos()) {
      let node = video.getRootNode();
      while (node && node.host) {
        hosts.push(node.host);
        node = node.host.getRootNode();
      }
    }
    return hosts;
  }

  // --- Theater ------------------------------------------------------------

  /// Clears everything around `el` and stages it full-screen.
  ///
  /// Works on the <video> in the frame that owns it, and on the player <iframe>
  /// in the page that hosts it — the walk is the same either way.
  function stage(el) {
    ensureStyle();
    unstage();                        // only one stage at a time

    let node = el;
    while (node.parentElement) {
      const parent = node.parentElement;
      for (const sib of parent.children) {
        if (sib !== node && !sib.hasAttribute('data-cp-keep')) {
          sib.dataset.cpHidden = '1';
        }
      }
      // transform / filter / perspective / contain each create a containing
      // block, which would trap the stage's position:fixed inside them.
      parent.dataset.cpUntrap = '1';
      node = parent;
    }

    el.dataset.cpStage = '1';
    document.documentElement.dataset.cpTheater = '1';
    // Set on the buttons themselves, not via a `[data-cp-theater] .btn`
    // ancestor rule: a selector rooted in the document cannot reach a button
    // inside a shadow tree, so on those players the overlay buttons stayed
    // visible on top of the staged video.
    for (const b of allButtons()) b.dataset.cpStaged = '1';
  }

  function unstage() {
    // Deep, because `stage()` walks up from the video and the video may live in
    // a shadow root. A document-only query leaves those marks in place, and the
    // marks are what make the video full-screen-fixed and its siblings
    // display:none — so the page stays bricked after Close.
    for (const el of allDeep('[data-cp-hidden],[data-cp-untrap],[data-cp-stage]')) {
      delete el.dataset.cpHidden;
      delete el.dataset.cpUntrap;
      delete el.dataset.cpStage;
    }
    delete document.documentElement.dataset.cpTheater;
    for (const b of allButtons()) delete b.dataset.cpStaged;
  }

  /// iOS renders a <video> inline only when the element itself says it may.
  ///
  /// `allowsInlineMediaPlayback` on the web view is necessary but not
  /// sufficient: without `playsinline` the platform insists on its own
  /// fullscreen player. Theater refuses fullscreen — correctly, it is already
  /// full screen — so the two together produced playback with no picture at
  /// all: audio running, scrubber advancing, black screen.
  ///
  /// Only attributes we added are taken back, so a page that set its own keeps
  /// it.
  function allowInline(video) {
    const added = [];
    for (const name of ['playsinline', 'webkit-playsinline']) {
      if (!video.hasAttribute(name)) {
        video.setAttribute(name, '');
        added.push(name);
      }
    }
    video.__cpInlined = added;
  }

  function restoreInline(video) {
    for (const name of video.__cpInlined || []) video.removeAttribute(name);
    delete video.__cpInlined;
  }

  /// Distinct from the `pause` that follows it. "Finished" is the only state
  /// that should offer the next episode; a pause halfway through must not.
  function reportEnded() {
    post({ type: 'ended' });
  }

  function reportPlayback() {
    // `armed` marks playback from the frame native armed before an episode
    // change. Native cannot tell frames apart itself: WKFrameInfo is a
    // transient object with no value equality.
    if (staged) post({ type: 'playback', playing: !staged.paused,
                       ...(armedEpisodeSource !== null && { armed: true }) });
  }

  /// A live stream reports Infinity. A video that has not loaded its metadata
  /// yet reports NaN. Both are unusable as a duration, but they are NOT the
  /// same thing: calling the second one "live" mislabels every video the user
  /// has not pressed play on yet.
  function finiteDuration(video) {
    const d = video.duration;
    return (typeof d === 'number' && isFinite(d) && d > 0) ? d : 0;
  }

  function isLive(video) {
    return video.duration === Infinity;
  }

  function bufferedAhead(video) {
    const b = video.buffered;
    for (let i = 0; i < b.length; i++) {
      if (b.start(i) <= video.currentTime && video.currentTime <= b.end(i)) {
        return b.end(i);
      }
    }
    return video.currentTime;
  }

  function reportTime() {
    if (!staged || scrubbing) return;
    post({
      type: 'time',
      at: staged.currentTime || 0,
      duration: finiteDuration(staged),
      live: isLive(staged),
      buffered: bufferedAhead(staged),
      rate: staged.playbackRate || 1,
    });
  }

  /// `timeupdate` fires about four times a second. Every one of those crossing
  /// the bridge and invalidating SwiftUI is more than a seek bar needs.
  let lastTimePost = 0;
  function onTimeUpdate() {
    const now = Date.now();
    if (now - lastTimePost < 400) return;
    lastTimePost = now;
    reportTime();
  }

  /// True while the user drags the native scrubber. Position updates from the
  /// page would otherwise fight the thumb under their finger.
  let scrubbing = false;

  /// Held for as long as the drag, and no longer. `seek()` is what normally
  /// clears it, but a drag that ends without one — the video going away, an
  /// episode change mid-gesture — used to leave it set for good, and a stuck
  /// flag silences every position update for the rest of that video.
  let scrubDeadline = null;
  function beginScrub() {
    scrubbing = true;
    clearTimeout(scrubDeadline);
    scrubDeadline = setTimeout(() => { scrubbing = false; }, 10000);
    return true;
  }

  function endScrub() {
    scrubbing = false;
    clearTimeout(scrubDeadline);
    scrubDeadline = null;
  }

  function seek(to) {
    if (!staged) { endScrub(); return false; }
    const d = finiteDuration(staged);
    // Page-supplied only in the sense that the native bar computed it from a
    // duration this same element reported; clamp anyway.
    const target = Math.max(0, d > 0 ? Math.min(to, d) : to);
    staged.currentTime = target;
    endScrub();
    reportTime();
    return true;
  }

  function skip(by) {
    if (!staged) return false;
    return seek((staged.currentTime || 0) + by);
  }

  function setRate(rate) {
    if (!staged) return false;
    staged.playbackRate = rate;
    reportTime();
    return true;
  }

  // Native arms this before it clicks the site's Next/Previous control. The
  // old video may emit an ordinary `play` event during teardown; that is not a
  // successful handoff. Only a real source lifecycle event with a changed URL
  // may authorize same-frame playback to complete the transition.
  let armedEpisodeSource = null;
  let episodeSourceCleanup = null;
  function armEpisodeTransition() {
    if (!staged) return false;
    if (episodeSourceCleanup) episodeSourceCleanup();
    const video = staged;
    armedEpisodeSource = video.currentSrc || video.src || '';

    const changed = () => {
      if (staged !== video) return;
      const source = video.currentSrc || video.src || '';
      if (!source || source === armedEpisodeSource) return;
      if (episodeSourceCleanup) episodeSourceCleanup();
      post({ type: 'episodeSourceChanged', playing: !video.paused });
    };
    const events = ['loadstart', 'loadedmetadata', 'durationchange'];
    for (const event of events) video.addEventListener(event, changed);
    const observer = new MutationObserver(changed);
    observer.observe(video, { attributes: true, attributeFilter: ['src'],
                              childList: true, subtree: true });
    episodeSourceCleanup = () => {
      for (const event of events) video.removeEventListener(event, changed);
      observer.disconnect();
      episodeSourceCleanup = null;
      armedEpisodeSource = null;
    };
    return true;
  }

  // iOS ignores writes to HTMLMediaElement.volume. Route every requested level
  // through Web Audio when the stream is CORS-safe, not only the boosted range.
  // Creating the graph while entering theater is important: watchClean runs in
  // the site's real click, while a later native evaluateJavaScript call has no
  // WebKit user activation and may leave AudioContext permanently suspended.
  const boostedAudio = new WeakMap();
  function prepareVolume(video) {
    const existing = boostedAudio.get(video);
    if (existing) return existing;
    const sourceURL = video.currentSrc || video.src || '';
    let safeSource = sourceURL.startsWith('blob:') || sourceURL.startsWith('data:');
    try {
      const parsed = new URL(sourceURL, location.href);
      safeSource = safeSource || parsed.origin === location.origin || !!video.crossOrigin;
    } catch (_) {}
    const AudioContextClass = window.AudioContext || window.webkitAudioContext;
    if (!safeSource || !AudioContextClass) return null;
    try {
      const context = new AudioContextClass();
      const source = context.createMediaElementSource(video);
      const gain = context.createGain();
      source.connect(gain);
      gain.connect(context.destination);
      const chain = { context, source, gain };
      boostedAudio.set(video, chain);
      // Confirm activation when a level is requested. Not every theater entry
      // path carries a WebKit user gesture.
      return chain;
    } catch (_) {
      return null;
    }
  }

  function setVolume(percent) {
    if (!staged) return false;
    const wanted = Math.min(Math.max(Math.round(Number(percent) || 0), 0), 200);
    const chain = prepareVolume(staged);
    if (!chain) {
      // Native owns 0...100 through MPVolumeView. Cross-origin streams without
      // CORS cannot be routed through Web Audio, so boost honestly caps at 100.
      if (wanted <= 100) {
        post({ type: 'volume', percent: wanted, boosted: false });
        return true;
      }
      post({ type: 'volume', percent: 100, boosted: false });
      return false;
    }
    staged.volume = 1;
    // Native already attenuates 0...100. Applying that level here too would
    // turn 50% into 25%, so Web Audio is boost-only.
    chain.gain.gain.value = Math.max(wanted / 100, 1);
    Promise.resolve(chain.context.resume()).then(() => {
      if (chain.context.state && chain.context.state !== 'running') {
        post({ type: 'volume', percent: Math.min(wanted, 100), boosted: false });
        return;
      }
      post({ type: 'volume', percent: wanted, boosted: wanted > 100 });
    }).catch(() => {
      chain.gain.gain.value = 1;
      post({ type: 'volume', percent: Math.min(wanted, 100), boosted: false });
    });
    return true;
  }

  /// Only tracks the page exposes as real TextTracks. Sites that paint their
  /// own subtitles onto the video are invisible here, and the native menu hides
  /// itself rather than offering an empty list.
  function textTracks() {
    if (!staged || !staged.textTracks) return [];
    const out = [];
    for (let i = 0; i < staged.textTracks.length; i++) {
      const t = staged.textTracks[i];
      if (t.kind !== 'subtitles' && t.kind !== 'captions') continue;
      out.push({
        index: i,
        label: t.label || t.language || `Track ${i + 1}`,
        active: t.mode === 'showing',
      });
    }
    return out;
  }

  function selectTextTrack(index) {
    if (!staged || !staged.textTracks) return false;
    for (let i = 0; i < staged.textTracks.length; i++) {
      staged.textTracks[i].mode = (i === index) ? 'showing' : 'disabled';
    }
    reportTracks();
    return true;
  }

  function reportTracks() {
    post({ type: 'tracks', tracks: textTracks() });
  }

  /// Resolution comes from the decoded frame, which is the only quality figure
  /// available from outside the site's own player. Switching quality is the
  /// site's job — its selector lives in the UI theater just hid.
  function videoInfo() {
    if (!staged) return null;
    const sources = [];
    // Indexed against the NodeList, not against `sources`: a <source> with no
    // src is skipped, and an index into the filtered array would then address
    // the wrong element when the menu asks for one.
    const list = staged.querySelectorAll('source');
    for (let i = 0; i < list.length; i++) {
      const el = list[i];
      if (!el.src) continue;
      const label = el.getAttribute('data-quality') || el.getAttribute('label')
                 || el.getAttribute('size') || el.type || el.src.split('/').pop();
      sources.push({
        index: i,
        label: String(label).slice(0, 40),
        active: el.src === staged.currentSrc,
      });
    }
    return {
      height: staged.videoHeight || 0,
      width: staged.videoWidth || 0,
      fit: staged.style.objectFit || 'contain',
      sources,
    };
  }

  /// Switches to one of the page's own <source> elements.
  ///
  /// Only possible where the page exposes plain <source> children. An MSE
  /// player has none — its variants live inside its own manifest — so this is
  /// empty on most sites and the menu reports the decoded height instead.
  ///
  /// Takes an INDEX, never a URL. The src came from page content, and
  /// interpolating page text into the native side's evaluateJavaScript call
  /// would give the page a script injection into our own world. Every other
  /// selector here works the same way, for the same reason.
  function selectSource(index) {
    if (!staged) return false;
    const video = staged;                 // may be swapped out before we resume
    const chosen = video.querySelectorAll('source')[index];
    if (!chosen || !chosen.src) return false;
    if (video.currentSrc === chosen.src) return true;

    // Setting src resets the element: position and play state have to be put
    // back by hand, or switching quality restarts the episode.
    const at = video.currentTime || 0;
    const wasPlaying = !video.paused;

    const restore = () => {
      video.removeEventListener('loadedmetadata', restore);
      try { video.currentTime = at; } catch (_) {}
      if (wasPlaying) video.play().catch(() => {});
      reportVideo();
      reportTime();
    };
    video.addEventListener('loadedmetadata', restore);

    // The src attribute wins over <source> children, so the children stay in
    // the DOM and remain addressable for the next switch.
    video.src = chosen.src;
    video.load();
    reportVideo();
    return true;
  }

  /// contain shows the whole frame with bars; cover fills the screen and crops.
  /// Nothing else is offered — `fill` distorts, and users read that as a bug.
  function setObjectFit(mode) {
    if (!staged) return false;
    const value = (mode === 'cover') ? 'cover' : 'contain';
    staged.style.setProperty('object-fit', value, 'important');
    post({ type: 'video', info: videoInfo() });
    return true;
  }

  function reportVideo() {
    if (staged) post({ type: 'video', info: videoInfo() });
  }

  /// The whole episode list, not just the neighbours, so the player can offer
  /// a picker. Same-origin only, and capped: some season pages link hundreds.
  /// Episode-shaped path or query: `/ep-2`, `/episode-12`, `?ep=3`, `/e02`
  /// is deliberately not matched. Applied to path+query only, never the host.
  const EPISODE_HREF_RE = /(?:^|[\/?&#=._-])ep(?:isode)?[-_=.]?(\d{1,4})(?!\d)/i;

  /// Where a site's own Prev/Next are real links they would otherwise land in
  /// the list labelled "Next", ahead of the entry that names the episode.
  const NAV_NAME_RE = /^\s*(next|prev|previous)\b/i;

  function episodeNumber(name, url) {
    const lead = name.match(/^\s*(\d{1,4})(?!\d)/);
    if (lead) return parseInt(lead[1], 10);
    const worded = name.match(/\bep(?:isode)?\.?\s*(\d{1,4})(?!\d)/i);
    if (worded) return parseInt(worded[1], 10);
    const shaped = (url.pathname + url.search + routeFragment(url)).match(EPISODE_HREF_RE);
    return shaped ? parseInt(shaped[1], 10) : null;
  }

  /// A fragment that is a route rather than an anchor. Jellyfin, Emby and
  /// Plex are single pages that navigate entirely in the hash — `#/details?id=`,
  /// `#!/item?id=` — so on those sites the fragment is the only thing that
  /// distinguishes one episode from the next. `#top` and `#comments` are
  /// still anchors.
  function routeFragment(u) {
    return /^#!?\//.test(u.hash) ? u.hash : '';
  }

  /// A trailing slash is a server's habit, and an anchor never distinguishes
  /// episodes; a hash route does.
  function pageKey(href) {
    try {
      const u = new URL(href);
      return u.origin + u.pathname.replace(/\/+$/, '') + u.search + routeFragment(u);
    } catch (_) { return href; }
  }

  function episodeList() {
    const byPage = new Map();          // pageKey -> index into out
    const out = [];
    const here = pageKey(location.href);
    for (const a of document.querySelectorAll('a[href]')) {
      // "#request", "#sign", "#": in-page anchors on an episode URL resolve to
      // the episode URL, and on the live site they outnumbered the real entry
      // four to one — every one of them "current", so Next pointed back here.
      // A hash *route* is not an anchor, and is kept.
      const rawHref = (a.getAttribute('href') || '').trim();
      if (rawHref.startsWith('#') && !/^#!?\//.test(rawHref)) continue;
      const name = accessibleName(a);
      if (!name || name.length > 200) continue;
      if (NAV_NAME_RE.test(name)) continue;
      const href = sameOriginURL(a);
      if (!href) continue;
      const url = new URL(href);
      // Text OR URL shape. aniwave labels every entry "2 A Certain Bomb" and
      // links it to /ep-2: the text alone satisfies neither half of EPISODE_RE,
      // and every episode on the site was being thrown away for it.
      const shaped = EPISODE_HREF_RE.test(url.pathname + url.search + routeFragment(url));
      if (!EPISODE_RE.test(name) && !shaped) continue;
      // A leading number is evidence the TEXT names the episode — enough to
      // outrank a "Watch now" link to the same page — but not enough on its own
      // to admit "12 comments", so it only counts once the URL has qualified.
      const byText = EPISODE_RE.test(name) || (shaped && /^\s*\d{1,4}(?!\d)/.test(name));

      const key = pageKey(href);
      const entry = {
        // Truncated, not rejected. Episode 11 of the same show has an 81-char
        // title, and a length cap that drops it makes a hole in the list.
        label: name.slice(0, 60),
        href,
        current: key === here,
        number: episodeNumber(name, url),
        byText,
      };
      const at = byPage.get(key);
      if (at === undefined) {
        byPage.set(key, out.length);
        out.push(entry);
        if (out.length >= 200) break;
      } else if (byText && !out[at].byText) {
        // Same page, but this link's text names the episode and the earlier
        // one only matched by URL — the label the user sees should be this one.
        out[at] = entry;
      }
    }
    for (const e of out) delete e.byText;
    return out;
  }

  function canPiP() {
    return !!(staged && typeof staged.webkitSetPresentationMode === 'function');
  }

  function togglePiP() {
    if (!canPiP()) return false;
    const mode = staged.webkitPresentationMode === 'picture-in-picture'
      ? 'inline' : 'picture-in-picture';
    try { staged.webkitSetPresentationMode(mode); return true; }
    catch (_) { return false; }
  }

  function enterTheater(video) {
    if (!video || !video.isConnected) return false;
    exitTheater();
    stage(video);
    // Before anything asks it to play: setting this on a playing element does
    // not always bring the picture back on iOS.
    allowInline(video);
    staged = video;
    prepareVolume(video);
    trackAirPlay(video);
    // Theater hides the page, and the page is where the player's own play
    // button lives. The native bar has to know whether it is showing play or
    // pause, or the user is left with no way to control what they are watching.
    video.addEventListener('play', reportPlayback);
    video.addEventListener('pause', reportPlayback);
    video.addEventListener('ended', reportEnded);
    video.addEventListener('timeupdate', onTimeUpdate);
    video.addEventListener('durationchange', reportTime);
    video.addEventListener('progress', onTimeUpdate);

    post({ type: 'theater', airplay: airplayAvailable, pip: canPiP(), ...frameMetrics() });
    reportPlayback();
    reportTime();
    reportTracks();
    reportVideo();
    video.addEventListener('loadedmetadata', reportVideo);
    video.addEventListener('resize', reportVideo);
    return true;
  }

  /// Drives the native play/pause button.
  function togglePlay() {
    if (!staged) return false;
    if (staged.paused) staged.play().catch(() => {});
    else staged.pause();
    return true;
  }

  /// Called in the MAIN frame when theater started inside a cross-origin player
  /// frame.
  ///
  /// That frame staged the video against its own document root and stopped
  /// there — it has no reach into this one. Without this the site's header,
  /// server list and comments stay on screen underneath the native player
  /// controls, which reads as the app having done nothing but drop a stray
  /// close button on the page. Staging the frame itself finishes the job.
  function hostTheater() {
    const frame = largestFrame();
    if (!frame) return false;
    stage(frame);
    hosted = frame;
    return true;
  }

  function unhostTheater() {
    if (!hosted) return false;
    unstage();
    hosted = null;
    return true;
  }

  function largestFrame() {
    let best = null, bestArea = 0;
    for (const f of document.querySelectorAll('iframe')) {
      const r = f.getBoundingClientRect();
      const area = r.width * r.height;
      // Tracking pixels and 1x1 beacons are iframes too.
      if (area > bestArea && r.width >= 200 && r.height >= 100) {
        best = f; bestArea = area;
      }
    }
    return best;
  }

  function inFixedSubtree(el) {
    for (let n = el; n && n !== document.documentElement; n = n.parentElement) {
      if (getComputedStyle(n).position === 'fixed') return true;
    }
    return false;
  }

  /// The page's player embed: the biggest frame that scrolls WITH the page.
  ///
  /// `largestFrame` cannot serve here. On a phone a "choose your browser" card
  /// is wider and taller than a 16:9 embed below it, so largest-wins hands back
  /// the ad — and the overlay blocker then spares the ad and reads the real
  /// player as the thing on top. What separates them is not size: a responsive
  /// embed scrolls away with its page, while an interstitial is pinned to the
  /// viewport. No site pins its own player there, so a frame under a
  /// position:fixed ancestor is never the player.
  function playerFrame() {
    let best = null, bestArea = 0;
    for (const f of document.querySelectorAll('iframe')) {
      const r = f.getBoundingClientRect();
      const area = r.width * r.height;
      if (area <= bestArea || r.width < 200 || r.height < 100) continue;
      if (isOurs(f) || f.closest('[data-cp-keep]')) continue;
      if (inFixedSubtree(f)) continue;
      // Not every interstitial is pinned; some are absolutely positioned over
      // a scroll-locked page, and one of those bigger than the embed would
      // otherwise be crowned the player. A responsive embed is absolute INSIDE
      // a wrapper that RESERVES its aspect-ratio box — the padding-bottom
      // trick, and the whole technique. An overlay is positioned against the
      // page, or hung off a zero-height anchor that reserves nothing.
      if (getComputedStyle(f).position === 'absolute') {
        const host = f.offsetParent;
        if (!host || host === document.body || host === document.documentElement) continue;
        if (overlapFraction(host.getBoundingClientRect(), r) < 0.5) continue;
      }
      best = f; bestArea = area;
    }
    return best;
  }

  function exitTheater() {
    unstage();
    hosted = null;
    if (staged) {
      staged.removeEventListener('play', reportPlayback);
      staged.removeEventListener('pause', reportPlayback);
      staged.removeEventListener('ended', reportEnded);
      staged.removeEventListener('timeupdate', onTimeUpdate);
      staged.removeEventListener('durationchange', reportTime);
      staged.removeEventListener('progress', onTimeUpdate);
      staged.removeEventListener('loadedmetadata', reportVideo);
      staged.removeEventListener('resize', reportVideo);
      staged.style.removeProperty('object-fit');
      untrackAirPlay(staged);
      detachAirPlaySource(staged);
      restoreInline(staged);
      endScrub();
      staged = null;
      post({ type: 'theaterEnded' });
    }
    return true;
  }

  function isTheater() {
    return document.documentElement.hasAttribute('data-cp-theater');
  }

  // --- Mode B, with Mode C fallback ---------------------------------------

  /// Always Mode C. Mode B (WebKit's own fullscreen) looks better but takes the
  /// whole screen with Apple's chrome, which has no next/previous episode and
  /// no way back to our controls — so it cannot be the default. It is offered
  /// as a separate button instead.
  function watchClean(video) {
    // Players routinely swap the <video> out after they initialise (Wikimedia's
    // does), leaving a detached node behind. Re-resolve rather than fail.
    if (!video || !video.isConnected) video = largestVideo();
    if (!video) return 'none';
    if (!enterTheater(video)) return 'none';
    // Staging a paused video used to leave a black screen with nothing but a
    // close button — the page's own play control was hidden along with the
    // page. This runs inside the tap that asked for it, so autoplay policy
    // allows it.
    if (video.paused) video.play().catch(() => {});
    return 'C';
  }

  /// Mode B. Must be called from a real in-page gesture: iOS refuses fullscreen
  /// otherwise, and a native evaluateJavaScript call carries no gesture — which
  /// is why this is an injected button and not a native one.
  function nativeFullscreen(video) {
    if (!video || !video.isConnected) video = largestVideo();
    if (!video) return false;
    // videoWidth stays 0 when WebKit cannot decode the stream; handing such a
    // video to the native player presents nothing at all.
    if (typeof video.webkitEnterFullscreen !== 'function' ||
        video.readyState < 1 /* HAVE_METADATA */ || video.videoWidth === 0) {
      return false;
    }
    try { video.webkitEnterFullscreen(); return true; } catch (_) { return false; }
  }

  function canNativeFullscreen(video) {
    return typeof video.webkitEnterFullscreen === 'function';
  }

  // --- AirPlay ------------------------------------------------------------

  /// What the element is actually playing. This decides whether AirPlay can
  /// take the picture at all: a Media Source stream (blob: currentSrc, which
  /// is what DASH/MSE players and most DRM sites produce) cannot be handed to
  /// a receiver as video. WebKit offloads the audio and keeps the picture on
  /// the phone — the "sound on the TV, no picture" symptom exactly.
  /// Whether a URL names a manifest, judged on its PATH.
  ///
  /// Testing the whole URL matched the query string too, and ad-funded video
  /// sites put `.m3u8` there on purpose: observed live on echovideo, where
  /// `/cdn/<hash>?t.m3u8` is a 191-byte image/jpeg, not a playlist. The
  /// candidate scan took it for a manifest and attached it to the video as an
  /// AirPlay source — so the one diagnostic that was supposed to explain a
  /// failed offload reported `attached` and meant nothing.
  function isManifestURL(raw) {
    try {
      const url = new URL(raw, location.href);
      if (url.protocol !== 'https:' && url.protocol !== 'http:') return false;
      return /\.m3u8$/i.test(url.pathname);
    } catch (_) {
      return false;
    }
  }

  function sourceKind(video) {
    const src = video.currentSrc || video.src || '';
    if (!src) return 'none';
    if (src.startsWith('blob:')) return 'mse';
    if (isManifestURL(src)) return 'hls';
    if (src.startsWith('data:')) return 'data';
    return 'file';
  }

  /// AirPlay needs a URL the receiver can fetch for itself, and a MediaSource
  /// has none — the blob only means something in this process. WebKit's own
  /// answer is a second <source> holding an AirPlay-capable URL, which it
  /// switches to when a route is picked:
  /// https://webkit.org/blog/15036/how-to-use-media-source-extensions-with-airplay/
  ///
  /// That guidance is written for the page author, who already knows the URL.
  /// We are the browser, so it has to be discovered. Resource timing sees
  /// every request the page made and needs no patching of its fetch stack —
  /// monkey-patching fetch/XHR on an arbitrary site is how you break the site.
  const AIRPLAY_SRC_CLASS = 'cp-airplay-source';

  /// A playlist is text. The 191-byte image this scan once accepted was not
  /// one, and neither is a multi-megabyte response.
  ///
  /// Cross-origin responses without `Timing-Allow-Origin` report 0 for every
  /// size field, which is most media CDNs — so an unknown size is not held
  /// against a candidate, only an implausible one.
  const MIN_MANIFEST_BYTES = 200;
  const MAX_MANIFEST_BYTES = 2 * 1024 * 1024;

  function directoryOf(raw) {
    try {
      const url = new URL(raw, location.href);
      return url.origin + url.pathname.replace(/[^/]*$/, '');
    } catch (_) {
      return '';
    }
  }

  /// Ranked, best first, and only ever URLs the page actually requested.
  ///
  /// The ranking signal is siblings: a manifest with segments behind it was
  /// fetched from a directory the player kept going back to, while a stray hit
  /// usually was not. That orders real playlists above one-off files without
  /// inventing anything.
  ///
  /// ponytail: deliberately does NOT infer a manifest URL that was never
  /// requested — no appending `/index.m3u8` to a directory that looks
  /// promising. Same rule as episode discovery, for the same reason: a guessed
  /// URL fails as a 404 the user cannot see, and here it would be handed
  /// silently to a television.
  function streamCandidates() {
    let entries = [];
    try {
      entries = performance.getEntriesByType('resource');
    } catch (_) {
      return [];
    }

    const siblings = new Map();
    for (const entry of entries) {
      const dir = directoryOf(entry.name || '');
      if (dir) siblings.set(dir, (siblings.get(dir) || 0) + 1);
    }

    const ranked = new Map();
    for (const entry of entries) {
      const url = entry.name || '';
      // Manifests only. A media segment is useless to a receiver, and .mp4
      // here is as likely to be an init segment as a whole playable file.
      if (!isManifestURL(url) || ranked.has(url)) continue;
      const size = entry.encodedBodySize || entry.transferSize || 0;
      if (size && (size < MIN_MANIFEST_BYTES || size > MAX_MANIFEST_BYTES)) continue;
      ranked.set(url, siblings.get(directoryOf(url)) || 1);
    }

    return [...ranked.entries()]
      .sort((a, b) => b[1] - a[1])
      .map(([url]) => url);
  }

  /// Returns what it did, for the log. The interesting failure is
  /// 'src-attribute': a src on the element makes WebKit ignore <source>
  /// children entirely, and moving the blob into a child would need load(),
  /// which tears down the page's MediaSource session mid-playback. Breaking
  /// playback to maybe gain AirPlay is not a trade worth making silently.
  function attachAirPlaySource(video) {
    if (sourceKind(video) !== 'mse') return 'not-mse';
    if (video.hasAttribute('src') || video.src) return 'src-attribute';
    if (video.querySelector('source.' + AIRPLAY_SRC_CLASS)) return 'already';
    const candidates = streamCandidates();
    if (!candidates.length) return 'no-candidate';
    const el = document.createElement('source');
    el.className = AIRPLAY_SRC_CLASS;
    el.type = 'application/x-mpegURL';
    el.src = candidates[0];
    video.appendChild(el);
    return 'attached';
  }

  function detachAirPlaySource(video) {
    for (const el of video.querySelectorAll('source.' + AIRPLAY_SRC_CLASS)) {
      el.remove();
    }
  }

  /// Named, and kept on the element, so they can be taken off again.
  ///
  /// These were anonymous closures with nothing holding a reference, which
  /// made them unremovable: entering theater a second time on the same video
  /// added a second pair, and `airplayAvailable` is module state — so a
  /// listener left on a video the user had already left could overwrite the
  /// answer for the one they were watching. Apple's own guidance is to observe
  /// availability only while the controls that use it are on screen.
  function untrackAirPlay(video) {
    const handlers = video && video.__cpAirPlay;
    if (!handlers) return;
    video.removeEventListener('webkitplaybacktargetavailabilitychanged',
                              handlers.availability);
    delete video.__cpAirPlay;
    airplayAvailable = false;
  }

  function trackAirPlay(video) {
    // Never stack, even if theater was left by a path that skipped the teardown.
    untrackAirPlay(video);
    airplayAvailable = false;
    video.setAttribute('x-webkit-airplay', 'allow');

    // Detecting a route and opening the picker are two different capabilities,
    // and this used to bail out of the first when the second was missing: no
    // webkitShowPlaybackTargetPicker meant no listener, so we never learned a
    // route existed at all. The button then stayed hidden with nothing to say
    // why. Listen unconditionally; showAirPlay still guards on the method.
    const availability = (e) => {
      airplayAvailable = e.availability === 'available';
      // `source` is the half that was missing. A route being available says
      // nothing about whether the picture can travel down it: a MediaSource
      // has no URL a receiver can fetch, so WebKit offloads the audio and
      // leaves the video on the phone. Native needs both facts to decide what
      // the AirPlay button should even do.
      post({
        type: 'airplay',
        available: airplayAvailable,
        source: sourceKind(video),
      });
    };

    video.addEventListener('webkitplaybacktargetavailabilitychanged', availability);
    video.__cpAirPlay = { availability };

    // Give WebKit an AirPlay-capable <source> to switch to if the stream is
    // MediaSource. Harmless on any other kind — it returns without touching
    // the element. See attachAirPlaySource.
    attachAirPlaySource(video);

    // Two facts the availability event does not carry, needed before a route
    // is ever seen: whether this engine exposes a picker at all (so the button
    // can appear and say "no devices found" itself), and whether the stream is
    // one AirPlay can actually forward the picture for.
    post({
      type: 'airplaySupport',
      picker: typeof video.webkitShowPlaybackTargetPicker === 'function',
      source: sourceKind(video),
    });
  }

  /// Measured on device against a live receiver: this returns true and opens
  /// the picker from a native evaluateJavaScript call, with no user gesture.
  /// The gesture worry that this comment used to carry was unfounded. Opening
  /// the picker is not the same as offloading, though — see attachAirPlaySource.
  function showAirPlay() {
    const v = staged || largestVideo();
    if (!v || typeof v.webkitShowPlaybackTargetPicker !== 'function') return false;
    try { v.webkitShowPlaybackTargetPicker(); return true; } catch (_) { return false; }
  }

  // --- Episode discovery --------------------------------------------------

  // "Episode 110", "Ep 12", "EP.5", or a bare number in a list of them.
  const EPISODE_RE = /\bep(isode)?\.?\s*\d+|^\s*\d{1,4}\s*$/i;
  const NEXT_RE = /\bnext\b/i;
  const PREV_RE = /\b(prev|previous)\b/i;

  function accessibleName(el) {
    return (el.getAttribute('aria-label') || el.getAttribute('title') ||
            el.textContent || '').replace(/\s+/g, ' ').trim();
  }

  /// Resolves a link and refuses anything off-site. Keeps a link to the
  /// current page, which the episode list needs: that entry is the one it
  /// marks, and the one the neighbours are measured from.
  function sameOriginURL(el) {
    const href = el.getAttribute('href');
    if (!href) return null;
    let url;
    try { url = new URL(href, location.href); } catch (_) { return null; }
    if (url.protocol !== 'https:' && url.protocol !== 'http:') return null;
    if (url.origin !== location.origin) return null;      // never leave the site
    return url.href;
  }

  /// A navigation target. Self-links are rejected here because "next episode"
  /// pointing at the page you are on is not a next episode.
  function sameOriginHref(el) {
    const url = sameOriginURL(el);
    if (!url) return null;
    // An anchor into this document — "#comments" on a hash-routed page — is
    // not a page either, however the current route reads.
    if (!routeFragment(new URL(url)) &&
        pageKey(url) === pageKey(location.href.split('#')[0])) return null;
    return pageKey(url) !== pageKey(location.href) ? url : null;
  }

  /// Activate the site's real episode link instead of loading its URL behind
  /// the site's back. React/Vue-style players attach their in-place episode
  /// switch to this click; a direct WKWebView load bypasses it and turns Next
  /// into a full page navigation. Returns false when discovery came from a
  /// non-anchor signal such as <link rel="next">, so native can use its normal
  /// validated load as a fallback.
  function navigateEpisode(href) {
    let wanted;
    try { wanted = new URL(href, location.href); } catch (_) { return false; }
    if (wanted.origin !== location.origin) return false;
    const key = pageKey(wanted.href);
    if (key === pageKey(location.href)) return false;

    for (const anchor of document.querySelectorAll('a[href]')) {
      const candidate = sameOriginURL(anchor);
      if (candidate && pageKey(candidate) === key) {
        anchor.click();
        return true;
      }
    }
    return false;
  }

  /// rel=next/prev is the only standard signal, so it wins. The text match is a
  /// fallback and is genuinely unreliable.
  ///
  /// ponytail: rel + accessible-name matching only. Ceiling: sites that label
  /// episode links with bare numbers or images are missed, and pagination on a
  /// non-episodic page can match. Deliberately does NOT infer the next URL by
  /// incrementing a number in the path — that silently sends people to the
  /// wrong page or a 404.
  function findEpisodes() {
    const found = { next: null, prev: null };

    for (const el of document.querySelectorAll('link[rel~="next"],a[rel~="next"]')) {
      found.next = sameOriginHref(el);
      if (found.next) break;
    }
    for (const el of document.querySelectorAll('link[rel~="prev"],a[rel~="prev"]')) {
      found.prev = sameOriginHref(el);
      if (found.prev) break;
    }

    if (!found.next || !found.prev) {
      for (const a of document.querySelectorAll('a[href]')) {
        const name = accessibleName(a);
        if (!name || name.length > 40) continue;
        if (!found.next && NEXT_RE.test(name) && !PREV_RE.test(name)) {
          found.next = sameOriginHref(a);
        }
        if (!found.prev && PREV_RE.test(name)) {
          found.prev = sameOriginHref(a);
        }
        if (found.next && found.prev) break;
      }
    }

    // Fall back to the episode list itself.
    //
    // Plenty of sites — aniwave among them — draw Prev and Next in their own
    // player bar with JavaScript and no rel attribute, no anchor and no "next"
    // text anywhere in the DOM. The whole episode list is right there as
    // ordinary links, though, so the neighbours of the current episode are a
    // far more reliable source than matching words.
    if (!found.next || !found.prev) {
      const neighbours = episodeNeighbours();
      found.next = found.next || neighbours.next;
      found.prev = found.prev || neighbours.prev;
    }
    return found;
  }

  /// The entries either side of the current one in the episode list.
  function episodeNeighbours() {
    const list = episodeList();
    if (list.length < 2) return { next: null, prev: null };

    // Episode lists are usually in order already, but a site that renders them
    // newest-first would give the wrong neighbours. When every entry carries a
    // number — from its text or its URL — trust the number over the DOM.
    const numbered = list.every(e => e.number !== null);
    const ordered = numbered
      ? [...list].sort((a, b) => a.number - b.number)
      : list;

    const at = ordered.findIndex(e => e.current);
    if (at < 0) return { next: null, prev: null };
    return {
      next: at + 1 < ordered.length ? ordered[at + 1].href : null,
      prev: at - 1 >= 0 ? ordered[at - 1].href : null,
    };
  }

  // --- Resuming after an episode navigation -------------------------------

  /// Native calls this after loading the next episode so theater carries across
  /// the page change instead of dropping the user on the raw page.
  ///
  /// Three things this has to do that entering theater by hand does not:
  /// start playback (the tap that would have done it happened on the previous
  /// page), tolerate a player that has not been laid out yet, and say so when
  /// it gives up — native is holding a curtain over the page until it hears
  /// back, and a silent failure leaves the user staring at it.
  let autoTheaterRun = null;

  function autoTheater(timeoutMs = 45000) {
    if (autoTheaterRun) return autoTheaterRun;
    const started = Date.now();
    autoTheaterRun = new Promise((resolve) => {
      let observer = null;
      let poll = null;
      let deadline = null;
      let settled = false;

      const finish = (ok) => {
        if (settled) return;
        settled = true;
        if (observer) observer.disconnect();
        if (poll) clearInterval(poll);
        if (deadline) clearTimeout(deadline);
        autoTheaterRun = null;
        if (!ok) post({ type: 'theaterFailed' });
        resolve(ok);
      };

      const attempt = () => {
        const elapsed = Date.now() - started;
        const video = resumeCandidate(elapsed);
        if (video) {
          const ok = enterTheater(video);
          // Autoplay is permitted: the web view sets
          // mediaTypesRequiringUserActionForPlayback = []. Without this the
          // next episode opened cleanly and sat there paused, which is most of
          // what "I have to press play again" was.
          if (ok && video.paused) video.play().catch(() => {});
          finish(ok);
        }
      };

      // The replacement iframe often creates its <video> only after an AJAX
      // response. Observe that transition instead of performing a short,
      // one-shot search. The low-rate poll covers layout/readiness changes,
      // which do not necessarily mutate the DOM.
      observer = new MutationObserver(attempt);
      observer.observe(document.documentElement, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['src'],
      });
      poll = setInterval(attempt, 500);
      deadline = setTimeout(() => finish(false), timeoutMs);
      // Defer the first attempt until after `autoTheaterRun` receives this
      // promise. An immediate success inside the Promise constructor would
      // otherwise clear the variable and then have the assignment restore the
      // already-resolved promise, preventing a later episode transition.
      queueMicrotask(attempt);
    });
    return autoTheaterRun;
  }

  /// `largestVideo` requires a non-zero box, which is right for attaching a
  /// button and wrong for resuming: a player that has not been laid out yet
  /// reports 0x0, so the poll walked straight past the video it was armed for
  /// and timed out on exactly the page it existed to handle.
  ///
  /// Graded rather than unconditional. A sized video always wins; a boxless one
  /// is only accepted after the grace period, because taking the first match
  /// immediately would stage a hidden thumbnail on a page whose real player is
  /// still mounting.
  function resumeCandidate(elapsed, graceMs = 3000) {
    const sized = largestVideo();
    if (sized) return sized;
    if (elapsed < graceMs) return null;
    for (const v of allVideos()) {
      if (v.currentSrc || v.src || v.readyState > 0 || v.querySelector('source')) {
        return v;
      }
    }
    return null;
  }

  function largestVideo() {
    let best = null, bestArea = 0;
    for (const v of allVideos()) {
      const r = v.getBoundingClientRect();
      const area = r.width * r.height;
      if (area > bestArea) { best = v; bestArea = area; }
    }
    return bestArea > 0 ? best : null;
  }

  // --- Interstitial / overlay blocking ------------------------------------

  let overlayBlocking = true;
  let blockedCount = 0;

  function isOurs(el) {
    return el.id === STYLE_ID || el.classList.contains(BTN_CLASS) ||
           el.hasAttribute('data-cp-keep');
  }

  /// `Node.contains` that crosses shadow boundaries, so an element painted
  /// inside a shadow tree still counts as belonging to the hosts above it.
  function containsDeep(el, node) {
    for (let n = node; n; n = n.parentNode || n.host) {
      if (n === el) return true;
    }
    return false;
  }

  /// Every element in the document, shadow trees included, and not only those
  /// under <body>: ad scripts append to documentElement too, and a dialog
  /// rendered by a custom element lives in its shadow root, where
  /// querySelectorAll cannot reach.
  ///
  /// Also the only place that knows every shadow root, so it is where they get
  /// put under observation. A MutationObserver does not cross a shadow
  /// boundary either: without this, filling a host's shadow tree is invisible,
  /// and an interstitial rendered there is never looked at.
  function deepElements(root = document, out = []) {
    for (const el of root.querySelectorAll('*')) {
      out.push(el);
      if (el.shadowRoot) {
        watchRoot(el.shadowRoot);
        deepElements(el.shadowRoot, out);
      }
    }
    return out;
  }

  const OBSERVE = {
    childList: true, subtree: true,
    // Three attributes, not all of them. `data-cp-blocked` because a page that
    // strips our mark would otherwise stay unblocked until something else
    // happened to move a node; `open` because a <dialog> interstitial arrives
    // by attribute, not by insertion; `style` because the usual way to show an
    // ad is to flip the display on markup that was already in the document.
    // `class` is left out deliberately — players churn it every frame.
    attributes: true,
    attributeFilter: ['data-cp-blocked', 'open', 'style'],
  };
  const watchedRoots = new WeakSet();
  let domObserver = null;

  function watchRoot(root) {
    if (!domObserver || watchedRoots.has(root)) return;
    watchedRoots.add(root);
    domObserver.observe(root, OBSERVE);
  }

  /// How much of `target` the rect `r` covers, 0..1.
  function overlapFraction(r, target) {
    const w = Math.max(0, Math.min(r.right, target.right) - Math.max(r.left, target.left));
    const h = Math.max(0, Math.min(r.bottom, target.bottom) - Math.max(r.top, target.top));
    const area = target.width * target.height;
    return area > 0 ? (w * h) / area : 0;
  }

  /// An invisible layer is usually the player's own gesture catcher, and
  /// hiding it breaks tap-to-play. An ad card paints something.
  function hasVisibleSurface(el, cs) {
    // A frame paints a whole document, so it is a surface even when this one
    // can see nothing in it. Without this an ad frame with no background and
    // opacity:0.01 — the clickjacking layer laid over a player to swallow the
    // tap that looks like Play — reads as empty and survives.
    //
    // This cannot catch the player itself: where this document has a video the
    // player is that <video>, and where it does not, looksLikeInterstitial
    // spares frames outright.
    if (el.tagName === 'IFRAME' || el.tagName === 'OBJECT' || el.tagName === 'EMBED') {
      return true;
    }

    const bg = cs.backgroundColor;
    if (bg && bg !== 'transparent' && !/^rgba\(0, 0, 0, 0\)$/.test(bg)) return true;
    if (cs.backgroundImage && cs.backgroundImage !== 'none') return true;
    if (el.textContent.trim().length > 0) return true;
    return !!el.querySelector('img, svg, a, button, input');
  }

  /// The old version asked "is this big and high z-index", which was wrong
  /// twice over: a modal card is smaller than the viewport, and inside a
  /// player's own stacking context `z-index: 10` is perfectly normal. Both
  /// gates let the "install a VPN to continue watching" dialog straight
  /// through.
  ///
  /// The real question is whether something is sitting on top of the video.
  /// `topAtVideo` is the element actually painted at the video's centre, which
  /// answers that exactly — no z-index guesswork — and naturally spares the
  /// player's own control bar, which does not cover the centre.
  function looksLikeInterstitial(el, ctx) {
    const { videoRect, topAtVideo, hosts = [] } = ctx;
    if (el === document.body || el === document.documentElement) return false;
    if (isOurs(el) || el.closest('[data-cp-keep]')) return false;
    if (el.hasAttribute('data-cp-blocked')) return false;
    // Never hide the thing the user came to watch.
    //
    // The querySelector checks below cover CONTAINERS of a video. They do not
    // cover the video itself, and a staged video matches every test this
    // function applies: theater gives it position:fixed, full-screen size, an
    // opaque background, and it is topmost at its own centre by definition. So
    // the next mutation pass hid it — decoded, playing, display:none.
    if (el.tagName === 'VIDEO' || el.hasAttribute('data-cp-stage')) return false;
    if (el.querySelector('video') || el.querySelector('[data-cp-stage]')) return false;
    // Neither querySelector above crosses a shadow boundary, so a custom
    // element wrapping its own <video> reads as an empty positioned box.
    if (hosts.some(host => el === host || el.contains(host))) return false;

    // Never hide a sign-in. The no-video branch below treats any large
    // positioned element as a gate, which is right for "verify you are human"
    // and wrong for a real login: measured on a Jellyfin server, whose login
    // view is a full-viewport positioned element over a poster backdrop, so it
    // was hidden and left the user staring at the background with no way in.
    // A consent gate does not ask for a password; a login does.
    //
    // Collected once per pass and crossing shadow boundaries, which
    // querySelector does not. That matters more now the scan reaches into
    // shadow trees: a login rendered by a web component would otherwise be a
    // large positioned box with nothing to mark it as one. It also costs
    // nothing on the pages — nearly all of them — that have no password field
    // at all.
    const { passwords = [] } = ctx;
    if (passwords.some(input => containsDeep(el, input))) return false;

    const cs = getComputedStyle(el);
    // Sticky counts too. It is fixed once it has stuck, and a negative margin
    // is all it takes to park one over the player from the start.
    if (cs.position !== 'fixed' && cs.position !== 'absolute'
        && cs.position !== 'sticky') {
      return false;
    }
    if (cs.display === 'none' || cs.visibility === 'hidden' || cs.opacity === '0') {
      return false;
    }

    const r = el.getBoundingClientRect();
    if (r.width < 40 || r.height < 40) return false;      // badges, close buttons
    if (!hasVisibleSurface(el, cs)) return false;

    if (videoRect) {
      // Must actually be painted over the video, not merely overlap its box:
      // an element behind the player can share the same coordinates.
      if (!topAtVideo || !containsDeep(el, topAtVideo)) return false;
      return overlapFraction(r, videoRect) >= 0.3;
    }

    // No video in THIS document — either the player lives in a cross-origin
    // frame, or nothing is playing yet and this is the "verify your browser"
    // gate that comes first.
    //
    // A cross-origin player iframe looks identical to a gate from here: the
    // querySelector('video') guard above cannot see into it, and the standard
    // responsive embed is position:absolute at 100% of its wrapper with a
    // black background. So spare the player embed — the frame itself, and
    // anything holding it.
    //
    // Only in this branch. When this document does have a video, the player is
    // that <video>, so an iframe painted over it is an ad and still goes.
    const { frame, frameRect } = ctx;
    if (frame && (el === frame || el.contains(frame))) return false;

    if (frameRect) {
      // The player frame stands in for the <video> this document has not got,
      // so the branch can ask the same question as the one above instead of
      // guessing from size: is this painted over the player?
      //
      // The old version could only guess, and spared anything that HELD a
      // frame — which handed a free pass to the dimmer of every ad dialog
      // served in one, because querySelector('iframe') found the ad's own
      // frame inside it. That is the whole shape of the "is your browser
      // Firefox?" smartlink: a fixed dimmer over the page, an iframe card in
      // the middle of it, and the episode still playing underneath.
      //
      // Two shapes count. Over the player is the obvious one. The other is
      // the dialog in the report: pinned to the viewport and centred on IT,
      // so with a 16:9 embed on a tall phone it sits mostly ABOVE the
      // episode and covers less than a third of it while still owning the
      // screen. Nothing a site pins to the viewport at this size is content
      // the user asked for — its header, footer and cookie bar are bands
      // across one edge, far too short for either test.
      const coversPlayer = overlapFraction(r, frameRect) >= 0.3;
      const coversScreen = cs.position === 'fixed'
          && r.width >= window.innerWidth * 0.5
          && r.height >= window.innerHeight * 0.25;
      if (!coversPlayer && !coversScreen) return false;

      // Aim the hit test at the candidate's own centre, not the player's, for
      // the same reason: the card need not cover the player's middle. It
      // still spares anything merely sharing the player's coordinates from
      // BEHIND — what is painted there is the frame, which such a box neither
      // is nor contains.
      //
      // One hit test per candidate, where the video branch does one per pass.
      // The coverage gates above knock all but a handful out first.
      const top = centreHit(r);
      return !!top && containsDeep(el, top);
    }

    // No player frame on the page at all. Fall back to full-page coverage,
    // and keep the old frame guard for the window before the frame exists.
    //
    // ponytail: costs us gates that are themselves iframes on a page with no
    // player. That trade is deliberate — a missed gate is one shield tap away,
    // a hidden player looks like the app is broken.
    if (el.tagName === 'IFRAME' || el.querySelector('iframe')) return false;

    // The frame guard above only works once the frame exists. aniwave's
    // <div id="player"> is an absolutely positioned black box that sits empty
    // until a server is picked, and the pass that ran in that window hid it —
    // the iframe then landed inside display:none and the player stayed black.
    // A gate has something to read or press; an empty box is a placeholder.
    if (!hasContent(el)) return false;

    return r.width >= window.innerWidth * 0.6
        && r.height >= window.innerHeight * 0.5;
  }

  function hasContent(el) {
    return el.textContent.trim().length > 0
        || !!el.querySelector('img, svg, canvas, picture, button, input, a, form');
  }

  /// The complement of the guard, for when the guess was already wrong: a
  /// container hidden as a gate that has since received the player frame is
  /// released. Only where this document has no video of its own — the same
  /// condition under which frames are spared — so an ad frame injected into
  /// a hidden interstitial over a real <video> stays hidden with it.
  ///
  /// Scoped twice over, because releasing on any frame let an ad dialog free
  /// itself — the ad's own iframe is a frame inside the hidden container:
  ///
  /// - only what was hidden as a GATE, the guess made when the page had no
  ///   player frame at all. An overlay hidden while a player frame existed was
  ///   not that guess and never needs undoing;
  /// - and only for a frame that scrolls with the page, the same test that
  ///   picks the player out in the first place. `playerFrame` cannot be reused
  ///   here: the container is display:none, so the frame inside it measures
  ///   0×0 and fails the size floor, which would leave the player hidden for
  ///   good — the exact deadlock this function exists to break.
  function releaseFramedBlocks(hasOwnVideo) {
    if (hasOwnVideo) return 0;
    let released = 0;
    for (const el of blockedElements()) {
      if (el.getAttribute('data-cp-blocked') !== 'gate') continue;
      const frame = el.tagName === 'IFRAME' ? el : el.querySelector('iframe');
      if (frame && !inFixedSubtree(frame)) {
        unmarkBlocked(el);
        released++;
      }
    }
    return released;
  }

  /// ponytail: walks every element in the body on each mutation batch, which is
  /// O(n) per frame, plus one hit test. Ceiling: noticeable on very large DOMs.
  /// Upgrade path: only examine added nodes from the MutationRecords.
  function blockOverlays() {
    if (!overlayBlocking) return 0;
    // The marker attribute is inert without the stylesheet, and on a page with
    // no playable video nothing else would ever inject it.
    ensureStyle();

    const video = largestVideo();
    const videoRect = video ? video.getBoundingClientRect() : null;
    // Once per pass, not once per candidate.
    const hosts = videoHosts();
    // The stand-in for the video when this document has none of its own, so
    // it is only worth finding in that case.
    const frame = video ? null : playerFrame();
    const frameRect = frame ? frame.getBoundingClientRect() : null;
    releaseFramedBlocks(!!video);

    // One hit test per pass, not per candidate.
    const ctx = {
      videoRect, hosts, frame, frameRect,
      topAtVideo: centreHit(videoRect),
    };

    // Which guess this was, so `releaseFramedBlocks` can undo the one that
    // needs undoing and leave the other alone.
    const reason = (videoRect || frameRect) ? 'overlay' : 'gate';

    const all = deepElements();
    ctx.passwords = all.filter(el =>
      el.tagName === 'INPUT' && el.getAttribute('type') === 'password');

    let hidden = 0;
    for (const el of all) {
      if (el.hasAttribute('data-cp-blocked')) { hideHard(el); continue; }
      if (looksLikeInterstitial(el, ctx)) {
        markBlocked(el, reason);
        hidden++;
      }
    }

    // An interstitial is a card sitting on a backdrop, and only whichever is
    // topmost is caught per pass. Peel the remaining layers now rather than
    // leaving the dimmer behind. Whatever the pass aimed at — the video, or
    // the player frame standing in for it — is what the layers sit on.
    const target = videoRect || frameRect;
    if (hidden && target) {
      for (let peel = 0; peel < 3; peel++) {
        const again = blockLayerUnder(target, ctx);
        if (!again) break;
        hidden += again;
      }
    }

    if (hidden) {
      blockedCount += hidden;
      document.documentElement.setAttribute('data-cp-unlock', '');
      post({ type: 'blocked', count: blockedCount });
    }
    return hidden;
  }

  /// What is painted at the centre of `rect`, or null when there is no rect or
  /// the centre is off screen.
  function centreHit(rect) {
    if (!rect || rect.width <= 0 || rect.height <= 0) return null;
    const cx = rect.left + rect.width / 2;
    const cy = rect.top + rect.height / 2;
    if (cx < 0 || cy < 0 || cx > window.innerWidth || cy > window.innerHeight) return null;
    // elementFromPoint stops at a shadow host and reports the host itself.
    // Descend to what is actually painted, so a dialog rendered inside a
    // custom element can be recognised as the thing on top.
    let top = document.elementFromPoint(cx, cy);
    while (top && top.shadowRoot) {
      const inner = top.shadowRoot.elementFromPoint(cx, cy);
      if (!inner || inner === top) break;
      top = inner;
    }
    return top;
  }

  function blockLayerUnder(targetRect, ctx) {
    const top = centreHit(targetRect);
    if (!top) return 0;
    // Re-ask about the layer now on top, against the same target this pass is
    // aiming at, so the player itself stays spared. The video branch wants the
    // new topmost handed to it; the frame branch runs its own hit test per
    // candidate and needs no help.
    const next = ctx.videoRect ? { ...ctx, topAtVideo: top } : ctx;
    if (!looksLikeInterstitial(top, next)) return 0;
    markBlocked(top, 'overlay');
    return 1;
  }

  /// Escape hatch. Blocking by shape will sometimes catch a real dialog — a
  /// cookie consent or a login prompt — and the user needs a way back.
  /// The stylesheet is the cheap way to hide a block, but it does not always
  /// win. A document stylesheet never reaches inside a shadow root, and an
  /// inline `display: … !important` on the ad itself outranks any author rule
  /// — both are ways an interstitial stays on screen wearing our mark. So ask
  /// the browser what it actually computed, and only where the mark failed to
  /// land, overrule the element's own style. The value displaced is parked on
  /// the element so the shield can hand it back.
  function markBlocked(el, reason) {
    el.setAttribute('data-cp-blocked', reason);
    hideHard(el);
  }

  /// Make the mark stick. Called again on every pass for anything already
  /// marked, because an ad that lost the first round comes back and sets its
  /// display again on a timer — and a marked element is not re-examined, so
  /// without this the last write would be theirs.
  ///
  /// Costs nothing in the ordinary case: the stylesheet has already hidden it
  /// and this returns on the first line. Only the first displaced value is
  /// parked, so a shield tap hands back what the page had, not what the ad
  /// wrote while fighting us.
  function hideHard(el) {
    if (getComputedStyle(el).display === 'none') return;
    if (!el.hasAttribute('data-cp-display')) {
      const prior = el.style.getPropertyValue('display');
      const priority = el.style.getPropertyPriority('display');
      el.setAttribute('data-cp-display', priority ? `${prior} !${priority}` : prior);
    }
    el.style.setProperty('display', 'none', 'important');
  }

  function unmarkBlocked(el) {
    el.removeAttribute('data-cp-blocked');
    const prior = el.getAttribute('data-cp-display');
    if (prior === null) return;
    el.removeAttribute('data-cp-display');
    const bang = prior.indexOf(' !');
    if (!prior) el.style.removeProperty('display');
    else if (bang < 0) el.style.setProperty('display', prior);
    else el.style.setProperty('display', prior.slice(0, bang), prior.slice(bang + 2));
  }

  function blockedElements() {
    return deepElements().filter(el => el.hasAttribute('data-cp-blocked'));
  }

  function unblockOverlays() {
    for (const el of blockedElements()) {
      unmarkBlocked(el);
    }
    document.documentElement.removeAttribute('data-cp-unlock');
    blockedCount = 0;
    post({ type: 'blocked', count: 0 });
  }

  function setOverlayBlocking(on) {
    overlayBlocking = !!on;
    if (overlayBlocking) blockOverlays(); else unblockOverlays();
    return overlayBlocking;
  }

  // --- Entry button -------------------------------------------------------

  function makeButton(video, text, label, onTap) {
    const btn = document.createElement('button');
    btn.__cpVideo = video;            // so orphans can be swept when it swaps
    btn.type = 'button';              // inside a <form>, the default is submit
    btn.className = BTN_CLASS;
    btn.setAttribute('data-cp-keep', '');
    btn.setAttribute('aria-label', label);
    btn.textContent = text;
    // Theater may already be showing. `stage()` can only mark the buttons that
    // existed when it ran, and on a resumed episode the video is staged before
    // the page has finished mounting — so a button created afterwards appeared
    // on top of the player. Seen on device, not in any fixture.
    if (isTheater()) btn.dataset.cpStaged = '1';
    btn.addEventListener('click', (e) => {
      e.preventDefault();             // the page may wrap the video in an <a>
      e.stopPropagation();
      onTap();
    });
    return btn;
  }

  function attachButton(video) {
    if (!video || !video.parentElement) return;

    // Track the button ITSELF, not a flag on the video. A boolean marker meant
    // that once anything removed the button — the orphan sweep, or the page's
    // own re-render — the video stayed marked as done and never got another
    // one. That is how every button on the page disappeared.
    if (video.__cpBtn && video.__cpBtn.isConnected) return;

    // Pages embed dozens of thumbnail-sized <video> elements (a Wikimedia
    // category page has ~200). Only offer the control on something watchable.
    const r = video.getBoundingClientRect();
    if (r.width < 200 || r.height < 100) return;

    // The button is position:absolute, so it lands on the video only if the
    // parent establishes a containing block. On a static parent it flies off to
    // whatever ancestor is positioned — usually the top-left of the page, where
    // it looks like no button was added at all.
    const parent = video.parentElement;
    if (getComputedStyle(parent).position === 'static') {
      parent.style.position = 'relative';
      parent.dataset.cpAnchored = '1';
    }

    // A player inside a shadow root needs the stylesheet in that root.
    const root = video.getRootNode();
    ensureStyle(root === document ? document : root);

    const theater = makeButton(video, 'Watch clean', 'Watch clean',
                               () => watchClean(video));
    video.parentElement.appendChild(theater);
    video.__cpBtn = theater;

    if (canNativeFullscreen(video)) {
      const full = makeButton(video, 'Fullscreen', 'Open in the system player',
                              () => nativeFullscreen(video));
      full.dataset.cpSecondary = '1';
      video.parentElement.appendChild(full);
    }
  }

  /// A player that swaps its <video> out leaves the old button stacked on top of
  /// the new one, eating its taps. Seen on commons.wikimedia.org.
  function sweepOrphans() {
    for (const b of allButtons()) {
      if (!b.__cpVideo || !b.__cpVideo.isConnected) {
        const parent = b.parentElement;
        b.remove();
        // Give back the position we borrowed, once nothing of ours needs it.
        if (parent && parent.dataset && parent.dataset.cpAnchored === '1'
            && !parent.querySelector('.' + BTN_CLASS)) {
          parent.style.position = '';
          delete parent.dataset.cpAnchored;
        }
      }
    }
  }

  function allButtons(root = document) {
    const found = [];
    for (const b of root.querySelectorAll('.' + BTN_CLASS)) found.push(b);
    for (const el of root.querySelectorAll('*')) {
      if (el.shadowRoot) {
        for (const b of allButtons(el.shadowRoot)) found.push(b);
      }
    }
    return found;
  }

  function scan(root = document) {
    sweepOrphans();
    for (const v of allVideos(root)) attachButton(v);
    checkStaged();
  }

  // --- A player that leaves ------------------------------------------------

  /// A single-page app does not reload between items. Jellyfin, Emby and Plex
  /// route in the hash and rebuild their player in place, so an episode change
  /// there produces no new document, no `ready`, and nothing for native's
  /// resume to hook. What it does produce is the staged <video> leaving the
  /// DOM — with a replacement arriving a moment later, or not at all when the
  /// app went back to a page with no player.
  ///
  /// Follow the player rather than the page: keep the stage marks up as a
  /// curtain, poll for a replacement the way resume does, and hand theater over
  /// to it. Give up honestly when nothing turns up, so the user gets the page
  /// and its controls back instead of black under a set of dead buttons.
  const REPLACEMENT_TIMEOUT_MS = 8000;
  let following = null;              // { lost, deadline, timer }

  function checkStaged(timeoutMs = REPLACEMENT_TIMEOUT_MS) {
    // The hosted frame in the main document, same story: the site swapped
    // its player iframe. There is no agent left in the old frame to say so.
    if (hosted && !hosted.isConnected) {
      unhostTheater();
      post({ type: 'theaterEnded' });
    }
    if (!staged || staged.isConnected) return;
    if (following && following.lost === staged) {
      following.deadline = Math.min(following.deadline, Date.now() + timeoutMs);
      return;
    }
    following = { lost: staged, deadline: Date.now() + timeoutMs, timer: 0 };
    const started = Date.now();
    const attempt = () => {
      // Someone else — Close, or a real navigation — moved on already.
      if (!following || staged !== following.lost) { following = null; return; }
      const video = resumeCandidate(Date.now() - started);
      if (video && video !== staged) {
        following = null;
        // enterTheater posts theaterEnded for the old element and theater for
        // the new one, in that order, so native banks the old position and
        // then re-syncs its chrome to the replacement.
        enterTheater(video);
        return;
      }
      if (Date.now() > following.deadline) {
        following = null;
        exitTheater();
        return;
      }
      following.timer = setTimeout(attempt, 200);
    };
    attempt();
  }

  // Coalesce mutation storms into one pass per frame; ad scripts mutate the
  // DOM constantly and an unthrottled observer would rescan hundreds of times.
  let passPending = false;
  function schedulePass() {
    if (passPending) return;
    passPending = true;
    requestAnimationFrame(() => { passPending = false; scan(); blockOverlays(); });
  }

  /// The slow lane, for the wake-ups that are not a node arriving: scrolling,
  /// rotating, and attribute edits. A pass walks the whole DOM and reads a
  /// computed style per element, so running one per frame through a scroll or
  /// a progress-bar animation is the kind of thing that makes a page stutter.
  /// These can afford to wait.
  const SLOW_PASS_MS = 250;
  let slowTimer = 0;
  function scheduleThrottledPass() {
    if (slowTimer || passPending) return;
    slowTimer = setTimeout(() => {
      slowTimer = 0;
      scan();
      blockOverlays();
    }, SLOW_PASS_MS);
  }

  /// Announces this frame to the native side, once.
  ///
  /// Resuming theater after an episode change has to run in the frame holding
  /// the video, and on the sites this app exists for that is a cross-origin
  /// iframe. `evaluateJavaScript(in: nil)` only ever reaches the main frame, and
  /// there is no API to reach every frame — but a frame that has messaged us
  /// hands over its WKFrameInfo, which can be addressed directly.
  let announced = false;
  function announce() {
    if (announced) return;
    announced = true;
    post({ type: 'ready', ...frameMetrics() });
  }

  // A subframe navigation has no frame-specific WKNavigationDelegate callback.
  // Tell native while this document still owns its fid so per-frame state can
  // be removed. A page restored from the back-forward cache announces again.
  addEventListener('pagehide', () => post({ type: 'frameGone' }));
  addEventListener('pageshow', (event) => {
    if (!event.persisted) return;
    announced = false;
    announce();
  });

  domObserver = new MutationObserver((records) => {
    let structural = false;
    let needsPass = false;
    for (const rec of records) {
      if (rec.type === 'childList') { structural = true; continue; }
      // An element we have already hidden having its style rewritten is the ad
      // fighting back on its own timer. Answer that here and now: a full pass
      // is 250ms away, and a quarter second of ad, several times a second, is
      // the ad winning. Re-asserting is one style write and no DOM walk, and
      // it settles immediately — our own write comes back as a record whose
      // element is already hidden, which this leaves alone.
      if (rec.attributeName === 'style' && rec.target.nodeType === 1
          && rec.target.hasAttribute('data-cp-blocked')) {
        hideHard(rec.target);
        continue;
      }
      needsPass = true;
    }
    if (structural) schedulePass();
    else if (needsPass) scheduleThrottledPass();
  });
  watchRoot(document.documentElement);

  // An overlay whose centre is off screen cannot be hit-tested, and a rotation
  // changes every rect on the page. Neither is a mutation, so without these a
  // scroll could bring an untouched ad into view.
  addEventListener('scroll', scheduleThrottledPass, { passive: true, capture: true });
  addEventListener('resize', scheduleThrottledPass, { passive: true });
  addEventListener('orientationchange', scheduleThrottledPass, { passive: true });
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => { schedulePass(); announce(); });
  } else {
    ensureStyle();
    scan();
    blockOverlays();
    announce();
  }

  // Only what the native side or the tests actually call. Everything else is
  // reachable from in here without being on the bridge.
  window.__cp = {
    enterTheater, exitTheater, isTheater, autoTheater,
    hostTheater, unhostTheater, largestFrame,
    togglePlay, seek, skip, beginScrub, setRate, setVolume,
    armEpisodeTransition,
    textTracks, selectTextTrack, setObjectFit, selectSource, togglePiP,
    findEpisodes, episodeList, navigateEpisode,
    largestVideo, allVideos, resumeCandidate, scan,
    checkStaged,
    showAirPlay, nativeFullscreen, untrackAirPlay, isManifestURL,
    streamCandidates, sourceKind, attachAirPlaySource,
    blockOverlays, setOverlayBlocking,
  };
})();
