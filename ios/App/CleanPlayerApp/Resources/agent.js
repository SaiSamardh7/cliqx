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

  function post(payload) {
    try { window.webkit?.messageHandlers?.cp?.postMessage(payload); } catch (_) {}
  }

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
    for (const el of document.querySelectorAll(
      '[data-cp-hidden],[data-cp-untrap],[data-cp-stage]'
    )) {
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
    if (staged) post({ type: 'playback', playing: !staged.paused });
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

  function beginScrub() { scrubbing = true; return true; }

  function seek(to) {
    if (!staged) return false;
    const d = finiteDuration(staged);
    // Page-supplied only in the sense that the native bar computed it from a
    // duration this same element reported; clamp anyway.
    const target = Math.max(0, d > 0 ? Math.min(to, d) : to);
    staged.currentTime = target;
    scrubbing = false;
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
  function episodeList() {
    const seen = new Set();
    const out = [];
    for (const a of document.querySelectorAll('a[href]')) {
      const name = accessibleName(a);
      if (!name || name.length > 60) continue;
      if (!EPISODE_RE.test(name)) continue;
      const href = sameOriginURL(a);
      if (!href || seen.has(href)) continue;
      seen.add(href);
      out.push({ label: name.trim(), href, current: href === location.href });
      if (out.length >= 200) break;
    }
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

    post({ type: 'theater', airplay: airplayAvailable, pip: canPiP() });
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
      restoreInline(staged);
      scrubbing = false;
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

  function trackAirPlay(video) {
    airplayAvailable = false;
    if (typeof video.webkitShowPlaybackTargetPicker !== 'function') return;
    video.setAttribute('x-webkit-airplay', 'allow');
    video.addEventListener('webkitplaybacktargetavailabilitychanged', (e) => {
      airplayAvailable = e.availability === 'available';
      post({ type: 'airplay', available: airplayAvailable });
    });
  }

  /// ponytail: WebKit may require a user gesture for the route picker, and a
  /// native evaluateJavaScript call does not carry one. Ceiling: if this proves
  /// to need a gesture, AirPlay has to come from Control Center or from Mode B's
  /// native fullscreen controls instead. Untestable on the Simulator, which
  /// never reports an available route.
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
            el.textContent || '').trim();
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
    return (url && url !== location.href) ? url : null;
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
    // newest-first would give the wrong neighbours. When every label is a plain
    // number, trust the number over the DOM.
    const numbered = list.every(e => /^\s*\d{1,4}\s*$/.test(e.label));
    const ordered = numbered
      ? [...list].sort((a, b) => parseInt(a.label, 10) - parseInt(b.label, 10))
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
  function autoTheater(timeoutMs = 8000) {
    const started = Date.now();
    return new Promise((resolve) => {
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
          if (!ok) post({ type: 'theaterFailed' });
          resolve(ok);
          return;
        }
        if (elapsed > timeoutMs) {
          post({ type: 'theaterFailed' });
          resolve(false);
          return;
        }
        setTimeout(attempt, 200);
      };
      attempt();
    });
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
    if (el.tagName === 'IFRAME') return true;

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
  function looksLikeInterstitial(el, videoRect, topAtVideo) {
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

    const cs = getComputedStyle(el);
    if (cs.position !== 'fixed' && cs.position !== 'absolute') return false;
    if (cs.display === 'none' || cs.visibility === 'hidden' || cs.opacity === '0') {
      return false;
    }

    const r = el.getBoundingClientRect();
    if (r.width < 40 || r.height < 40) return false;      // badges, close buttons
    if (!hasVisibleSurface(el, cs)) return false;

    if (videoRect) {
      // Must actually be painted over the video, not merely overlap its box:
      // an element behind the player can share the same coordinates.
      if (!topAtVideo || !(el === topAtVideo || el.contains(topAtVideo))) return false;
      return overlapFraction(r, videoRect) >= 0.3;
    }

    // No video in THIS document — the "verify your browser" gate appears
    // before the player. Fall back to full-page coverage.
    //
    // But a cross-origin player iframe looks identical from here: the
    // querySelector('video') guard above cannot see into it, and the standard
    // responsive embed is position:absolute at 100% of its wrapper with a
    // black background. That is exactly the shape matched below, so without
    // this the app hides the video the user came to watch and leaves a blank
    // page. Spare anything that is, or holds, a frame.
    //
    // Only in this branch. When this document does have a video, the player is
    // that <video>, so an iframe painted over it is an ad and still goes.
    //
    // ponytail: costs us gates that are themselves iframes. That trade is
    // deliberate — a missed gate is one shield tap away, a hidden player looks
    // like the app is broken.
    if (el.tagName === 'IFRAME' || el.querySelector('iframe')) return false;

    return r.width >= window.innerWidth * 0.6
        && r.height >= window.innerHeight * 0.5;
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

    // One hit test per pass, not per candidate.
    let topAtVideo = null;
    if (videoRect && videoRect.width > 0 && videoRect.height > 0) {
      const cx = videoRect.left + videoRect.width / 2;
      const cy = videoRect.top + videoRect.height / 2;
      if (cx >= 0 && cy >= 0 && cx <= window.innerWidth && cy <= window.innerHeight) {
        topAtVideo = document.elementFromPoint(cx, cy);
      }
    }

    let hidden = 0;
    for (const el of document.querySelectorAll('body *')) {
      if (looksLikeInterstitial(el, videoRect, topAtVideo)) {
        el.setAttribute('data-cp-blocked', '');
        hidden++;
      }
    }

    // An interstitial is a card sitting on a backdrop, and only whichever is
    // topmost is caught per pass. Peel the remaining layers now rather than
    // leaving the dimmer behind.
    if (hidden && videoRect) {
      for (let peel = 0; peel < 3; peel++) {
        const again = blockLayerUnder(videoRect);
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

  function blockLayerUnder(videoRect) {
    const cx = videoRect.left + videoRect.width / 2;
    const cy = videoRect.top + videoRect.height / 2;
    if (cx < 0 || cy < 0 || cx > window.innerWidth || cy > window.innerHeight) return 0;
    const top = document.elementFromPoint(cx, cy);
    if (!top || !looksLikeInterstitial(top, videoRect, top)) return 0;
    top.setAttribute('data-cp-blocked', '');
    return 1;
  }

  /// Escape hatch. Blocking by shape will sometimes catch a real dialog — a
  /// cookie consent or a login prompt — and the user needs a way back.
  function unblockOverlays() {
    for (const el of document.querySelectorAll('[data-cp-blocked]')) {
      el.removeAttribute('data-cp-blocked');
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
  }

  // Coalesce mutation storms into one pass per frame; ad scripts mutate the
  // DOM constantly and an unthrottled observer would rescan hundreds of times.
  let passPending = false;
  function schedulePass() {
    if (passPending) return;
    passPending = true;
    requestAnimationFrame(() => { passPending = false; scan(); blockOverlays(); });
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
    post({ type: 'ready' });
  }

  new MutationObserver(schedulePass).observe(document.documentElement, {
    childList: true, subtree: true
  });
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
    togglePlay, seek, skip, beginScrub, setRate,
    textTracks, selectTextTrack, setObjectFit, selectSource, togglePiP,
    findEpisodes, episodeList, largestVideo, allVideos, resumeCandidate, scan,
    showAirPlay, nativeFullscreen,
    blockOverlays, setOverlayBlocking,
  };
})();
