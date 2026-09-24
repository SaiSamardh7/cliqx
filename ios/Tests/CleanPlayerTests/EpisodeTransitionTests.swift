import UIKit
import WebKit
import XCTest
@testable import CleanPlayer

@MainActor
final class EpisodeTransitionTests: XCTestCase {
    func testCanonicalSameSiteChangeKeepsResumeArmed() throws {
        let expected = try XCTUnwrap(URL(string: "https://watch.example.com/show/episode-2"))
        let canonical = try XCTUnwrap(URL(string: "https://www.example.com/watch/episode-2?server=2"))
        let attacker = try XCTUnwrap(URL(string: "https://example.net/watch/episode-2"))

        XCTAssertTrue(EpisodeTransition.mayResume(expected: expected, current: canonical))
        XCTAssertFalse(EpisodeTransition.mayResume(expected: expected, current: attacker))
    }

    func testOutgoingPlaybackCannotCompleteUntilItsSourceChanges() {
        XCTAssertFalse(EpisodeTransition.playbackCompletesResume(
            isFromOutgoingFrame: true, outgoingSourceChanged: false))
        XCTAssertTrue(EpisodeTransition.playbackCompletesResume(
            isFromOutgoingFrame: true, outgoingSourceChanged: true))
        XCTAssertTrue(EpisodeTransition.playbackCompletesResume(
            isFromOutgoingFrame: false, outgoingSourceChanged: false))
    }

    func testPageWorldControlRunsSitesRealAJAXHandler() async throws {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        let webView = WKWebView(frame: frame)

        // In a real window, not detached — the same reason spelled out in
        // RuleActivationTests. WebKit grants no visibility assertion to a web
        // view in no window, and a loaded machine then suspends its content
        // process mid-navigation. This test was detached, and had been failing
        // on CI for exactly that: the document never arrived, so waiting on
        // `didFinish` timed out and so did waiting for the button.
        //
        // The `defer` keeps the window alive; nothing else refers to it once
        // the web view is added, and releasing it takes the web view back out.
        // Exactly the pattern RuleActivationTests uses, because that one does
        // load pages on this CI and this one does not. A key window with no
        // root view controller is its own problem, so it is not made key.
        let window = UIWindow(frame: frame)
        window.isHidden = false
        window.addSubview(webView)
        defer {
            webView.removeFromSuperview()
            window.isHidden = true
        }


        // Served over loopback rather than loadHTMLString, which does not
        // navigate at all on the GitHub macOS runner — no commit, no finish,
        // no error, while JavaScript still evaluates against the initial empty
        // document. A real http:// load is an ordinary navigation and commits.
        let server = try FixtureServer(html: """
        <!doctype html><html><body>
        <button class="ctrl forward next">Next</button>
        <iframe id="player"></iframe>
        <script>
          document.querySelector('.ctrl.forward.next').addEventListener('click', () => {
            document.body.dataset.transition = 'ajax';
            document.querySelector('#player').src = 'about:blank#episode-2';
          });
        </script>
        </body></html>
        """)
        try server.start()
        defer { server.stop() }

        let recorder = NavigationRecorder()
        webView.navigationDelegate = recorder
        webView.load(URLRequest(url: server.url.appendingPathComponent("episode-1")))

        // Not `didFinish`: the fixture holds an <iframe>, so that waits on the
        // frame as well and has timed out on CI while the button this test is
        // about had been in the document for seconds.
        // 60s, because this suite has been measured on CI taking nine seconds
        // to run a single pure-logic assertion. The wait returns the moment
        // the document is there, so a generous deadline costs nothing when the
        // machine is not overloaded.
        try await waitForPage(
            "!!document.querySelector('.ctrl.forward.next') && !!document.querySelector('#player')",
            in: webView, timeout: 60, recorder: recorder)
        let handled: Bool = try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(
                EpisodeTransition.siteControlScript(for: .next),
                in: nil, in: .page
            ) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value as? Bool ?? false)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
        let result = try await webView.evaluateJavaScript(
            "document.body.dataset.transition + '|' + document.querySelector('#player').getAttribute('src')") as? String

        XCTAssertTrue(handled)
        XCTAssertEqual(result, "ajax|about:blank#episode-2")
    }
}
