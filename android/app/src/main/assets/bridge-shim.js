// Injected immediately BEFORE the shared agent, in every frame.
//
// The agent posts to `window.webkit.messageHandlers.cp` because it was written
// for WKWebView. Rather than fork 98KB of tested heuristics to change one call
// site, this supplies that shape on top of Android's bridge. The agent stays
// byte-identical to the file iOS ships, and the 420 Playwright specs keep
// covering both platforms.
//
// Two differences from iOS are structural and cannot be shimmed away:
//
//  1. There are no content worlds in Android WebView. The agent runs in the
//     page world, so `window.__cp` is visible to the page. On iOS it is hidden
//     in a named WKContentWorld. A hostile page can therefore read or clobber
//     it here; see android/README.md.
//  2. `addJavascriptInterface` marshals strings, not objects, so every payload
//     is serialised here and parsed natively.
(() => {
  'use strict';
  if (window.webkit?.messageHandlers?.cp) return;

  const native = window.__cliqxNative;
  // Absent when the bridge failed to attach. The agent's own `post` is wrapped
  // in try/catch and optional chaining, so leaving this undefined degrades to
  // a silent no-op rather than throwing out of the agent's IIFE and taking
  // window.__cp with it.
  if (!native || typeof native.post !== 'function') return;

  const handler = {
    postMessage(payload) {
      try {
        native.post(JSON.stringify(payload));
      } catch (_) {
        // A payload with a cycle or a BigInt would throw here. Dropping one
        // message is correct; breaking the agent is not.
      }
    },
  };

  // `webkit` may already exist on a page that sniffs for it. Extend rather
  // than replace, and do not make the property non-writable: the agent only
  // ever reads it, and a frozen global is itself a fingerprint.
  const webkit = window.webkit || (window.webkit = {});
  const handlers = webkit.messageHandlers || (webkit.messageHandlers = {});
  handlers.cp = handler;
})();
