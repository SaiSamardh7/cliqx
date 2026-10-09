// Wraps the shared agent so it starts once the document has a root element.
//
// The agent ends its setup with `watchRoot(document.documentElement)` before it
// assigns `window.__cp`. In Chromium — and therefore in Android WebView — a
// document-start script runs BEFORE the parser creates <html>, so that argument
// is null, `WeakSet.add(null)` throws, the agent's IIFE unwinds and `__cp` is
// never assigned. Every feature is then silently absent, which looks exactly
// like the app not working.
//
// WebKit creates the root element before running `atDocumentStart` scripts, so
// iOS never sees this and the agent needs no change to keep working there. The
// one-line guard in agent.js that would make this wrapper unnecessary is
// described in android/README.md; it is not applied here because the iOS app is
// mid-release and that file ships in it.
//
// Deferring costs nothing the agent cares about: everything it does needs a DOM
// to look at. What must NOT be deferred is popupguard, which replaces
// `window.open` and `HTMLElement.prototype.click` — no DOM needed — and so is
// still injected at true document start.
(() => {
  'use strict';

  const start = () => {
    /*{{AGENT}}*/
  };

  if (document.documentElement) {
    start();
    return;
  }

  // The root element appears on the parser's first tick, well under a
  // millisecond away. A MutationObserver is not an option: there is no node to
  // observe yet, which is the whole problem.
  let attempts = 0;
  const timer = setInterval(() => {
    if (document.documentElement) {
      clearInterval(timer);
      start();
    } else if (++attempts > 1000) {
      // A document that never gains a root element is not one the agent can
      // work on. Stop rather than spin for the lifetime of the frame.
      clearInterval(timer);
    }
  }, 0);
})();
