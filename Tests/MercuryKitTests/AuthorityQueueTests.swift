import Foundation
import Testing

@testable import MercuryKit

/// The shared queue and the revision-fenced session edits a v0.23 session
/// authority serves (QueueAPI.swift), plus the calls that change shape there:
/// rename, compress, model, steer/redirect and the contract probe. Shapes are
/// hermes-agent v0.23.0, live-checked against a throwaway Webapp listener
/// (VERIFICATION.md).
@Suite("session authority queue and mutations")
struct AuthorityQueueTests {
    private static let snapshot = #"""
        {"session_id":"local-abc","stored_session_id":"local-abc","messages":[],"message_count":0,
         "running":true,"authority_epoch":7,"replay_epoch":"ep","last_sequence":0,
         "subscription_id":"sub-1","revision":4,"execution_generation":2,"pending":[],"prompts":[],
         "info":{"desktop_protocol":"hermes-gateway-v1"}}
        """#

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func next(_ method: String) -> Int {
            lock.withLock {
                counts[method, default: 0] += 1
                return counts[method]!
            }
        }
    }

    /// `reply(method, nth)` returns a full `result` JSON or `!{error}`.
    private func connect(
        authority: Bool = true,
        reply: @escaping @Sendable (String, Int) -> String
    ) async throws -> (TransportUnionLoopbackGatewayServer, HermesConnection) {
        let counter = Counter()
        let server = try await TransportUnionLoopbackGatewayServer.start(
            onOpen: { server in
                server.sendEvent(
                    type: "gateway.ready",
                    payload: authority ? #"{"session_authority":true}"# : "{}")
            },
            onRequest: { frame in
                let method = frame["method"]?.stringValue ?? ""
                let id = frame["id"]?.intValue ?? 0
                let body = reply(method, counter.next(method))
                if body.hasPrefix("!") {
                    return #"{"jsonrpc":"2.0","id":\#(id),"error":\#(body.dropFirst())}"#
                }
                return #"{"jsonrpc":"2.0","id":\#(id),"result":\#(body)}"#
            })
        let endpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let connection = HermesConnection(endpoint: endpoint, token: nil, adoptsSessionAuthority: true)
        await connection.start()
        #expect(await transportEventually { await connection.phase == .ready(isReconnect: false) })
        return (server, connection)
    }

    private func frames(_ server: TransportUnionLoopbackGatewayServer, _ method: String) -> [JSONValue] {
        server.receivedFrames.filter { $0["method"]?.stringValue == method }.compactMap { $0["params"] }
    }

    private static func base(_ method: String) -> String? {
        switch method {
        case "session.create", "session.resume": return snapshot
        default: return nil
        }
    }

    // MARK: Queue decoding

    @Test func pendingRowsDecodeInSequenceOrder() {
        let payload: JSONValue = [
            "revision": 3,
            "pending": [
                ["admission_id": "b", "sequence": 2, "status": "queued", "text": "two",
                 "controls": ["steer", "replace", "mystery"], "steering": false],
                ["admission_id": "a", "sequence": 1, "status": "started", "text": "one", "controls": []],
                ["sequence": 3, "text": "no id"],
            ],
        ]
        let queue = QueuedPrompt.list(from: payload)
        #expect(queue?.map(\.admissionID) == ["a", "b"])
        #expect(queue?[0].status == .started)
        #expect(queue?[1].controls == [.steer, .replace])
        #expect(QueuedPrompt.list(from: ["running": true]) == nil)
        #expect(QueuedPrompt.list(from: ["pending": []]) == [])
    }

    // MARK: Queue verbs

    @Test func queueVerbsSendTheCanonicalParams() async throws {
        let (server, connection) = try await connect { method, _ in
            Self.base(method) ?? #"{"admission_id":"a2","status":"terminal","outcome":"cancelled"}"#
        }
        defer { server.stop() }
        let handle = try await connection.createSession()
        let cancelled = try await connection.cancelQueued(sessionID: handle.runtimeID, admissionID: "a1")
        #expect(cancelled.outcome == "cancelled")
        _ = try await connection.replaceQueued(
            sessionID: handle.runtimeID, admissionID: "a1", text: "edited", submissionID: "s-9")
        _ = try await connection.steerQueued(sessionID: handle.runtimeID, admissionID: "a1")
        _ = try await connection.promptReceipt(sessionID: handle.runtimeID, admissionID: "a1")
        #expect(frames(server, "prompt.cancel").last == ["session_id": "local-abc", "admission_id": "a1"])
        #expect(
            frames(server, "prompt.replace_queued").last
                == ["session_id": "local-abc", "admission_id": "a1", "text": "edited", "submission_id": "s-9"])
        #expect(frames(server, "prompt.steer_queued").last == ["session_id": "local-abc", "admission_id": "a1"])
        #expect(frames(server, "prompt.receipt").last == ["session_id": "local-abc", "admission_id": "a1"])
    }

    @Test func queueVerbsNeedTheAuthority() async throws {
        let (server, connection) = try await connect(authority: false) { _, _ in "{}" }
        defer { server.stop() }
        await #expect(throws: HermesError.self) {
            try await connection.cancelQueued(sessionID: "s", admissionID: "a")
        }
        #expect(frames(server, "prompt.cancel").isEmpty)
    }

    @Test func submitKeepsTheCallersSubmissionID() async throws {
        let (server, connection) = try await connect { method, _ in
            Self.base(method) ?? #"{"admission_id":"a1","status":"queued","sequence":1}"#
        }
        defer { server.stop() }
        let handle = try await connection.createSession()
        let receipt = try await connection.submit(sessionID: handle.runtimeID, text: "hi", submissionID: "sub-1")
        #expect(receipt.admissionID == "a1")
        #expect(frames(server, "prompt.submit").last?["submission_id"] == "sub-1")
    }

    // MARK: Mutations

    @Test func renameIsARevisionFencedMutation() async throws {
        let (server, connection) = try await connect { method, _ in
            Self.base(method) ?? #"{"session_id":"local-abc","operation":"rename","revision":5,"title":"New"}"#
        }
        defer { server.stop() }
        let handle = try await connection.createSession()
        let title = try await connection.setSessionTitle(sessionID: handle.runtimeID, title: "New")
        #expect(title == "New")
        let sent = try #require(frames(server, "session.mutate").last)
        #expect(sent["operation"] == "rename")
        #expect(sent["payload"] == ["title": "New"])
        #expect(sent["expected_revision"] == 4)
        #expect(sent["expected_generation"] == nil)
        #expect(sent["request_id"]?.stringValue?.isEmpty == false)
        #expect(frames(server, "session.title").isEmpty)
    }

    @Test func aRevisionConflictRetriesOnceWithTheFreshFences() async throws {
        let (server, connection) = try await connect { method, nth in
            if let base = Self.base(method) { return base }
            guard method == "session.mutate" else { return "{}" }
            return nth == 1
                ? #"!{"code":4001,"message":"revision_conflict","data":{"reason":"revision_conflict","revision":9,"execution_generation":3}}"#
                : #"{"session_id":"local-abc","operation":"compress","revision":10,"status":"compressed"}"#
        }
        defer { server.stop() }
        let handle = try await connection.createSession()
        let status = try await connection.compressSession(sessionID: handle.runtimeID)
        #expect(status == "compressed")
        let sent = frames(server, "session.mutate")
        #expect(sent.count == 2)
        #expect(sent[0]["expected_revision"] == 4 && sent[0]["expected_generation"] == 2)
        #expect(sent[1]["expected_revision"] == 9 && sent[1]["expected_generation"] == 3)
        #expect(sent[0]["request_id"] != sent[1]["request_id"])
    }

    @Test func aSecondConflictSurfaces() async throws {
        let (server, connection) = try await connect { method, _ in
            Self.base(method)
                ?? #"!{"code":4001,"message":"revision_conflict","data":{"reason":"revision_conflict","revision":9}}"#
        }
        defer { server.stop() }
        let handle = try await connection.createSession()
        await #expect(throws: HermesError.self) {
            _ = try await connection.setSessionTitle(sessionID: handle.runtimeID, title: "x")
        }
        #expect(frames(server, "session.mutate").count == 2)
    }

    @Test func modelPickIsAFencedMutation() async throws {
        let (server, connection) = try await connect { method, _ in
            Self.base(method) ?? #"{"session_id":"local-abc","operation":"model","revision":5,"model":"m"}"#
        }
        defer { server.stop() }
        let handle = try await connection.createSession()
        let result = try await connection.setSessionModel(sessionID: handle.runtimeID, model: "m", provider: "p")
        #expect(result.value == "m")
        let sent = try #require(frames(server, "session.mutate").last)
        #expect(sent["operation"] == "model")
        #expect(sent["payload"] == ["model": "m", "provider": "p"])
        #expect(sent["expected_generation"] == 2)
        #expect(frames(server, "config.set").isEmpty)
    }

    @Test func sessionInfoAdvancesTheRevision() async throws {
        let (server, connection) = try await connect { method, _ in
            Self.base(method) ?? #"{"session_id":"local-abc","operation":"rename","revision":8}"#
        }
        defer { server.stop() }
        let handle = try await connection.createSession()
        server.send(#"{"jsonrpc":"2.0","method":"event","params":{"type":"session.info","session_id":"local-abc","payload":{"revision":7,"execution_generation":2}}}"#)
        #expect(await transportEventually { await connection.sessionRevisions[handle.runtimeID] == 7 })
        // A replayed older snapshot never rewinds it.
        server.send(#"{"jsonrpc":"2.0","method":"event","params":{"type":"session.info","session_id":"local-abc","payload":{"revision":5}}}"#)
        _ = try await connection.setSessionTitle(sessionID: handle.runtimeID, title: "x")
        #expect(frames(server, "session.mutate").last?["expected_revision"] == 7)
    }

    // MARK: Turn corrections and the probe

    @Test func steerCarriesTheGenerationAndStaleMeansRejected() async throws {
        let (server, connection) = try await connect { method, _ in
            if let base = Self.base(method) { return base }
            return method == "session.redirect"
                ? #"!{"code":4001,"message":"stale_generation","data":{"reason":"stale_generation"}}"#
                : #"{"status":"queued","text":"x"}"#
        }
        defer { server.stop() }
        let handle = try await connection.createSession()
        #expect(try await connection.steerSession(sessionID: handle.runtimeID, text: "x"))
        #expect(frames(server, "session.steer").last?["execution_generation"] == 2)
        #expect(try await connection.redirectSession(sessionID: handle.runtimeID, text: "x") == false)
    }

    @Test func probeCreatesNothingOnAnAuthority() async throws {
        let (server, connection) = try await connect { method, _ in Self.base(method) ?? "{}" }
        defer { server.stop() }
        #expect(try await connection.probeDesktopContract() == nil)
        #expect(frames(server, "session.create").isEmpty)
    }
}
