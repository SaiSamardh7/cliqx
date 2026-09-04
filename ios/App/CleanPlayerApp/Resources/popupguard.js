// Runs in the PAGE content world — it has to, because it replaces a global the
// page itself calls. That means the page can see and undo it; there is no way
// around that trade-off, and an isolated world cannot override window.open.
//
// Approach studied from how content blockers gate popups, implemented from
// scratch: no Brave code is used here (brave-core/ios is MPL-2.0, which is
// file-level copyleft and would attach to any file copied in).
(() => {
  'use strict';
  if (window.__cpPopupGuard) return;
  window.__cpPopupGuard = true;
  window.__cpPopupsBlocked = 0;

  const nativeOpen = window.open;

  /// A popunder fires from a handler bound to the whole document, so "a click
  /// happened recently" is not enough to tell it from a real link. The thing
  /// that actually separates them is whether the user activated a link.
  function fromRealLink() {
    const e = window.event;
    if (!e || (e.type !== 'click' && e.type !== 'auxclick')) return false;
    const target = e.target;
    if (!target || typeof target.closest !== 'function') return false;
    return !!target.closest('a[href]');
  }

  /// Returning null makes page scripts throw, which breaks the page far more
  /// visibly than the ad did. A dead stub keeps them running.
  function stubWindow() {
    const noop = () => {};
    return {
      closed: true, opener: null, name: '', location: { href: '', replace: noop, assign: noop },
      document: { write: noop, writeln: noop, close: noop },
      focus: noop, blur: noop, close: noop, print: noop,
      postMessage: noop, addEventListener: noop, removeEventListener: noop,
      moveTo: noop, resizeTo: noop, scrollTo: noop,
    };
  }

  window.open = function (url, name, features) {
    if (!fromRealLink()) {
      window.__cpPopupsBlocked++;
      return stubWindow();
    }
    return nativeOpen.call(window, url, name, features);
  };

  // While theater is showing, the page must not be able to take the screen.
  //
  // WebKit element fullscreen renders in a layer ABOVE the app's own views, so
  // a player that calls requestFullscreen when playback starts hides the native
  // player chrome completely: no controls, no status bar, and no way back
  // except the hardware gesture. Several mobile players do exactly that on
  // play, and Watch clean starts playback.
  //
  // This lives in popupguard rather than the agent because it has to run in the
  // PAGE world — an isolated world cannot replace the page's own methods. The
  // two worlds coordinate through the attribute the agent already sets on
  // documentElement, which is readable from both.
  const inTheater = () =>
    document.documentElement.hasAttribute('data-cp-theater');

  for (const [proto, name] of [
    [Element.prototype, 'requestFullscreen'],
    [Element.prototype, 'webkitRequestFullscreen'],
    [Element.prototype, 'webkitRequestFullScreen'],
    [window.HTMLVideoElement && HTMLVideoElement.prototype, 'webkitEnterFullscreen'],
  ]) {
    if (!proto || typeof proto[name] !== 'function') continue;
    const native = proto[name];
    proto[name] = function (...args) {
      // Theater is already full screen. Anything asking for more is the page
      // trying to draw over controls the user needs.
      if (inTheater()) return Promise.resolve();
      return native.apply(this, args);
    };
  }

  // Some popunders skip window.open and synthesise a detached anchor with
  // target=_blank, then click it. A click on an anchor that was never in the
  // document is not something a user can do.
  const nativeClick = HTMLElement.prototype.click;
  HTMLElement.prototype.click = function () {
    if (this instanceof HTMLAnchorElement &&
        this.target === '_blank' && !this.isConnected) {
      window.__cpPopupsBlocked++;
      return;
    }
    return nativeClick.call(this);
  };
})();
