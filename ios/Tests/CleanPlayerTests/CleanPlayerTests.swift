import WebKit
import XCTest
@testable import CleanPlayer

final class MessageSink: NSObject, WKScriptMessageHandler {
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {}
}

final class CleanPlayerTests: XCTestCase {
    // Bug: userContentController.add(self, ...) retains strongly -> leak.
    @MainActor
    func testWeakBridgeDoesNotRetainItsTarget() {
        let controller = WKUserContentController()
        weak var weakSink: MessageSink?
        autoreleasepool {
            let sink = MessageSink()
            weakSink = sink
            controller.add(WeakScriptBridge(sink),
                           contentWorld: BrowserSetup.world, name: "cp")
        }
        XCTAssertNil(weakSink, "the controller must not keep the target alive")
    }

    // NOT a bug, contrary to my earlier claim. WKWebViewConfiguration is copied
    // at init, but the copy is SHALLOW: the userContentController is shared by
    // reference, so adding scripts or rule lists to the original still works.
    @MainActor
    func testConfigurationCopyStillSharesTheUserContentController() {
        let cfg = BrowserSetup.makeConfiguration(agentJS: "void 0;")
        let webView = WKWebView(frame: .zero, configuration: cfg)

        XCTAssertFalse(webView.configuration === cfg,
                       "the configuration itself is copied")
        XCTAssertTrue(webView.configuration.userContentController
                        === cfg.userContentController,
                      "but the controller is shared by reference")

        let baseline = webView.configuration.userContentController.userScripts.count
        cfg.userContentController.addUserScript(
            WKUserScript(source: "void 1;", injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true))

        XCTAssertEqual(webView.configuration.userContentController.userScripts.count,
                       baseline + 1, "so late additions DO reach the live web view")
    }
}
