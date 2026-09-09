import Foundation
import Network

/// One-shot HTTP listener on 127.0.0.1 that catches the authorize redirect.
/// Start it, put `http://127.0.0.1:<port><path>` in the authorize URL, and
/// await `waitForRedirect()`; it resolves with code and state, or throws
/// on IDP denial, an incoherent callback for this flow, or `cancel()`.
/// When initialized with `expectedState`, requests without that state — including denials — are
/// answered with an HTTP rejection and leave the wait running: only the flow
/// that knows the state can end it.
public actor LoopbackRedirectListener {
    public struct Redirect: Sendable, Equatable {
        public var code: String
        public var state: String
    }

    public enum ListenerError: Error, LocalizedError, Equatable {
        case failedToStart
        case badRequest(String)
        case cancelled
        case denied(String)
        /// A callback that proved the expected `state` but carried nothing
        /// this flow can act on — no usable `code` and no `error`. Callbacks
        /// that fail the state check never reach here: they are rejected
        /// over HTTP and the wait keeps running. (Case name kept for API
        /// compatibility; it no longer implies a mismatched state.)
        case stateMismatch
        case listenerFailed(String)
        case timedOut
        /// The system browser sheet refused to present, so no redirect can
        /// ever arrive.
        case presentationFailed

        public var errorDescription: String? {
            switch self {
            case .failedToStart: return "Could not open a local sign-in listener."
            case .badRequest(let why): return "Sign-in redirect was malformed: \(why)"
            case .cancelled: return "Sign-in was cancelled."
            case .denied(let detail): return "Sign-in was denied: \(detail)"
            case .stateMismatch: return "Sign-in response failed validation. Try again."
            case .timedOut: return "Sign-in timed out. Try again."
            case .presentationFailed: return "Couldn't open the sign-in browser. Try again."
            case .listenerFailed(let detail): return "Couldn't listen for the sign-in redirect: \(detail)"
            }
        }
    }

    public let path: String
    private let expectedState: String?
    /// How long an accepted connection has to deliver a complete request line
    /// before it is dropped. A loopback redirect arrives in milliseconds; the
    /// bound exists so a connection that opens and then stalls cannot hold a
    /// receive (and its buffer) for the whole sign-in.
    private let requestDeadline: Duration
    /// Cap on what one connection may accumulate while its request line is
    /// still unterminated. A callback request line is a few hundred bytes.
    private static let maxRequestLineBytes = 16384
    /// Connections whose request line is still being read. Membership is what
    /// says a completed receive may be parsed: cancelling a connection
    /// completes its pending receive with `isComplete == true, error == nil`,
    /// which is exactly what a peer's half-close looks like, so the receive
    /// alone cannot tell "the browser finished writing" from "the deadline
    /// gave up". `expire` drops the connection from this set before
    /// cancelling it, and every terminal read path drops it too — so an
    /// expiry that lands after the request line was handled is a no-op and
    /// the set cannot grow.
    private var readingConnections: [ObjectIdentifier: NWConnection] = [:]
    /// Test seam over a single receive completion, reduced to the three
    /// things the read loop acts on: the bytes, the peer's clean
    /// end-of-stream, and whether the receive itself failed. A transport
    /// failure landing on a half-delivered request line cannot be provoked
    /// from a loopback client with any determinism — a reset may surface as a
    /// clean end-of-stream, and may take the already-buffered bytes with it —
    /// so tests inject one here instead. `nil` in production: the read loop
    /// uses what Network reported, unaltered.
    typealias ReceiveRewrite =
        @Sendable (Data?, Bool, Bool) -> (
            data: Data?, isComplete: Bool, failed: Bool
        )
    private let receiveRewrite: ReceiveRewrite?
    private var listener: NWListener?
    private var startWaiter: CheckedContinuation<UInt16, Error>?
    private var codeWaiter: CheckedContinuation<Redirect, Error>?
    /// Buffered outcome for a redirect that lands before waitForRedirect().
    private var outcome: Result<Redirect, Error>?
    private var finished = false

    /// Pass the PKCE challenge's state to authenticate callbacks before they
    /// can finish the flow. The no-argument legacy API leaves state validation
    /// to the caller; new integrations should always supply expectedState.
    public init(expectedState: String? = nil, path: String = "/callback") {
        self.expectedState = expectedState
        self.path = path
        self.requestDeadline = .seconds(10)
        self.receiveRewrite = nil
    }

    /// Test seams for the accept deadline and the receive results; the public
    /// initializer keeps the production value and no rewrite.
    init(
        expectedState: String, path: String = "/callback", requestDeadline: Duration,
        receiveRewrite: ReceiveRewrite? = nil
    ) {
        self.expectedState = expectedState
        self.path = path
        self.requestDeadline = requestDeadline
        self.receiveRewrite = receiveRewrite
    }

    /// Bind to an ephemeral loopback port and return the full callback URL.
    public func start() async throws -> String {
        guard !finished, listener == nil else { throw ListenerError.failedToStart }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) }
        catch { throw ListenerError.failedToStart }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            Task { await self.accept(connection) }
        }
        let startupTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await self?.finish(.failure(ListenerError.failedToStart))
        }
        defer { startupTimeout.cancel() }
        let port = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<UInt16, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: ListenerError.cancelled)
                    finish(.failure(ListenerError.cancelled))
                    return
                }
                startWaiter = continuation
                listener.stateUpdateHandler = { [weak self] state in
                    Task { await self?.listenerStateChanged(state) }
                }
                listener.start(queue: .global(qos: .userInitiated))
            }
        } onCancel: {
            Task { await self.cancel() }
        }
        return "http://127.0.0.1:\(port)\(path)"
    }

    /// Await the redirect. Single-shot: resolves with the code or throws.
    ///
    /// Bounded and cancellation-aware on purpose: the only thing that resumes
    /// this is a redirect landing on the listener, so a browser sheet that
    /// never presents (no anchor, another sheet already up) would otherwise
    /// park the continuation forever and leak the sign-in task with the UI
    /// stuck on the sheet.
    public func waitForRedirect(timeout: TimeInterval = 300) async throws -> Redirect {
        if let outcome {
            return try outcome.get()
        }
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.timeOut()
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Redirect, Error>) in
                // The cancellation handler and the timeout both hop onto the
                // actor to finish(), so either can land before the
                // continuation is installed — resume from the buffered
                // outcome instead of waiting for a resume that already fired.
                if let outcome {
                    continuation.resume(with: outcome)
                } else {
                    codeWaiter = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func timeOut() {
        finish(.failure(ListenerError.timedOut))
    }

    /// Abort (user closed the browser sheet, or the flow owner is bailing).
    public func cancel() {
        finish(.failure(ListenerError.cancelled))
    }

    // MARK: Internals

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port?.rawValue, let waiter = startWaiter {
                startWaiter = nil
                waiter.resume(returning: port)
            }
        case .failed(let error):
            if let waiter = startWaiter {
                startWaiter = nil
                waiter.resume(throwing: ListenerError.listenerFailed("\(error)"))
            }
            finish(.failure(ListenerError.listenerFailed("\(error)")))
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !finished else { return connection.cancel() }
        connection.start(queue: .global(qos: .userInitiated))
        readingConnections[ObjectIdentifier(connection)] = connection
        // A peer that opens the connection and then stalls — mid-request-line
        // or before writing a byte — would otherwise hold an idle receive for
        // as long as the flow lives, so give it a deadline of its own. Expiry
        // goes through the actor so it is ordered against `received`, and the
        // task holds only the connection and the duration: no reference to
        // the listener, and nothing to cancel once it has run.
        let deadline = Task { [weak self, requestDeadline] in
            try? await Task.sleep(for: requestDeadline)
            guard !Task.isCancelled else { return }
            guard let self else { return connection.cancel() }
            await self.expire(connection)
        }
        receiveRequestLine(on: connection, accumulated: Data(), deadline: deadline)
    }

    /// The deadline fired: drop the connection with its half-written request
    /// line unread. Never resolves the flow — the fragment is not ours to act
    /// on, so the wait stays open for the callback that completes.
    private func expire(_ connection: NWConnection) {
        // Absent means the read already ended on its own; the cancel below
        // would then be racing a response that is already on its way out.
        guard readingConnections.removeValue(forKey: ObjectIdentifier(connection)) != nil else { return }
        connection.cancel()
    }

    /// Terminal for the read side: stop the deadline and forget the
    /// connection, so a deadline that fires afterwards finds nothing to expire.
    private func endReading(_ connection: NWConnection, deadline: Task<Void, Never>) {
        deadline.cancel()
        readingConnections.removeValue(forKey: ObjectIdentifier(connection))
    }

    /// One TCP receive is not one HTTP request: the redirect's request line
    /// may arrive split across segments, so accumulate until it is terminated,
    /// the peer stops writing, the read fails, or the byte bound is reached.
    private func receiveRequestLine(
        on connection: NWConnection, accumulated: Data, deadline: Task<Void, Never>
    ) {
        let rewrite = receiveRewrite
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Self.maxRequestLineBytes - accumulated.count
        ) { [weak self] data, _, isComplete, error in
            let result =
                rewrite?(data, isComplete, error != nil)
                ?? (data: data, isComplete: isComplete, failed: error != nil)
            guard let self else {
                deadline.cancel()
                return connection.cancel()
            }
            Task {
                await self.received(
                    result.data, endOfStream: result.isComplete, failed: result.failed,
                    on: connection, accumulated: accumulated, deadline: deadline)
            }
        }
    }

    private func received(
        _ data: Data?, endOfStream: Bool, failed: Bool, on connection: NWConnection,
        accumulated: Data, deadline: Task<Void, Never>
    ) {
        guard readingConnections[ObjectIdentifier(connection)] != nil else {
            // `expire` already gave up on this connection, and its cancel is
            // what completed this receive. Whatever is buffered is a fragment,
            // not an EOF-terminated request line.
            deadline.cancel()
            connection.cancel()
            return
        }
        var buffer = accumulated
        if let data { buffer += data }

        if let terminator = buffer.range(of: Data("\r\n".utf8)) {
            // A terminated request line is a whole request, whatever became of
            // the read that carried the last of it: the CRLF is the proof.
            endReading(connection, deadline: deadline)
            handle(requestLine: buffer[..<terminator.lowerBound], on: connection)
        } else if failed {
            // A read that failed is not a peer that stopped writing. The
            // buffered fragment is not a request line — it merely parses like
            // one, and doing so would resolve the one-shot flow from a
            // half-delivered callback (a truncated `code`, or a `code=` not yet
            // written, which fails the wait outright). Drop it and keep
            // waiting: the callback that arrives whole is the one that counts.
            endReading(connection, deadline: deadline)
            connection.cancel()
        } else if endOfStream {
            endReading(connection, deadline: deadline)
            // No CRLF, but the peer is done writing: what it sent is all the
            // request line there will ever be.
            if buffer.isEmpty {
                connection.cancel()
            } else {
                handle(requestLine: buffer, on: connection)
            }
        } else if buffer.count >= Self.maxRequestLineBytes {
            // Past the bound with no end in sight. Drop it unanswered rather
            // than act on a truncated line: a truncation splits cleanly enough
            // to parse, which is how a half-delivered callback could hand the
            // flow a truncated `code` and consume the one-shot sign-in.
            endReading(connection, deadline: deadline)
            connection.cancel()
        } else {
            receiveRequestLine(on: connection, accumulated: buffer, deadline: deadline)
        }
    }

    private func handle(requestLine bytes: Data, on connection: NWConnection) {
        guard let requestLine = String(data: bytes, encoding: .utf8) else {
            connection.cancel()
            return
        }
        // "GET /oauth/callback?code=…&state=… HTTP/1.1"
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
            let components = URLComponents(string: "http://127.0.0.1\(parts[1])"),
            components.path == path
        else {
            respond(on: connection, status: "404 Not Found", body: "Not found.")
            return
        }
        if expectedState == nil {
            var query: [String: String] = [:]
            for item in components.queryItems ?? [] {
                let duplicate = query.updateValue(item.value ?? "", forKey: item.name) != nil
                if duplicate, ["code", "state", "error"].contains(item.name) {
                    respond(on: connection, status: "400 Bad Request", body: "Ambiguous sign-in response.")
                    return
                }
            }
            if let error = query["error"], !error.isEmpty {
                respond(on: connection, status: "400 Bad Request", body: "Sign-in failed. Return to Mercury.")
                finish(.failure(ListenerError.badRequest(error)))
                return
            }
            guard let code = query["code"], !code.isEmpty else {
                respond(on: connection, status: "400 Bad Request", body: "Waiting for sign-in.")
                return
            }
            respond(on: connection, status: "200 OK", body: "Signed in. Return to Mercury.")
            finish(.success(Redirect(code: code, state: query["state"] ?? "")))
            return
        }
        // Exactly-one lookup: a repeated parameter is ambiguous input, and
        // resolving it in the sender's favour (first match wins) is how a
        // smuggled second `state=` slips past validation.
        let query = { (name: String) -> String? in
            let values = (components.queryItems ?? []).filter { $0.name == name }
            guard values.count == 1 else { return nil }
            return values[0].value
        }

        // State first, for denials as much as for successes: a callback that
        // can't prove it belongs to this flow gets an HTTP rejection and the
        // listener keeps waiting, so a stray browser request or a hostile
        // local process can neither hijack the sign-in nor kill it (an
        // unauthenticated `?error=access_denied` used to be enough).
        guard let state = query("state"), state == expectedState else {
            respond(
                on: connection, status: "400 Bad Request",
                body: "Sign-in response failed validation. Restart sign-in from the app.")
            return
        }

        if let error = query("error") {
            let detail = query("error_description") ?? error
            respond(
                on: connection, status: "200 OK",
                body: "Sign-in failed: \(detail). You can close this tab.")
            finish(.failure(ListenerError.denied(detail)))
            return
        }
        // Right state, no usable code and no error: our own flow answering
        // incoherently, so fail the wait instead of holding a flow that
        // nothing can complete.
        guard let code = query("code"), !code.isEmpty
        else {
            respond(
                on: connection, status: "400 Bad Request",
                body: "Sign-in response failed validation. Restart sign-in from the app.")
            finish(.failure(ListenerError.stateMismatch))
            return
        }
        respond(
            on: connection, status: "200 OK",
            body: "Signed in — return to Mercury. You can close this tab.")
        finish(.success(Redirect(code: code, state: state)))
    }

    /// `body` is plain text — it can carry the server's `error_description`,
    /// which a real browser would otherwise render as markup — so it is
    /// escaped into the page rather than interpolated.
    private func respond(on connection: NWConnection, status: String, body: String) {
        let html =
            "<!doctype html><meta charset=\"utf-8\"><title>Mercury</title>"
            + "<body style=\"font-family:-apple-system,sans-serif;padding:2em\">"
            + "<p>\(Self.htmlEscaped(body))</p></body>"
        let payload = Data(html.utf8)
        let head =
            "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        connection.send(
            content: Data(head.utf8) + payload,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in Self.drainThenCancel(connection) })
    }

    /// Escapes per Unicode scalar, which is what an HTML tokenizer reads.
    /// Iterating `Character` would leave a bypass: a grapheme cluster can
    /// swallow a delimiter, because a Prepend code point (U+0600, U+0D4E,
    /// U+110BD…) does not break before the next code point (UAX #29 GB9b),
    /// so `U+0600 <` is one Character that matches none of these cases and
    /// used to be appended verbatim — enough to open a tag, with the `>` of
    /// the surrounding `</p>` closing it.
    private static func htmlEscaped(_ text: String) -> String {
        var escaped = ""
        escaped.unicodeScalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    private func finish(_ result: Result<Redirect, Error>) {
        guard !finished else { return }
        finished = true
        outcome = result
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        if let waiter = startWaiter {
            startWaiter = nil
            switch result {
            case .failure(let error): waiter.resume(throwing: error)
            case .success: waiter.resume(throwing: ListenerError.failedToStart)
            }
        }
        for connection in readingConnections.values { connection.cancel() }
        readingConnections.removeAll()
        if let waiter = codeWaiter {
            codeWaiter = nil
            waiter.resume(with: result)
        }
    }

    /// Read until the peer closes (or errors), then cancel. A failsafe
    /// timer cancels regardless — cancel() is idempotent, so racing the
    /// EOF path is harmless.
    private nonisolated static func drainThenCancel(_ connection: NWConnection) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { connection.cancel() }
        receiveToEOF(connection) { connection.cancel() }
    }

    private nonisolated static func receiveToEOF(
        _ connection: NWConnection, then done: @escaping @Sendable () -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            _, _, isComplete, error in
            if isComplete || error != nil {
                done()
            } else {
                receiveToEOF(connection, then: done)
            }
        }
    }
}
