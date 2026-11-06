import Foundation
import Testing

@testable import MercuryKit

extension HermesConnection {
    /// Test seam: stand in for a prior `prompt.submit` voice_turn rejection.
    func testForceSendsVoiceTurn(_ value: Bool) { sendsVoiceTurn = value }
}

private final class DialCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

/// Per-socket state must not leak across a reconnect: the new socket gets a
/// fresh `voice_turn` arming, no subscriptions, no execution generations, and
/// the authority flag of its own `gateway.ready`.
@Suite("reconnect resets per-socket state")
struct ReconnectResetsSocketStateTests {
    private static let snapshot = #"""
        {"session_id":"local-abc","stored_session_id":"local-abc","messages":[],"message_count":0,
         "running":false,"authority_epoch":7,"replay_epoch":"ep","last_sequence":0,
         "subscription_id":"sub-1","revision":1,"execution_generation":2,"pending":[],"prompts":[],
         "info":{"desktop_protocol":"hermes-gateway-v1","cwd":"/tmp/w"}}
        """#

    private func run(policy: ServerRequestPolicy) async throws {
        let dials = DialCounter()
        let server = try await TransportUnionLoopbackGatewayServer.start(
            onOpen: { server in
                // First socket is a session authority; the second is legacy.
                let first = dials.next() == 1
                server.sendEvent(
                    type: "gateway.ready", payload: first ? #"{"session_authority":true}"# : "{}")
            },
            onRequest: { frame in
                let id = frame["id"]?.intValue ?? 0
                let result = frame["method"]?.stringValue == "session.create" ? Self.snapshot : "{}"
                return #"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#
            })
        defer { server.stop() }
        let endpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let connection = HermesConnection(
            endpoint: endpoint, token: nil, serverRequestPolicy: policy,
            adoptsSessionAuthority: true)
        await connection.start()
        #expect(await transportEventually { await connection.phase == .ready(isReconnect: false) })
        #expect(await connection.speaksSessionAuthority)

        _ = try await connection.createSession(cwd: "/tmp/w")
        await connection.testForceSendsVoiceTurn(false)
        #expect(await connection.authoritySubscriptions["local-abc"] == "sub-1")
        #expect(await connection.executionGenerations["local-abc"] == 2)

        server.dropConnections()
        #expect(
            await transportEventually(timeout: 15) {
                await connection.phase == .ready(isReconnect: true)
            })

        #expect(await connection.sendsVoiceTurn)
        #expect(await connection.authoritySubscriptions.isEmpty)
        #expect(await connection.executionGenerations.isEmpty)
        #expect(await connection.speaksSessionAuthority == false)
        await connection.stop()
    }

    @Test func nonPolicyBranch() async throws { try await run(policy: .disabled) }

    @Test func serverRequestPolicyBranch() async throws { try await run(policy: .voice) }
}
