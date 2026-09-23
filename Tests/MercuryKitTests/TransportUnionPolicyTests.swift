import Foundation
import Testing
@testable import MercuryKit

private final class TransportUnionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    func read() -> TimeInterval { lock.withLock { time } }
    func advance() { lock.withLock { time += 1 } }
}

private actor TransportUnionPolicyDialer: GatewayDialing {
    /// How the injected backend answers `client.capabilities`.
    enum Capabilities {
        case answer
        /// -32601, as a contract-6 backend answers.
        case methodNotFound
        /// The socket dies while the reply is awaited.
        case dropSocket
    }

    var state: GatewayClient.State = .idle
    let replayEpoch: String? = "injected-epoch"
    let closeCause: GatewayClient.CloseCause
    let succeeds: Bool
    let pingError: HermesError?
    let capabilities: Capabilities
    var closes = 0
    var connects = 0
    /// Every RPC method the supervisor sent, in order, across dials.
    var methods: [String] = []
    private var continuation: AsyncStream<GatewayEvent>.Continuation?
    init(cause: GatewayClient.CloseCause = .other, succeeds: Bool = false, pingError: HermesError? = nil,
         capabilities: Capabilities = .answer) {
        self.closeCause = cause
        self.succeeds = succeeds
        self.pingError = pingError
        self.capabilities = capabilities
    }
    func connect(timeout: TimeInterval) async throws {
        connects += 1
        if succeeds { state = .ready; return }
        state = .closed(reason: "text containing (4401) and (4403) is not a typed cause")
        throw HermesError.connectionClosed("text containing (4401) and (4403) is not a typed cause")
    }
    func request(_ method: String, params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
        methods.append(method)
        if method == "client.capabilities" {
            #expect(params == ["server_requests": true])
            #expect(timeout == 5)
            switch capabilities {
            case .answer:
                return ["server_requests": ["approval", "clarify", "sudo", "secret", "tour"]]
            case .methodNotFound:
                throw HermesError.rpcError(code: -32601, message: "unknown method: client.capabilities")
            case .dropSocket:
                state = .closed(reason: "dropped during the handshake")
                continuation?.finish()
                throw HermesError.connectionClosed("dropped during the handshake")
            }
        }
        #expect(method == "gateway.ping")
        if let pingError { throw pingError }
        return .null
    }
    func events() -> AsyncStream<GatewayEvent> {
        AsyncStream {
            if case .closed = state { $0.finish() } else { continuation = $0 }
        }
    }
    func close(reason: String?) {
        closes += 1
        state = .closed(reason: reason)
        continuation?.finish()
    }
}

private actor TransportUnionPhaseLog {
    private(set) var phases: [HermesConnection.Phase] = []
    func append(_ phase: HermesConnection.Phase) { phases.append(phase) }
}

@Suite struct TransportUnionPolicyTests {
    private func connection(policy: ReconnectPolicy, dialer: TransportUnionPolicyDialer,
                            serverRequests: ServerRequestPolicy = .disabled) -> HermesConnection {
        let endpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:9999")!)
        let clock = TransportUnionClock()
        return HermesConnection(endpoint: endpoint,
            authenticator: HermesAuthenticator(endpoint: endpoint, credentials: nil),
            reconnectPolicy: policy, serverRequestPolicy: serverRequests, supervisorCheckpoint: nil,
            now: { clock.read() }, sleeper: { _ in clock.advance() }, makeClient: { _, _ in dialer })
    }

    @Test(arguments: [true, false])
    func onlySelectedBudgetAppliesAndPokeIsProductOwned(restartOnPoke: Bool) async {
        let dialer = TransportUnionPolicyDialer()
        let policy = ReconnectPolicy(stopRule: restartOnPoke ? .failureWindow(2) : .failedHandshakeLimit(3), restartOnPoke: restartOnPoke)
        let connection = connection(policy: policy, dialer: dialer)
        await connection.start()
        #expect(await transportEventually {
            if case .unreachable = await connection.phase { return true }
            return false
        })
        #expect(await dialer.closes == 3)
        await connection.pokeReconnect()
        if restartOnPoke {
            #expect(await transportEventually { await dialer.closes == 6 })
        } else {
            #expect(await dialer.closes == 3)
            await connection.start()
            #expect(await transportEventually { await dialer.closes == 6 })
        }
        await connection.stop()
    }

    @Test(arguments: [GatewayClient.CloseCause.unauthorized, .forbidden])
    func typedInjectedCloseIsTerminal(cause: GatewayClient.CloseCause) async {
        let dialer = TransportUnionPolicyDialer(cause: cause)
        let connection = connection(policy: .voice, dialer: dialer)
        await connection.start()
        #expect(await transportEventually {
            let phase = await connection.phase
            if cause == .unauthorized { return phase == .authExpired }
            if case .refused = phase { return true }
            return false
        })
        #expect(await dialer.closes == 1)
        await connection.pokeReconnect()
        #expect(await dialer.closes == 1)
        await connection.stop()
    }

    @Test(arguments: [true, false])
    func heartbeatRPCResponseProvesLivenessButTimeoutCloses(rpcResponse: Bool) async {
        let dialer = TransportUnionPolicyDialer(succeeds: true,
            pingError: rpcResponse ? .rpcError(code: -32601, message: "old backend") : .timeout("ping"))
        let connection = connection(policy: .voice, dialer: dialer)
        await connection.start()
        #expect(await transportEventually { await connection.phase == .ready(isReconnect: false) })
        #expect(await connection.replayEpoch == "injected-epoch")
        await connection.verifyConnection()
        #expect(await dialer.closes == (rpcResponse ? 0 : 1))
        await connection.stop()
    }

    // MARK: Contract-7 handshake

    /// The switch is off by default, and off means today's behaviour: no
    /// `client.capabilities` on the wire, ready as soon as the dial lands.
    @Test func theDisabledPolicySendsNoCapabilities() async {
        let dialer = TransportUnionPolicyDialer(succeeds: true)
        let connection = connection(policy: .chat, dialer: dialer)
        #expect(connection.serverRequestPolicy == .disabled)
        await connection.start()
        #expect(await transportEventually { await connection.phase == .ready(isReconnect: false) })
        await connection.verifyConnection()
        #expect(await dialer.methods == ["gateway.ping"])
        #expect(await connection.serverRequestMethods == nil)
        await connection.stop()
    }

    @Test(arguments: [ServerRequestPolicy.chat, .voice])
    func anEnabledPolicyAdvertisesBeforeReady(policy: ServerRequestPolicy) async {
        let dialer = TransportUnionPolicyDialer(succeeds: true)
        let connection = connection(policy: .chat, dialer: dialer, serverRequests: policy)
        await connection.start()
        #expect(await transportEventually { await connection.phase == .ready(isReconnect: false) })
        #expect(await dialer.methods == ["client.capabilities"])
        #expect(await connection.serverRequestMethods == ["approval", "clarify", "sudo", "secret", "tour"])
        await connection.stop()
        #expect(await connection.serverRequestMethods == nil)
    }

    /// A contract-6 backend answers -32601: swallowed, and still ready.
    @Test func aContract6RefusalOfCapabilitiesStillReachesReady() async {
        let dialer = TransportUnionPolicyDialer(succeeds: true, capabilities: .methodNotFound)
        let connection = connection(policy: .voice, dialer: dialer, serverRequests: .voice)
        await connection.start()
        #expect(await transportEventually { await connection.phase == .ready(isReconnect: false) })
        #expect(await connection.serverRequestMethods == nil)
        await connection.stop()
    }

    /// A server that accepts every dial and drops it during the handshake
    /// must still exhaust the budget. Each such socket is a failed dial, and
    /// none is ever reported ready (mercury-voice #126 reset the counters
    /// before the handshake, so this spun forever).
    @Test(arguments: [
        ReconnectPolicy(stopRule: .failedHandshakeLimit(3), restartOnPoke: false),
        ReconnectPolicy(stopRule: .failureWindow(2), restartOnPoke: true),
    ])
    func handshakeDropsCountTowardTheGiveUpRule(policy: ReconnectPolicy) async {
        let dialer = TransportUnionPolicyDialer(succeeds: true, capabilities: .dropSocket)
        let connection = connection(policy: policy, dialer: dialer, serverRequests: .chat)
        let updates = await connection.updates()
        let log = TransportUnionPhaseLog()
        let collector = Task {
            for await update in updates {
                if case .phase(let phase) = update { await log.append(phase) }
            }
        }
        defer { collector.cancel() }
        await connection.start()
        // Polled with a deadline rather than awaited: the regression this
        // pins is an endless redial loop, which must fail, not hang.
        let gaveUp = await transportEventually {
            if case .unreachable = await connection.phase { return true }
            return false
        }
        await connection.stop()
        #expect(gaveUp)
        #expect(await log.phases.allSatisfy { if case .ready = $0 { return false }; return true })
        #expect(await dialer.connects == 3)
        #expect(await dialer.closes == 3)
        #expect(await dialer.methods == Array(repeating: "client.capabilities", count: 3))
    }

    /// The handshake-drop path keeps the typed terminal causes terminal.
    @Test(arguments: [GatewayClient.CloseCause.unauthorized, .forbidden])
    func aTypedCloseDuringTheHandshakeIsTerminal(cause: GatewayClient.CloseCause) async {
        let dialer = TransportUnionPolicyDialer(cause: cause, succeeds: true, capabilities: .dropSocket)
        let connection = connection(policy: .voice, dialer: dialer, serverRequests: .voice)
        await connection.start()
        #expect(await transportEventually {
            let phase = await connection.phase
            if cause == .unauthorized { return phase == .authExpired }
            if case .refused = phase { return true }
            return false
        })
        #expect(await dialer.connects == 1)
        await connection.stop()
    }
}
