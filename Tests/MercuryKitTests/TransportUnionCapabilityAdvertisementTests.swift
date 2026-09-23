import Foundation
import Testing

@testable import MercuryKit

/// Contract ≥ 7 backends only deliver prompts to a socket that advertised
/// `client.capabilities {"server_requests": true}` on it (hermes-agent
/// f9d178f78e). With an enabled `ServerRequestPolicy` the supervisor sends
/// that advertisement, and awaits its reply, before publishing
/// `.phase(.ready)`: apps answer ready with `session.resume`, so a late
/// advertisement would race the session's first prompt. Real supervisor over
/// real loopback sockets.
@Suite("Capability advertisement")
struct TransportUnionCapabilityAdvertisementTests {
    private func connection(
        _ server: TransportUnionLoopbackGatewayServer, serverRequests: ServerRequestPolicy,
        backoffDelay: TimeInterval? = nil
    ) -> HermesConnection {
        let endpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        return HermesConnection(
            endpoint: endpoint,
            authenticator: HermesAuthenticator(endpoint: endpoint, credentials: nil),
            reconnectPolicy: .voice, serverRequestPolicy: serverRequests,
            supervisorCheckpoint: nil, backoffDelay: backoffDelay)
    }

    @Test(arguments: [ServerRequestPolicy.voice, .chat])
    func capabilitiesIsTheFirstFrameAndReadyWaitsForItsReply(policy: ServerRequestPolicy) async throws {
        let server = try await TransportUnionLoopbackGatewayServer.start(autoAnswersCapabilities: false)
        defer { server.stop() }
        let connection = connection(server, serverRequests: policy)
        let log = CapabilityPhaseLog()
        let updates = await connection.updates()
        let collector = Task {
            for await update in updates {
                if case .phase(let phase) = update { await log.append(phase) }
            }
        }
        defer { collector.cancel() }

        await connection.start()

        #expect(await transportEventually { server.receivedMethods == ["client.capabilities"] })
        // The frame carries the capability, not just the method.
        let frame = try #require(server.receivedFrames.first)
        #expect(frame["params"] == ["server_requests": true])
        // No reply yet: ready must not have been published.
        #expect(await connection.phase != .ready(isReconnect: false))
        #expect(await !log.phases.contains(.ready(isReconnect: false)))

        #expect(server.answerCapabilities())

        // A short deadline, not the 5 s capabilities timeout: ready must come
        // from processing this reply, not from the timeout firing under it.
        #expect(await transportEventually(timeout: 1) { await connection.phase == .ready(isReconnect: false) })
        #expect(server.receivedMethods == ["client.capabilities"])
        #expect(await connection.serverRequestMethods == ["approval", "clarify", "sudo", "secret"])
        await connection.stop()
    }

    @Test func aContract6BackendsErrorReplyStillReachesReady() async throws {
        let server = try await TransportUnionLoopbackGatewayServer.start(autoAnswersCapabilities: false)
        defer { server.stop() }
        let connection = connection(server, serverRequests: .voice)
        await connection.start()

        #expect(await transportEventually { server.receivedMethods == ["client.capabilities"] })
        #expect(server.answerCapabilities(asError: true))

        #expect(await transportEventually(timeout: 1) { await connection.phase == .ready(isReconnect: false) })
        #expect(await connection.serverRequestMethods == nil)
        await connection.stop()
    }

    @Test func aSocketDroppedDuringTheCapabilitiesAwaitNeverPublishesReady() async throws {
        let server = try await TransportUnionLoopbackGatewayServer.start(autoAnswersCapabilities: false)
        defer { server.stop() }
        // A large fixed backoff: nothing races a redial while this runs.
        let connection = connection(server, serverRequests: .voice, backoffDelay: 60)
        let log = CapabilityPhaseLog()
        let updates = await connection.updates()
        let collector = Task {
            for await update in updates {
                if case .phase(let phase) = update { await log.append(phase) }
            }
        }
        defer { collector.cancel() }

        await connection.start()
        #expect(await transportEventually { server.receivedMethods == ["client.capabilities"] })

        // Kill the transport with the reply still withheld.
        server.dropConnections()

        #expect(
            await transportEventually {
                await log.phases.contains { if case .disconnected = $0 { return true }; return false }
            })
        #expect(await !log.phases.contains(.ready(isReconnect: false)))
        #expect(await connection.phase != .ready(isReconnect: false))
        await connection.stop()
    }

    /// The switch-off path over the real transport: no advertisement, ready
    /// straight from `gateway.ready`, even with the server holding replies.
    @Test func theDisabledPolicySendsNothingAndIsReadyAtOnce() async throws {
        let server = try await TransportUnionLoopbackGatewayServer.start(autoAnswersCapabilities: false)
        defer { server.stop() }
        let connection = connection(server, serverRequests: .disabled)
        await connection.start()
        #expect(await transportEventually(timeout: 1) { await connection.phase == .ready(isReconnect: false) })
        // The helper never answers the ping; only its arrival matters here.
        let probe = Task { await connection.verifyConnection() }
        #expect(await transportEventually { server.receivedMethods == ["gateway.ping"] })
        await connection.stop()
        probe.cancel()
    }

    /// The default auto-answer keeps loopback connection tests fast: an
    /// advertising connection is ready well inside the 5 s timeout.
    @Test func theServerAutoAnswersByDefault() async throws {
        let server = try await TransportUnionLoopbackGatewayServer.start()
        defer { server.stop() }
        let connection = connection(server, serverRequests: .chat)
        await connection.start()
        #expect(await transportEventually(timeout: 1) { await connection.phase == .ready(isReconnect: false) })
        await connection.stop()
    }

    /// Each client numbers its requests from 1, so a capabilities reply
    /// broadcast to every socket would resolve another socket's pending id 1
    /// too. The helper must answer only the socket that asked.
    @Test func aHeldReplyReachesOnlyTheSocketThatAsked() async throws {
        let server = try await TransportUnionLoopbackGatewayServer.start(autoAnswersCapabilities: false)
        defer { server.stop() }
        let endpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let authenticator = HermesAuthenticator(endpoint: endpoint, credentials: nil)
        let first = GatewayClient(endpoint: endpoint, authenticator: authenticator)
        let second = GatewayClient(endpoint: endpoint, authenticator: authenticator)
        try await first.connect(timeout: 5)
        try await second.connect(timeout: 5)

        let advertise: @Sendable (GatewayClient) async -> RPCOutcome = { client in
            await rpcOutcome {
                try await client.request(
                    "client.capabilities", params: ["server_requests": true], timeout: 5)
            }
        }
        let firstCall = Task { await advertise(first) }
        #expect(await transportEventually { server.receivedMethods.count == 1 })
        let secondCall = Task { await advertise(second) }
        #expect(await transportEventually { server.receivedMethods.count == 2 })

        #expect(server.answerCapabilities())
        guard case .value = await firstCall.value else {
            Issue.record("the socket that asked first was not answered")
            return
        }
        // The other socket's request with the same id is still waiting.
        #expect(await transportEventually(timeout: 0.5) { await second.pendingRequestCount == 0 } == false)

        #expect(server.answerCapabilities(asError: true))
        guard case .failure = await secondCall.value else {
            Issue.record("the second socket did not get its own reply")
            return
        }
        await first.close(reason: "test over")
        await second.close(reason: "test over")
    }
}

private actor CapabilityPhaseLog {
    private(set) var phases: [HermesConnection.Phase] = []
    func append(_ phase: HermesConnection.Phase) { phases.append(phase) }
}
