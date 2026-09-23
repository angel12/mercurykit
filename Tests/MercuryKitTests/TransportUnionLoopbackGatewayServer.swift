import CryptoKit
import Foundation
import Network

@testable import MercuryKit

/// A real WebSocket gateway on 127.0.0.1 with an OS-assigned port, so
/// `GatewayClient` is exercised over an actual `URLSessionWebSocketTask`
/// against actual bytes.
///
/// It exists because the interesting refusals are *transport* facts no
/// injected socket can prove: a gateway that rejects the HTTP upgrade with
/// 401/403 never produces a WebSocket close code at all, and an application
/// close code (4401/4403) only reaches the client if URLSession surfaces it.
/// Both are Apple behaviors, so they get tested against Apple's transport.
///
/// The RFC 6455 handshake and framing are done by hand (NWListener's
/// `NWProtocolWebSocket` options fail to start on this macOS), which also
/// makes the server scriptable enough to refuse an upgrade outright.
final class TransportUnionLoopbackGatewayServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    /// Non-nil: refuse every upgrade with this HTTP status instead of 101.
    private let refuseUpgradeWith: Int?
    /// Kill the connection without answering the upgrade at all — a dial that
    /// dies mid-handshake, which is what a genuinely transient failure looks
    /// like (no status code ever reaches the client).
    private let dropsUpgrade: Bool
    private let onOpen: @Sendable (TransportUnionLoopbackGatewayServer) -> Void
    /// False holds back every `client.capabilities` reply until a test fires
    /// it with `answerCapabilities(asError:)`, to pin down its ordering
    /// against `.phase(.ready)`. True (the default) answers at once, so a
    /// connection test against a policy that advertises never waits out the
    /// supervisor's 5 s capabilities timeout.
    private let autoAnswersCapabilities: Bool
    private var peers: [ObjectIdentifier: Peer] = [:]
    private var _upgradeAttempts = 0
    private var _receivedFrames: [JSONValue] = []
    /// Held `client.capabilities` requests, oldest first: the request id and
    /// the socket it arrived on, so the reply goes back to that socket only.
    private var _pendingCapabilities: [(id: Int, peer: ObjectIdentifier)] = []
    private(set) var port: UInt16 = 0

    /// One accepted TCP connection: its socket, its unparsed bytes, and
    /// whether the upgrade head has been consumed.
    private final class Peer {
        let connection: NWConnection
        var handshaken = false
        var pending: [UInt8] = []

        init(_ connection: NWConnection) { self.connection = connection }
    }

    /// How many HTTP upgrade heads the server has consumed — one per dial, so
    /// a supervisor that keeps redialing a terminal refusal shows up as a
    /// rising count.
    var upgradeAttempts: Int { lock.withLock { _upgradeAttempts } }

    static func start(
        refuseUpgradeWith: Int? = nil,
        dropsUpgrade: Bool = false,
        autoAnswersCapabilities: Bool = true,
        onOpen: @escaping @Sendable (TransportUnionLoopbackGatewayServer) -> Void = { server in
            server.sendEvent(type: "gateway.ready")
        }
    ) async throws -> TransportUnionLoopbackGatewayServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        let server = TransportUnionLoopbackGatewayServer(
            listener: listener, refuseUpgradeWith: refuseUpgradeWith,
            dropsUpgrade: dropsUpgrade, autoAnswersCapabilities: autoAnswersCapabilities,
            onOpen: onOpen)
        try await server.waitUntilReady()
        return server
    }

    private init(
        listener: NWListener,
        refuseUpgradeWith: Int?,
        dropsUpgrade: Bool,
        autoAnswersCapabilities: Bool,
        onOpen: @escaping @Sendable (TransportUnionLoopbackGatewayServer) -> Void
    ) {
        self.listener = listener
        self.refuseUpgradeWith = refuseUpgradeWith
        self.dropsUpgrade = dropsUpgrade
        self.autoAnswersCapabilities = autoAnswersCapabilities
        self.onOpen = onOpen
        // Installed before start(): a started NWListener without a
        // newConnectionHandler fails with EINVAL.
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.withLock {
                self.peers[ObjectIdentifier(connection)] = Peer(connection)
            }
            connection.start(queue: DispatchQueue(label: "test.loopback-gateway-connection"))
            self.receiveNext(connection)
        }
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let box = TransportUnionPortResumeOnce(continuation)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let self, let port = self.listener.port?.rawValue, port != 0 {
                        self.lock.withLock { self.port = port }
                        box.resume(returning: ())
                    } else {
                        box.resume(throwing: URLError(.cannotConnectToHost))
                    }
                case .failed(let error):
                    box.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "test.loopback-gateway"))
        }
    }

    private func receiveNext(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.withLock {
                    self.peers[ObjectIdentifier(connection)]?.pending.append(contentsOf: data)
                }
                self.drain(connection)
            }
            if error != nil || isComplete {
                self.drop(connection)
                return
            }
            self.receiveNext(connection)
        }
    }

    private func drop(_ connection: NWConnection) {
        lock.withLock { peers[ObjectIdentifier(connection)] = nil }
        connection.cancel()
    }

    private func drain(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        let needsHandshake = lock.withLock { peers[key].map { !$0.handshaken } ?? false }
        guard needsHandshake else {
            handleClientFrames(connection)
            return
        }
        guard let response = lock.withLock({ takeHandshakeLocked(key) }) else { return }
        if dropsUpgrade {
            drop(connection)
            return
        }
        if refuseUpgradeWith != nil {
            // The refusal must be fully flushed before the socket goes away:
            // a connection cancelled with bytes still queued reaches
            // URLSession as "the network connection was lost" and the status
            // code is never parsed at all.
            connection.send(
                content: response, isComplete: true,
                completion: .contentProcessed { [weak self] _ in self?.drop(connection) })
            return
        }
        connection.send(content: response, isComplete: true, completion: .idempotent)
        onOpen(self)
        handleClientFrames(connection)
    }

    /// Consume the HTTP upgrade head and return the response bytes — 101 for
    /// a normal dial, or the scripted refusal status. Nil while the head has
    /// not fully arrived. Caller holds `lock`.
    private func takeHandshakeLocked(_ key: ObjectIdentifier) -> Data? {
        guard let peer = peers[key] else { return nil }
        let marker: [UInt8] = Array("\r\n\r\n".utf8)
        guard let headEnd = peer.pending.firstRange(of: marker) else { return nil }
        let head = String(decoding: peer.pending[..<headEnd.lowerBound], as: UTF8.self)
        peer.pending.removeSubrange(..<headEnd.upperBound)
        peer.handshaken = true
        _upgradeAttempts += 1

        if let status = refuseUpgradeWith {
            let body = Data(#"{"detail":"refused"}"#.utf8)
            let responseHead =
                "HTTP/1.1 \(status) Refused\r\nContent-Type: application/json\r\n"
                + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            return Data(responseHead.utf8) + body
        }

        let requestKey =
            head.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("sec-websocket-key:") }?
            .split(separator: ":", maxSplits: 1).last?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let accept = Data(
            Insecure.SHA1.hash(
                data: Data((requestKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        ).base64EncodedString()
        return Data(
            ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                + "Connection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n").utf8)
    }

    // MARK: Client → server

    /// Every text frame the clients have sent, decoded, in arrival order.
    var receivedFrames: [JSONValue] { lock.withLock { _receivedFrames } }

    /// The JSON-RPC `method` of every frame the clients have sent.
    var receivedMethods: [String] { receivedFrames.compactMap { $0["method"]?.stringValue } }

    /// Parse the complete client frames buffered for `connection`. Only
    /// `client.capabilities` is answered; nothing else here needs a generic
    /// RPC dispatcher. Recording a frame and holding its capabilities id
    /// share one lock acquisition, so a fast `answerCapabilities()` can
    /// never find the frame recorded but its id not yet held.
    private func handleClientFrames(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        while true {
            let taken: (opcode: UInt8, payload: Data)? = lock.withLock {
                guard let peer = peers[key], let frame = Self.takeFrame(peer.pending) else {
                    return nil
                }
                peer.pending.removeSubrange(..<frame.consumed)
                return (frame.opcode, frame.payload)
            }
            guard let taken else { return }
            // Text only; a close or control frame carries no request.
            guard taken.opcode == 0x1,
                let frame = try? JSONDecoder().decode(JSONValue.self, from: taken.payload)
            else { continue }
            let capabilitiesID =
                frame["method"]?.stringValue == "client.capabilities" ? frame["id"]?.intValue : nil
            lock.withLock {
                _receivedFrames.append(frame)
                if let capabilitiesID, !autoAnswersCapabilities {
                    _pendingCapabilities.append((capabilitiesID, key))
                }
            }
            if let capabilitiesID, autoAnswersCapabilities {
                reply(to: connection, id: capabilitiesID, asError: false)
            }
        }
    }

    /// Answer the oldest held `client.capabilities` request, on the socket
    /// that sent it. `asError` replies -32601, as a contract-6 backend does.
    /// False when nothing is held.
    @discardableResult
    func answerCapabilities(asError: Bool = false) -> Bool {
        let held: (id: Int, connection: NWConnection)? = lock.withLock {
            while !_pendingCapabilities.isEmpty {
                let next = _pendingCapabilities.removeFirst()
                if let peer = peers[next.peer] { return (next.id, peer.connection) }
            }
            return nil
        }
        guard let held else { return false }
        reply(to: held.connection, id: held.id, asError: asError)
        return true
    }

    private func reply(to connection: NWConnection, id: Int, asError: Bool) {
        let text =
            asError
            ? #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32601,"message":"unknown method: client.capabilities"}}"#
            : #"{"jsonrpc":"2.0","id":\#(id),"result":{"server_requests":["approval","clarify","sudo","secret"]}}"#
        sendFrame(opcode: 0x1, payload: Data(text.utf8), to: connection)
    }

    /// One client frame from the front of `bytes`: opcode, unmasked payload
    /// and the bytes it spans, or nil while it is not fully buffered. Client
    /// frames are masked (RFC 6455 §5.3); unfragmented frames only, which is
    /// all a small JSON-RPC request produces.
    private static func takeFrame(_ bytes: [UInt8]) -> (opcode: UInt8, payload: Data, consumed: Int)? {
        guard bytes.count >= 2 else { return nil }
        let opcode = bytes[0] & 0x0F
        let masked = bytes[1] & 0x80 != 0
        var length = Int(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= offset + 2 else { return nil }
            length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
        } else if length == 127 {
            guard bytes.count >= offset + 8 else { return nil }
            length = bytes[offset..<offset + 8].reduce(0) { $0 << 8 | Int($1) }
            offset += 8
        }
        var mask: [UInt8] = []
        if masked {
            guard bytes.count >= offset + 4 else { return nil }
            mask = Array(bytes[offset..<offset + 4])
            offset += 4
        }
        guard bytes.count >= offset + length else { return nil }
        var payload = Array(bytes[offset..<offset + length])
        if masked {
            for index in payload.indices { payload[index] ^= mask[index % 4] }
        }
        return (opcode, Data(payload), offset + length)
    }

    // MARK: Server → client

    /// To every handshaken peer, or to `target` alone.
    private func sendFrame(opcode: UInt8, payload: Data, to target: NWConnection? = nil) {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8(payload.count >> 8))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((payload.count >> shift) & 0xFF))
            }
        }
        frame.append(payload)
        // Never hold the lock across a send.
        let live = lock.withLock {
            peers.values.filter { $0.handshaken && (target == nil || $0.connection === target) }
                .map(\.connection)
        }
        for connection in live {
            connection.send(content: frame, isComplete: true, completion: .idempotent)
        }
    }

    func send(_ text: String) {
        sendFrame(opcode: 0x1, payload: Data(text.utf8))
    }

    /// Push a `{"method": "event"}` frame the way the gateway does.
    func sendEvent(type: String, payload: String = "{}") {
        send(
            #"{"jsonrpc":"2.0","method":"event","params":{"type":"\#(type)","payload":\#(payload)}}"#
        )
    }

    /// Server-initiated close carrying an application close code (4401/4403).
    func close(code: UInt16) {
        sendFrame(opcode: 0x8, payload: Data([UInt8(code >> 8), UInt8(code & 0xFF)]))
    }

    /// Kill every open peer without stopping the listener: a transport loss
    /// mid-flight, with a request the client awaits still outstanding.
    func dropConnections() {
        let open = lock.withLock {
            let open = peers.values.map(\.connection)
            peers = [:]
            return open
        }
        for connection in open { connection.cancel() }
    }

    func stop() {
        let open = lock.withLock {
            let open = peers.values.map(\.connection)
            peers = [:]
            return open
        }
        for connection in open { connection.cancel() }
        listener.cancel()
    }

    deinit { listener.cancel() }
}

final class TransportUnionPortResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: error)
    }
}

/// Poll `condition` until it holds or the deadline passes. Loopback transport
/// outcomes land on URLSession's own queues, so a test observes them by
/// waiting for the state rather than by sleeping a guessed interval.
func transportEventually(
    timeout: Double = 5, _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}
