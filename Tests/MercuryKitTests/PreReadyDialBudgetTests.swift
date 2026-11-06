import Foundation
import Testing

@testable import MercuryKit

/// mercury-voice `9742704` (#128): a socket that finishes the WebSocket
/// handshake and sends `gateway.ready` but dies before the
/// `client.capabilities` reply is never published ready, so it must not reset
/// the dial budget or the backoff attempt either. The union supervisor
/// already counts it as a failed dial; this pins that the fix is superseded
/// rather than missing.
@Suite("pre-ready dial budget")
struct PreReadyDialBudgetTests {
    @Test func socketsThatDieBeforeCapabilitiesCountAgainstTheBudget() async throws {
        let server = try await TransportUnionLoopbackGatewayServer.start(
            autoAnswersCapabilities: false
        ) { server in
            server.sendEvent(type: "gateway.ready")
            server.close(code: 1011)
        }
        defer { server.stop() }
        let endpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let connection = HermesConnection(
            endpoint: endpoint,
            authenticator: HermesAuthenticator(endpoint: endpoint, credentials: nil),
            reconnectPolicy: .voice, serverRequestPolicy: .voice,
            supervisorCheckpoint: nil, backoffDelay: 60)
        let updates = await connection.updates()
        let log = PhaseLog()
        let collector = Task {
            for await update in updates {
                guard case .phase(let phase) = update else { continue }
                log.append(phase)
                if case .disconnected = phase { await connection.pokeReconnect() }
                if case .unreachable = phase { return }
                if server.upgradeAttempts > 10 { return }
            }
        }
        await connection.start()
        #expect(
            await transportEventually(timeout: 15) {
                if case .unreachable = await connection.phase { return true }
                return server.upgradeAttempts > 10
            })
        collector.cancel()
        await collector.value
        let terminal = await connection.phase
        guard case .unreachable = terminal else {
            Issue.record("Expected unreachable, got \(terminal)")
            await connection.stop()
            return
        }
        #expect(server.upgradeAttempts == 10)
        let phases = log.all
        #expect(!phases.contains { if case .ready = $0 { return true }; return false })
        let attempts = phases.compactMap { phase -> Int? in
            if case .connecting(let attempt) = phase { return attempt }
            return nil
        }
        #expect(attempts == Array(0..<10))
        await connection.stop()
    }
}
