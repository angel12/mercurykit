import Foundation
import Testing

@testable import MercuryKit

/// HermesRESTClient against a scripted local HTTP server: stored session ids
/// are interpolated into request paths, so every reserved character in an id
/// (above all `/`) must arrive single-percent-encoded — a raw `/` would
/// splice extra path segments into the route; a double-encoded `%252F`
/// would 404 server-side.
@Suite("HermesRESTClient", .timeLimit(.minutes(1)))
struct HermesRESTClientTests {
    private func client(port: UInt16) throws -> HermesRESTClient {
        HermesRESTClient(
            endpoint: try ServerEndpoint.parse("http://127.0.0.1:\(port)").endpoint,
            token: "tok")
    }

    @Test func sessionMessagesEncodesSlashInStoredID() async throws {
        let server = try await ScriptedHTTPServer.start { _ in
            ScriptedHTTPResponse(200, #"{"messages": []}"#)
        }
        defer { server.stop() }

        _ = try await client(port: server.port).sessionMessages(storedID: "a/b")

        #expect(server.requests.map(\.path) == ["/api/sessions/a%2Fb/messages"])
    }

    @Test func updateSessionEncodesReservedCharactersInStoredID() async throws {
        let server = try await ScriptedHTTPServer.start(handler: Self.fencedBackend)
        defer { server.stop() }

        // `/ : @ & + ,` all pass through `.urlPathAllowed` unencoded.
        try await client(port: server.port).updateSession(
            storedID: "a/b:c@d", title: "renamed")

        #expect(server.requests.map(\.method) == ["GET", "PATCH"])
        #expect(
            server.requests.map(\.path) == [
                "/api/sessions/a%2Fb%3Ac%40d/mutation-snapshot",
                "/api/sessions/a%2Fb%3Ac%40d",
            ])
    }

    @Test func deleteSessionEncodesSlashInStoredID() async throws {
        let server = try await ScriptedHTTPServer.start(handler: Self.fencedBackend)
        defer { server.stop() }

        try await client(port: server.port).deleteSession(storedID: "a/b")

        #expect(server.requests.map(\.method) == ["GET", "DELETE"])
        #expect(server.requests.last?.path.hasPrefix("/api/sessions/a%2Fb?") == true)
    }

    // MARK: Fenced session edits (hermes-agent eb329d21ba)

    /// A v0.22.2+ backend: the snapshot reports revision 7, generation 2;
    /// every write succeeds.
    @Sendable private static func fencedBackend(_ request: CapturedHTTPRequest) -> ScriptedHTTPResponse {
        if request.path.contains("/mutation-snapshot") {
            return ScriptedHTTPResponse(
                200,
                #"{"session_id": "s", "exists": true, "runtime_revision": 7, "runtime_generation": 2}"#)
        }
        return ScriptedHTTPResponse(200, #"{"ok": true}"#)
    }

    private static func expectHTTPError(
        _ status: Int, _ detail: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("expected HTTP \(status) \(detail)", sourceLocation: sourceLocation)
        } catch HermesError.httpError(let gotStatus, let gotDetail) {
            #expect(gotStatus == status, sourceLocation: sourceLocation)
            #expect(gotDetail == detail, sourceLocation: sourceLocation)
        } catch {
            Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
        }
    }

    private static func body(_ request: CapturedHTTPRequest) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: request.body)
    }

    private static func query(_ request: CapturedHTTPRequest) -> [String: String] {
        let items = URLComponents(string: "http://x\(request.path)")?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test func updateSessionSendsTheSnapshotRevisionAndAFreshRequestID() async throws {
        let server = try await ScriptedHTTPServer.start(handler: Self.fencedBackend)
        defer { server.stop() }

        try await client(port: server.port).updateSession(
            storedID: "s", pinned: true, profile: "work")

        #expect(server.requests.first?.path == "/api/sessions/s/mutation-snapshot?profile=work")
        let body = try Self.body(try #require(server.requests.last))
        #expect(body["pinned"]?.boolValue == true)
        #expect(body["profile"]?.stringValue == "work")
        #expect(body["expected_revision"]?.intValue == 7)
        #expect(body["expected_generation"]?.intValue == 2)
        let requestID = try #require(body["request_id"]?.stringValue)
        #expect(UUID(uuidString: requestID) != nil)
        // StrictInt on the server: the revision must not arrive as 7.0.
        #expect(String(decoding: server.requests.last!.body, as: UTF8.self)
            .contains(#""expected_revision":7"#))
    }

    @Test func deleteSessionSendsTheIdentityInTheQuery() async throws {
        let server = try await ScriptedHTTPServer.start(handler: Self.fencedBackend)
        defer { server.stop() }

        try await client(port: server.port).deleteSession(storedID: "s", profile: "work")

        let query = Self.query(try #require(server.requests.last))
        #expect(query["profile"] == "work")
        #expect(query["expected_revision"] == "7")
        #expect(query["expected_generation"] == "2")
        #expect(UUID(uuidString: query["request_id"] ?? "") != nil)
    }

    @Test func backendWithoutTheSnapshotRouteGetsThePlainEdit() async throws {
        let server = try await ScriptedHTTPServer.start { request in
            if request.path.contains("/mutation-snapshot") {
                return ScriptedHTTPResponse(
                    404, #"{"detail": "No such API endpoint: /api/sessions/s/mutation-snapshot"}"#)
            }
            return ScriptedHTTPResponse(200, #"{"ok": true}"#)
        }
        defer { server.stop() }

        try await client(port: server.port).updateSession(storedID: "s", title: "t")

        let body = try Self.body(try #require(server.requests.last))
        #expect(server.requests.map(\.method) == ["GET", "PATCH"])
        #expect(body == ["title": "t"])
    }

    @Test func revisionConflictRereadsAndRetriesOnceWithANewRequestID() async throws {
        let writes = Counter()
        let server = try await ScriptedHTTPServer.start { request in
            if request.path.contains("/mutation-snapshot") {
                return Self.fencedBackend(request)
            }
            return writes.next() == 0
                ? ScriptedHTTPResponse(409, #"{"detail": "revision_conflict"}"#)
                : ScriptedHTTPResponse(200, #"{"ok": true}"#)
        }
        defer { server.stop() }

        try await client(port: server.port).updateSession(storedID: "s", title: "t")

        #expect(server.requests.map(\.method) == ["GET", "PATCH", "GET", "PATCH"])
        let first = try Self.body(server.requests[1])["request_id"]?.stringValue
        let second = try Self.body(server.requests[3])["request_id"]?.stringValue
        #expect(first != nil && first != second)
    }

    @Test func aSecondConflictSurfaces() async throws {
        let server = try await ScriptedHTTPServer.start { request in
            request.path.contains("/mutation-snapshot")
                ? Self.fencedBackend(request)
                : ScriptedHTTPResponse(409, #"{"detail": "stale_generation"}"#)
        }
        defer { server.stop() }

        await Self.expectHTTPError(409, "stale_generation") {
            try await client(port: server.port).updateSession(storedID: "s", title: "t")
        }
        #expect(server.requests.count == 4)
    }

    @Test func busySessionIsNotRetried() async throws {
        let server = try await ScriptedHTTPServer.start { request in
            request.path.contains("/mutation-snapshot")
                ? Self.fencedBackend(request)
                : ScriptedHTTPResponse(409, #"{"detail": "session_busy"}"#)
        }
        defer { server.stop() }

        await Self.expectHTTPError(409, "session_busy") {
            try await client(port: server.port).deleteSession(storedID: "s")
        }
        #expect(server.requests.count == 2)
    }

    @Test func deletingAnAbsentSessionSucceedsWithoutWriting() async throws {
        let server = try await ScriptedHTTPServer.start { _ in
            ScriptedHTTPResponse(
                200, #"{"session_id": "s", "exists": false, "runtime_revision": 0, "runtime_generation": null}"#)
        }
        defer { server.stop() }

        try await client(port: server.port).deleteSession(storedID: "s")

        #expect(server.requests.map(\.method) == ["GET"])
    }

    @Test func editingAnAbsentSessionThrowsNotFound() async throws {
        let server = try await ScriptedHTTPServer.start { _ in
            ScriptedHTTPResponse(
                200, #"{"session_id": "s", "exists": false, "runtime_revision": 0, "runtime_generation": null}"#)
        }
        defer { server.stop() }

        await Self.expectHTTPError(404, "not_found") {
            try await client(port: server.port).updateSession(storedID: "s", title: "t")
        }
        #expect(server.requests.map(\.method) == ["GET"])
    }
}

/// Thread-safe call counter for scripted server handlers.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            defer { value += 1 }
            return value
        }
    }
}
