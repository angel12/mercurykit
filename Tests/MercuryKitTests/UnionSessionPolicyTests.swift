import Foundation
import Testing
@testable import MercuryKit

@Suite("Union session policy and request contracts", .timeLimit(.minutes(1)))
struct UnionSessionPolicyTests {
    private final class Frames: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [JSONValue] = []
        func append(_ value: JSONValue) { lock.withLock { values.append(value) } }
        var last: JSONValue? { lock.withLock { values.last } }
    }
    private func connected(_ port: UInt16) async throws -> HermesConnection {
        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(port)").endpoint
        let connection = HermesConnection(endpoint: endpoint, token: "test-token")
        await connection.start()
        for await update in await connection.updates() {
            if case .phase(.ready) = update { break }
        }
        return connection
    }
    private func server(_ frames: Frames, result: String) async throws -> LocalGatewayServer {
        try await LocalGatewayServer.start(onText: { text, server in
            guard let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
                  let id = frame["id"]?.intValue else { return }
            frames.append(frame)
            server.respond(id: id, result: result)
        })
    }

    @Test func resumeFlagsAreCallerOwned() async throws {
        let frames = Frames()
        let server = try await server(frames, result: #"{"session_id":"runtime","resumed":"tip"}"#)
        defer { server.stop() }
        let connection = try await connected(server.port)
        let handle = try await connection.resumeSession(storedID: "stored", profile: "work")
        #expect(handle.runtimeID == "runtime")
        #expect(handle.storedID == "tip")
        #expect(frames.last?["params"] == ["session_id":"stored", "profile":"work", "cols":96, "source":"desktop", "omit_messages":true])
        _ = try await connection.resumeSession(storedID: "stored", omitMessages: false, deferHistory: true)
        #expect(frames.last?["params"] == ["session_id":"stored", "cols":96, "source":"desktop", "omit_messages":false, "defer_history":true])
        await connection.stop()
    }

    @Test func activationValidatesIdentityEnvelope() async throws {
        let frames = Frames()
        let server = try await server(frames, result: #"{"session_id":"runtime","session_key":"stored","started_at":1,"status":"idle","running":false}"#)
        defer { server.stop() }
        let connection = try await connected(server.port)
        let snapshot = try await connection.activateSession(sessionID: "runtime")
        #expect(snapshot.runtimeID == "runtime")
        #expect(frames.last?["method"] == "session.activate")
        #expect(frames.last?["params"] == ["session_id":"runtime", "omit_messages":true])
        await connection.stop()
    }

    @Test func activationRefusesMalformedEnvelope() async throws {
        let frames = Frames()
        let server = try await server(frames, result: #"{"session_id":"runtime"}"#)
        defer { server.stop() }
        let connection = try await connected(server.port)
        await #expect(throws: HermesError.self) { _ = try await connection.activateSession(sessionID: "runtime") }
        await connection.stop()
    }

    @Test func projectLimitsAndNestedHydration() async throws {
        let frames = Frames()
        let server = try await server(frames, result: #"{"project":{"repos":[{"groups":[{"sessions":[{"id":"stored"}]}]}]}}"#)
        defer { server.stop() }
        let connection = try await connected(server.port)
        _ = try await connection.projectsTree(profile: "work")
        #expect(frames.last?["params"] == ["preview_limit":3, "profile":"work"])
        _ = try await connection.projectsTree(previewLimit: 7)
        #expect(frames.last?["params"] == ["preview_limit":7])
        let rows = try await connection.projectSessions(projectID: "project", profile: "work", sessionLimit: 12)
        #expect(rows.map(\.storedID) == ["stored"])
        #expect(frames.last?["params"] == ["project_id":"project", "profile":"work", "session_limit":12])
        _ = try await connection.projectSessions(projectID: "project")
        #expect(frames.last?["params"] == ["project_id":"project"])
        await connection.stop()
    }

    @Test func canonicalReplayAndAliasAreFailClosed() async throws {
        let frames = Frames()
        let server = try await server(frames, result: #"{"events":[],"latest_seq":4,"epoch":"e"}"#)
        defer { server.stop() }
        let connection = try await connected(server.port)
        let replay = try await connection.sessionEventsSince(sessionID: "runtime", lastSeen: 4)
        #expect(replay.truncated)
        #expect(!replay.isLossless(under: "e", forSession: "runtime", after: 4))
        #expect(frames.last?["params"] == ["session_id":"runtime", "last_seen":4])
        let alias = try await connection.eventsSince(sessionID: "runtime", lastSeen: 4)
        #expect(alias == replay)
        await connection.stop()
    }

    /// The contract-6 reply methods stay for older backends.
    @available(*, deprecated)
    @Test func exactBlockingPromptPayloadsAndSubmitStatus() async throws {
        let frames = Frames()
        let server = try await server(frames, result: #"{"status":"ok","remaining":["q2"]}"#)
        defer { server.stop() }
        let connection = try await connected(server.port)
        for requestID in [nil, "", "approval-1"] as [String?] {
            try await connection.respondApproval(sessionID: "runtime", choice: "once", requestID: requestID)
            var expected: JSONValue = ["session_id":"runtime", "choice":"once"]
            if requestID == "approval-1" { expected = ["session_id":"runtime", "choice":"once", "request_id":"approval-1"] }
            #expect(frames.last?["params"] == expected)
        }
        #expect(try await connection.respondSudo(requestID: "sudo-1", password: "test-password") == .accepted)
        #expect(frames.last?["params"] == ["request_id":"sudo-1", "password":"test-password"])
        #expect(try await connection.respondSecret(requestID: "secret-1", value: "test-value") == .accepted)
        #expect(frames.last?["params"] == ["request_id":"secret-1", "value":"test-value"])
        #expect(try await connection.respondClarifyQuestion(requestID: "clarify-1", questionID: "q1", answer: "yes") == ["q2"])
        #expect(frames.last?["params"] == ["request_id":"clarify-1", "question_id":"q1", "answer":"yes"])
        #expect(try await connection.submitPrompt(sessionID: "runtime", text: "hello") == "ok")
        await connection.stop()
    }

    /// `session.redirect` answers `redirected` when the active turn took it,
    /// `queued` during the turn-build window (it runs next turn) and
    /// `rejected` when the agent refused (`methods_session.py`
    /// `_correction_method`).
    @Test(arguments: [("redirected", true), ("queued", true), ("rejected", false)])
    func redirectReportsAcceptance(status: String, accepted: Bool) async throws {
        let frames = Frames()
        let server = try await server(frames, result: #"{"status":"\#(status)","text":"go left"}"#)
        defer { server.stop() }
        let connection = try await connected(server.port)
        #expect(try await connection.redirectSession(sessionID: "runtime", text: "go left") == accepted)
        #expect(frames.last?["method"] == "session.redirect")
        #expect(frames.last?["params"] == ["session_id":"runtime", "text":"go left"])
        await connection.stop()
    }

    /// `session.steer` answers `queued` on acceptance, `rejected` otherwise.
    @Test(arguments: [("queued", true), ("rejected", false), ("redirected", false)])
    func steerReportsAcceptance(status: String, accepted: Bool) async throws {
        let frames = Frames()
        let server = try await server(frames, result: #"{"status":"\#(status)","text":"note"}"#)
        defer { server.stop() }
        let connection = try await connected(server.port)
        #expect(try await connection.steerSession(sessionID: "runtime", text: "note") == accepted)
        #expect(frames.last?["method"] == "session.steer")
        #expect(frames.last?["params"] == ["session_id":"runtime", "text":"note"])
        await connection.stop()
    }

    @Test(arguments: [true, false]) func closeReportsConfirmation(closed: Bool) async throws {
        let frames = Frames()
        let server = try await server(frames, result: closed ? #"{"closed":true}"# : #"{"closed":false}"#)
        defer { server.stop() }
        let connection = try await connected(server.port)
        #expect(await connection.closeSession(sessionID: "runtime") == (closed ? .closed : .unconfirmed))
        await connection.stop()
        if case .failed = await connection.closeSession(sessionID: "runtime") {} else { Issue.record("Disconnected close must fail") }
    }
}

@Suite("Desktop contract requirement")
struct DesktopContractRequirementTests {
    @Test func eachAppSuppliesItsOwnMinimum() {
        #expect(DesktopContractRequirement.promptEvents.minimum == 6)
        #expect(DesktopContractRequirement.serverRequests.minimum == 7)
        let requirement = DesktopContractRequirement.serverRequests
        #expect(requirement.assess(nil) == .unknown)
        #expect(requirement.assess(6) == .older(6))
        #expect(requirement.assess(7) == .satisfied(7))
        // Contract 8 (connectors only) is not a warning for either app.
        #expect(requirement.assess(8) == .satisfied(8))
        #expect(DesktopContractRequirement.promptEvents.assess(8) == .satisfied(8))
        #expect(DesktopContractRequirement(minimum: 9).assess(8) == .older(8))
    }

    /// Chat compares against the old constant with `!=`; its notice must not
    /// change until Chat moves to a requirement of its own.
    @available(*, deprecated)
    @Test func theLegacyConstantStaysAtTheBaseline() {
        #expect(GatewayClient.builtAgainstDesktopContract == 6)
    }
}
