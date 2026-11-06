import Foundation
import Testing

@testable import MercuryKit

private final class Dials: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

/// A shared multi-profile authority socket (the Webapp listener) routes a
/// frame to a sibling profile only when `params.profile` names it
/// (`gateway/session_controls.py` `AuthorityConnection.dispatch`). Every
/// session-scoped call must therefore carry the profile the session was
/// opened in, or the launch profile's authority refuses it with 4001.
@Suite("session profile routing")
struct SessionProfileRoutingTests {
    private static let snapshot = #"""
        {"session_id":"local-abc","stored_session_id":"local-abc","messages":[],"message_count":0,
         "running":true,"authority_epoch":7,"replay_epoch":"ep","last_sequence":0,
         "subscription_id":"sub-1","revision":1,"execution_generation":2,"pending":[],"prompts":[],
         "info":{"desktop_protocol":"hermes-gateway-v1","cwd":"/tmp/w"}}
        """#
    private static let receipt =
        #"{"admission_id":"a1","sequence":1,"status":"queued","outcome":null,"authority_epoch":7,"execution_generation":2,"ref":{"profile_id":"work","session_id":"local-abc"}}"#

    private static func answer(_ method: String) -> String {
        switch method {
        case "session.create", "session.resume": return snapshot
        case "prompt.submit", "prompt.cancel", "prompt.steer_queued", "prompt.receipt": return receipt
        case "session.steer", "session.redirect":
            return #"{"status":"queued","text":"x","execution_generation":2,"authority_epoch":7}"#
        case "session.mutate": return #"{"revision":2,"title":"t"}"#
        case "session.detach": return #"{"session_id":"local-abc","subscription_id":"sub-1","detached":true}"#
        case "approval.respond", "clarify.respond": return #"{"status":"resolved"}"#
        case "session.events.since":
            return #"{"events":[],"latest_seq":0,"truncated":false,"epoch":"ep","count":0,"open_requests":[]}"#
        default: return "{}"
        }
    }

    private func connect(
        authority: @escaping @Sendable (Int) -> Bool = { _ in true }
    ) async throws -> (TransportUnionLoopbackGatewayServer, HermesConnection) {
        let dials = Dials()
        let server = try await TransportUnionLoopbackGatewayServer.start(
            onOpen: { server in
                server.sendEvent(
                    type: "gateway.ready",
                    payload: authority(dials.next()) ? #"{"session_authority":true}"# : "{}")
            },
            onRequest: { frame in
                let method = frame["method"]?.stringValue ?? ""
                return #"{"jsonrpc":"2.0","id":\#(frame["id"]?.intValue ?? 0),"result":\#(Self.answer(method))}"#
            })
        let endpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let connection = HermesConnection(endpoint: endpoint, token: nil, adoptsSessionAuthority: true)
        await connection.start()
        #expect(await transportEventually { await connection.phase == .ready(isReconnect: false) })
        return (server, connection)
    }

    /// `profile` of every frame sent for `method`, in order.
    private func profiles(_ server: TransportUnionLoopbackGatewayServer, _ method: String) -> [String?] {
        server.receivedFrames
            .filter { $0["method"]?.stringValue == method }
            .map { $0["params"]?["profile"]?.stringValue }
    }

    /// Drive every session-scoped verb the kit sends on an authority socket.
    private func driveEveryVerb(_ connection: HermesConnection) async {
        let sid = "local-abc"
        _ = try? await connection.submit(sessionID: sid, text: "hi")
        _ = try? await connection.submitPrompt(sessionID: sid, text: "hi", voiceTurn: true)
        _ = try? await connection.steerSession(sessionID: sid, text: "x")
        _ = try? await connection.redirectSession(sessionID: sid, text: "x")
        _ = try? await connection.cancelQueued(sessionID: sid, admissionID: "a1")
        _ = try? await connection.steerQueued(sessionID: sid, admissionID: "a1")
        _ = try? await connection.promptReceipt(sessionID: sid, admissionID: "a1")
        _ = try? await connection.sessionEventsSince(sessionID: sid, lastSeen: 0)
        _ = try? await connection.setSessionTitle(sessionID: sid, title: "t")
        try? await connection.respondApproval(
            sessionID: sid, choice: "once", requestID: "p-1", executionGeneration: 2)
        _ = try? await connection.respondClarifyPrompt(
            sessionID: sid, promptID: "p-2", answer: "yes", executionGeneration: 2)
        _ = try? await connection.activateSession(sessionID: sid)
        try? await connection.interruptSession(sessionID: sid)
        _ = await connection.closeSession(sessionID: sid)
    }

    private static let verbs = [
        "prompt.submit", "session.steer", "session.redirect", "prompt.cancel", "prompt.steer_queued",
        "prompt.receipt", "session.events.since", "session.mutate", "approval.respond",
        "clarify.respond", "session.resume", "session.interrupt", "session.detach",
    ]

    @Test func aProfiledSessionStampsEverySessionCall() async throws {
        let (server, connection) = try await connect()
        defer { server.stop() }
        _ = try await connection.createSession(profile: "work")
        await driveEveryVerb(connection)

        #expect(profiles(server, "session.create") == ["work"])
        for verb in Self.verbs {
            let sent = profiles(server, verb)
            #expect(!sent.isEmpty, "\(verb) was never sent")
            #expect(sent.allSatisfy { $0 == "work" }, "\(verb) sent \(sent)")
        }
        // prompt.submit twice (submit + submitPrompt); activate's resume too.
        #expect(profiles(server, "prompt.submit").count == 2)
        await connection.stop()
    }

    @Test func aResumedSessionStampsItsProfile() async throws {
        let (server, connection) = try await connect()
        defer { server.stop() }
        _ = try await connection.resumeSession(storedID: "local-abc", profile: "work")
        _ = try await connection.submit(sessionID: "local-abc", text: "hi")
        try await connection.interruptSession(sessionID: "local-abc")
        #expect(profiles(server, "prompt.submit") == ["work"])
        #expect(profiles(server, "session.interrupt") == ["work"])
        await connection.stop()
    }

    @Test func aSessionWithoutAProfileSendsNone() async throws {
        let (server, connection) = try await connect()
        defer { server.stop() }
        _ = try await connection.createSession()
        await driveEveryVerb(connection)
        let stamped = server.receivedFrames.filter { $0["params"]?["profile"] != nil }
        #expect(stamped.isEmpty, "unexpected profile on \(stamped.compactMap { $0["method"]?.stringValue })")
        await connection.stop()
    }

    @Test func theDefaultProfileIsCarriedAsOpened() async throws {
        // A session opened in `default` names it as create did; on the
        // launch profile's own authority hermes strips it again.
        let (server, connection) = try await connect()
        defer { server.stop() }
        _ = try await connection.createSession(profile: "default")
        _ = try await connection.submit(sessionID: "local-abc", text: "hi")
        #expect(profiles(server, "prompt.submit") == ["default"])
        await connection.stop()
    }

    @Test func anExplicitProfileIsNotOverwritten() async throws {
        let (server, connection) = try await connect()
        defer { server.stop() }
        _ = try await connection.createSession(profile: "work")
        _ = try await connection.setConfig(
            sessionID: "local-abc", key: "approvals.mode", value: .string("smart"), profile: "other")
        #expect(profiles(server, "config.set") == ["other"])
        await connection.stop()
    }

    @Test func answersAndUnlistedMethodsAreUntouched() async throws {
        let (server, connection) = try await connect()
        defer { server.stop() }
        _ = try await connection.createSession(profile: "work")
        _ = try? await connection.answerServerRequest(id: "r-1", result: .object(["choice": "once"]))
        _ = try? await connection.request(
            "session.branch", params: ["session_id": "local-abc"])
        #expect(profiles(server, "request.answer") == [nil])
        #expect(profiles(server, "session.branch") == [nil])
        await connection.stop()
    }

    @Test func aLegacySocketKeepsItsParams() async throws {
        let (server, connection) = try await connect(authority: { _ in false })
        defer { server.stop() }
        _ = try await connection.createSession(profile: "work")
        _ = try? await connection.submit(sessionID: "local-abc", text: "hi")
        #expect(profiles(server, "session.create") == ["work"])
        #expect(!profiles(server, "prompt.submit").isEmpty)
        #expect(profiles(server, "prompt.submit").allSatisfy { $0 == nil })
        await connection.stop()
    }

    @Test func theProfileSurvivesAReconnect() async throws {
        let (server, connection) = try await connect()
        defer { server.stop() }
        _ = try await connection.createSession(profile: "work")
        server.dropConnections()
        #expect(
            await transportEventually(timeout: 15) {
                await connection.phase == .ready(isReconnect: true)
            })
        // Before any re-resume: the session's profile is still known.
        _ = try? await connection.sessionEventsSince(sessionID: "local-abc", lastSeen: 0)
        #expect(profiles(server, "session.events.since") == ["work"])
        await connection.stop()
    }
}
