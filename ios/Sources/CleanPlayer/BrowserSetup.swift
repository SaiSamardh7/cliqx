import WebKit

/// Forwards script messages without retaining the target.
///
/// `WKUserContentController` retains its handler strongly, so passing `self`
/// directly creates self -> webView -> configuration -> controller -> self and
/// leaks the entire browser.
public final class WeakScriptBridge: NSObject, WKScriptMessageHandler {
    public weak var target: WKScriptMessageHandler?

    public init(_ target: WKScriptMessageHandler) { self.target = target }

    public func userContentController(_ controller: WKUserContentController,
                                      didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

public enum BrowserSetup {
    /// A named world the page cannot see into, forge messages from, or
    /// monkey-patch.
    public static let world = WKContentWorld.world(name: "CleanPlayer")

    /// `popupGuardJS` is injected into the page's own world, not ours: it
    /// replaces `window.open`, which an isolated world cannot reach.
    /// `privateBrowsing` swaps in a non-persistent data store: cookies, cache,
    /// local storage and IndexedDB live in memory and are gone when the store
    /// is released. It has to be decided here because a web view's data store
    /// cannot be changed after the view is created.
    public static func makeConfiguration(agentJS: String,
                                         popupGuardJS: String = "",
                                         privateBrowsing: Bool = false) -> WKWebViewConfiguration {
        let cfg = WKWebViewConfiguration()
        if privateBrowsing { cfg.websiteDataStore = .nonPersistent() }
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.allowsPictureInPictureMediaPlayback = true
        cfg.userContentController.addUserScript(
            WKUserScript(source: agentJS,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false,   // every frame
                         in: world)
        )
        if !popupGuardJS.isEmpty {
            cfg.userContentController.addUserScript(
                WKUserScript(source: popupGuardJS,
                             injectionTime: .atDocumentStart,
                             forMainFrameOnly: false,
                             in: .page)
            )
        }
        return cfg
    }

    /// Note `add(_:contentWorld:name:)`. `addScriptMessageHandler(_:...)` is the
    /// *WithReply* overload and does not accept a plain WKScriptMessageHandler.
    ///
    /// Everything below takes the web view rather than the configuration.
    /// `WKWebViewConfiguration` is copied at init, but the copy is shallow —
    /// the userContentController is shared by reference, so mutating the
    /// original would in fact still work. Going through `webView.configuration`
    /// just removes the need to know that.
    public static func installBridge(_ handler: WKScriptMessageHandler,
                                     on webView: WKWebView,
                                     name: String = "cp") {
        webView.configuration.userContentController.add(
            WeakScriptBridge(handler), contentWorld: world, name: name)
    }
}
