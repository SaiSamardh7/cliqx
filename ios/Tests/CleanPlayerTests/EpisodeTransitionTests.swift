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
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let waiter = LoadWaiter()
        webView.navigationDelegate = waiter
        webView.loadHTMLString("""
        <button class="ctrl forward next">Next</button>
        <iframe id="player" src="about:blank"></iframe>
        <script>
          document.querySelector('.ctrl.forward.next').addEventListener('click', () => {
            document.body.dataset.transition = 'ajax';
            document.querySelector('#player').src = 'about:blank#episode-2';
          });
        </script>
        """, baseURL: URL(string: "https://video.example/episode-1")!)

        try await waiter.wait()
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
