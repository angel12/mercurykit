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
    var state: GatewayClient.State = .idle
    let replayEpoch: String? = "injected-epoch"
    let closeCause: GatewayClient.CloseCause
    let succeeds: Bool
    let pingError: HermesError?
    var closes = 0
    private var continuation: AsyncStream<GatewayEvent>.Continuation?
    init(cause: GatewayClient.CloseCause = .other, succeeds: Bool = false, pingError: HermesError? = nil) {
        self.closeCause = cause
        self.succeeds = succeeds
        self.pingError = pingError
    }
    func connect(timeout: TimeInterval) async throws {
        if succeeds { state = .ready; return }
        state = .closed(reason: "text containing (4401) and (4403) is not a typed cause")
        throw HermesError.connectionClosed("text containing (4401) and (4403) is not a typed cause")
    }
    func request(_ method: String, params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
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

@Suite struct TransportUnionPolicyTests {
    private func connection(policy: ReconnectPolicy, dialer: TransportUnionPolicyDialer) -> HermesConnection {
        let endpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:9999")!)
        let clock = TransportUnionClock()
        return HermesConnection(endpoint: endpoint,
            authenticator: HermesAuthenticator(endpoint: endpoint, credentials: nil),
            reconnectPolicy: policy, supervisorCheckpoint: nil,
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
}
