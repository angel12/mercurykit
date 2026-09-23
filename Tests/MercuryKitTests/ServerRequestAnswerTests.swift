import Foundation
import Testing

@testable import MercuryKit

/// Answering contract ≥ 7 prompts: `request.answer`, `clarify.lock`,
/// `connection.respond`, and the result objects they carry. Upstream
/// validates every params object with `extra="forbid"` (4000 on an unknown
/// key), so the exact shapes are the contract.
@Suite("Server request answers", .timeLimit(.minutes(1)))
struct ServerRequestAnswerTests {
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
                let id = frame["id"]?.intValue
            else { return }
            frames.append(frame)
            server.respond(id: id, result: result)
        })
    }

    // MARK: Result builders

    @Test func resultBuildersMatchTheContract() {
        #expect(ServerRequestResult.approval(choice: "once") == ["choice": "once"])
        #expect(ServerRequestResult.approval(choice: "deny", all: true) == ["choice": "deny", "all": true])
        #expect(ServerRequestResult.clarify(answer: "dev") == ["answer": "dev"])
        #expect(ServerRequestResult.clarify(answer: "") == ["answer": ""])
        #expect(
            ServerRequestResult.clarify(answers: ["q1": "dev", "q2": "main"])
                == ["answers": ["q1": "dev", "q2": "main"]])
        // Cancel-all is neither `answer` nor `answers`: an empty object.
        #expect(ServerRequestResult.clarifyCancelAll == .object([:]))
        #expect(ServerRequestResult.value("hunter2") == ["value": "hunter2"])
        #expect(ServerRequestResult.value("") == ["value": ""])
    }

    // MARK: request.answer

    @Test func answerSendsExactlyIDAndResult() async throws {
        let frames = Frames()
        let server = try await server(frames, result: #"{"status":"ok"}"#)
        defer { server.stop() }
        let connection = try await connected(server.port)
        let status = try await connection.answerServerRequest(
            id: "srq-aaaaaaaaaaaa", result: ServerRequestResult.approval(choice: "once"))
        #expect(status == .accepted)
        #expect(frames.last?["method"] == "request.answer")
        #expect(frames.last?["params"] == ["id": "srq-aaaaaaaaaaaa", "result": ["choice": "once"]])
        await connection.stop()
    }

    @Test func anExpiredAnswerIsReportedAsExpired() async throws {
        let frames = Frames()
        let server = try await server(frames, result: #"{"status":"expired"}"#)
        defer { server.stop() }
        let connection = try await connected(server.port)
        #expect(
            try await connection.answerServerRequest(
                id: "srq-bbbbbbbbbbbb", result: ServerRequestResult.clarifyCancelAll) == .expired)
        #expect(frames.last?["params"] == ["id": "srq-bbbbbbbbbbbb", "result": .object([:])])
        await connection.stop()
    }

    /// mercury-voice #126 read an unknown or missing status as delivered.
    /// The kit refuses to claim delivery it has no evidence for.
    @Test(arguments: [#"{"status":"something-new"}"#, #"{}"#, #"{"status":null}"#])
    func anUnknownAnswerStatusThrows(reply: String) async throws {
        let frames = Frames()
        let server = try await server(frames, result: reply)
        defer { server.stop() }
        let connection = try await connected(server.port)
        await #expect(throws: HermesError.self) {
            _ = try await connection.answerServerRequest(
                id: "srq-cccccccccccc", result: ServerRequestResult.value(""))
        }
        await connection.stop()
    }

    // MARK: clarify.lock

    @Test func lockSendsTheDeclaredKeysAndReturnsRemaining() async throws {
        let frames = Frames()
        let server = try await server(frames, result: #"{"status":"ok","remaining":["q2"]}"#)
        defer { server.stop() }
        let connection = try await connected(server.port)
        #expect(
            try await connection.lockClarifyAnswer(
                requestID: "srq-dddddddddddd", questionID: "q1", answer: "dev") == ["q2"])
        #expect(frames.last?["method"] == "clarify.lock")
        #expect(
            frames.last?["params"]
                == ["request_id": "srq-dddddddddddd", "question_id": "q1", "answer": "dev"])
        await connection.stop()
    }

    @Test func anExpiredLockIsNil() async throws {
        let frames = Frames()
        let server = try await server(frames, result: #"{"status":"expired"}"#)
        defer { server.stop() }
        let connection = try await connected(server.port)
        #expect(
            try await connection.lockClarifyAnswer(
                requestID: "srq-dddddddddddd", questionID: "q1", answer: "dev") == nil)
        await connection.stop()
    }

    @Test func anUnknownLockStatusThrows() async throws {
        let frames = Frames()
        let server = try await server(frames, result: #"{"remaining":[]}"#)
        defer { server.stop() }
        let connection = try await connected(server.port)
        await #expect(throws: HermesError.self) {
            _ = try await connection.lockClarifyAnswer(
                requestID: "srq-dddddddddddd", questionID: "q1", answer: "dev")
        }
        await connection.stop()
    }

    // MARK: connection.respond

    private static let answer = ConnectionAnswer(
        targets: [
            .init(name: "github", status: .approved, env: ["GITHUB_TOKEN": "t"]),
            .init(name: "linear", status: .skipped, detail: "not now"),
        ],
        continueOperation: true)

    private static let answerJSON: JSONValue = [
        "targets": [
            ["name": "github", "status": "approved", "env": ["GITHUB_TOKEN": "t"]],
            ["name": "linear", "status": "skipped", "detail": "not now"],
        ],
        "settled_by": "continue",
    ]

    /// Contract 8 moved the session into `owner`; unknown means current.
    @Test(arguments: [8, 9, nil] as [Int?])
    func respondConnectionUsesTheOwnerShapeFromContract8(contract: Int?) async throws {
        let frames = Frames()
        let server = try await server(frames, result: #"{"status":"ok","settled":true}"#)
        defer { server.stop() }
        let connection = try await connected(server.port)
        #expect(
            try await connection.respondConnection(
                sessionID: "rt", opID: "op-1", answer: Self.answer, desktopContract: contract))
        #expect(frames.last?["method"] == "connection.respond")
        #expect(
            frames.last?["params"]
                == [
                    "owner": ["type": "session", "session_id": "rt"], "op_id": "op-1",
                    "result": Self.answerJSON,
                ])
        await connection.stop()
    }

    @Test func respondConnectionUsesSessionIDOnContract7() async throws {
        let frames = Frames()
        let server = try await server(frames, result: #"{"status":"ok","settled":false}"#)
        defer { server.stop() }
        let connection = try await connected(server.port)
        let bare = ConnectionAnswer(targets: [.init(name: "github", status: .approved)])
        #expect(
            try await connection.respondConnection(
                sessionID: "rt", opID: "op-1", answer: bare, desktopContract: 7) == false)
        #expect(
            frames.last?["params"]
                == [
                    "session_id": "rt", "op_id": "op-1",
                    "result": ["targets": [["name": "github", "status": "approved"]]],
                ])
        await connection.stop()
    }

    @Test(arguments: [#"{"settled":true}"#, #"{"status":"ok"}"#, #"{"status":"no","settled":true}"#])
    func anUnconfirmedConnectionRespondThrows(reply: String) async throws {
        let frames = Frames()
        let server = try await server(frames, result: reply)
        defer { server.stop() }
        let connection = try await connected(server.port)
        await #expect(throws: HermesError.self) {
            _ = try await connection.respondConnection(
                sessionID: "rt", opID: "op-1", answer: Self.answer, desktopContract: 8)
        }
        await connection.stop()
    }

    // MARK: connection.request decoding

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    @Test func connectionRequestDecodes() throws {
        let event = GatewayEvent(
            type: GatewayEvent.Kind.connectionRequest, sessionID: "rt",
            payload: try json(
                """
                {"op_id": "op-1", "seq": 3, "deadline_at": 1790000000.5, "timeout_seconds": 600,
                 "tool_call_id": "call_9",
                 "targets": [
                   {"name": "github", "kind": "mcp", "action": "install", "state": "pending",
                    "detail": "GitHub MCP", "required_env": [
                      {"name": "GITHUB_TOKEN", "required": true, "secret": true, "default": "", "prompt": "Token"}]},
                   {"name": "linear", "kind": "connector", "action": "connect", "state": "initiated",
                    "connect_url": "https://example.test/connect", "tier": "official"}
                 ]}
                """))
        let request = try #require(ConnectionRequest(event: event))
        #expect(request.opID == "op-1")
        #expect(request.id == "op-1")
        #expect(request.sessionID == "rt")
        #expect(request.seq == 3)
        #expect(request.deadlineAt == 1_790_000_000.5)
        #expect(request.timeoutSeconds == 600)
        #expect(request.toolCallID == "call_9")
        #expect(request.targets.map(\.name) == ["github", "linear"])
        #expect(request.targets[0].requiredEnv.first?.name == "GITHUB_TOKEN")
        #expect(request.targets[0].requiredEnv.first?.secret == true)
        #expect(request.targets[1].connectURL == "https://example.test/connect")
        #expect(request.targets[1].raw["tier"] == "official")
    }

    @Test(arguments: [
        #"{"seq": 1, "deadline_at": 1, "timeout_seconds": 1, "targets": []}"#,
        #"{"op_id": "op", "deadline_at": 1, "timeout_seconds": 1, "targets": []}"#,
        #"{"op_id": "op", "seq": 1, "timeout_seconds": 1, "targets": []}"#,
        #"{"op_id": "op", "seq": 1, "deadline_at": 1, "timeout_seconds": 1}"#,
        #"{"op_id": "op", "seq": 1, "deadline_at": 1, "timeout_seconds": 1, "targets": [{"name": "x"}]}"#,
        #"{"op_id": "op", "seq": 1, "deadline_at": 1, "timeout_seconds": 1, "targets": [{"name": "x", "kind": "mcp", "action": "install", "state": "pending", "required_env": [{"name": "K"}]}]}"#,
    ])
    func connectionRequestFailsClosed(payload: String) throws {
        #expect(ConnectionRequest(payload: try json(payload), sessionID: "rt") == nil)
    }

    @Test func connectionRequestOnlyDecodesItsEvent() throws {
        let event = GatewayEvent(type: GatewayEvent.Kind.connectionUpdate, sessionID: "rt", payload: [:])
        #expect(ConnectionRequest(event: event) == nil)
    }
}
