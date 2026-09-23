import Foundation
import Network

/// A one-page HTTP server on the loopback interface, for tests that need a web
/// view to actually navigate.
///
/// `loadHTMLString` does not navigate on the GitHub macOS runner: the
/// navigation delegate sees no commit, no finish and no error, while
/// JavaScript still evaluates against the initial empty document. Everything
/// asserted about a page therefore timed out there, and no window arrangement
/// or timeout changed it. A real `http://127.0.0.1` load is an ordinary
/// navigation and does commit.
///
/// Deliberately small: one document, no routing, no keep-alive. It exists so a
/// test has a URL, not so the project has a web server.
final class FixtureServer {
    private let listener: NWListener
    private let body: Data
    private let queue = DispatchQueue(label: "cliqx.fixture-server")

    /// The port the kernel gave us, which is what the URL has to use — a fixed
    /// port collides the moment two tests run at once.
    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var url: URL { URL(string: "http://127.0.0.1:\(port)/")! }

    init(html: String) throws {
        body = Data(html.utf8)
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Port 0: let the kernel pick a free one.
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [body] connection in
            connection.start(queue: .global())
            // The request is read and thrown away. Every path serves the same
            // document, because a test needs one page, not a site.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                let header = "HTTP/1.1 200 OK\r\n"
                    + "Content-Type: text/html; charset=utf-8\r\n"
                    + "Content-Length: \(body.count)\r\n"
                    + "Connection: close\r\n\r\n"
                var response = Data(header.utf8)
                response.append(body)
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    /// Starts listening and waits until the port is known, so a caller can
    /// build a URL from it immediately.
    func start(timeout: TimeInterval = 5) throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + timeout) == .success, port != 0 else {
            throw Failure.didNotStart
        }
    }

    func stop() { listener.cancel() }

    enum Failure: Error { case didNotStart }
}
