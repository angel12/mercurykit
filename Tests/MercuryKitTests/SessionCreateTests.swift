import Foundation
import Testing

@testable import MercuryKit

/// `session.create`'s `cwd` provenance. Upstream (hermes-agent `a9972dc3f9`,
/// declared in `66bc259712`) lets a named profile's `terminal.cwd` beat a
/// client `cwd` unless `cwd_explicit` is true, because the desktop seeds new
/// chats from an inherited app-global workspace. A kit caller's `cwd` is
/// always a deliberate pick, so it ships the flag. Backends from before that
/// change refuse the undeclared key with 4000, and never override the cwd
/// either, so the kit resends without the flag.
@Suite("Session create", .timeLimit(.minutes(1)))
struct SessionCreateTests {
    private final class Frames: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [JSONValue] = []
        func append(_ frame: JSONValue) { lock.withLock { values.append(frame) } }
        var all: [JSONValue] { lock.withLock { values } }
    }

    private typealias Reply = @Sendable (_ params: JSONValue?) -> Result<String, RPCFailure>

    private struct RPCFailure: Error, Sendable {
        let code: Int
        let message: String
    }

    private static let created = #"{"session_id": "rt1", "info": {"cwd": "/work/app"}}"#

    /// What a backend from before `66bc259712` answers for the new key
    /// (`tui_gateway/contracts/registry.py` `validate_params`).
    private static let undeclaredFlag = RPCFailure(
        code: 4000,
        message:
            "invalid params for session.create: cwd_explicit: Extra inputs are not permitted — the client and "
            + "the Hermes backend are out of sync (different versions); run `hermes update` and restart both")

    private func withGateway<T>(
        _ reply: @escaping Reply, _ body: (HermesConnection, Frames) async throws -> T
    ) async throws -> T {
        let frames = Frames()
        let server = try await LocalGatewayServer.start(onText: { text, server in
            guard let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
                let id = frame["id"]?.intValue
            else { return }
            frames.append(frame)
            switch reply(frame["params"]) {
            case .success(let result): server.respond(id: id, result: result)
            case .failure(let failure):
                server.respondError(id: id, code: failure.code, message: failure.message)
            }
        })
        defer { server.stop() }
        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let connection = HermesConnection(endpoint: endpoint, token: "test-token")
        await connection.start()
        for await update in await connection.updates() {
            if case .phase(.ready) = update { break }
        }
        do {
            let value = try await body(connection, frames)
            await connection.stop()
            return value
        } catch {
            await connection.stop()
            throw error
        }
    }

    private func creates(_ frames: Frames) -> [JSONValue?] {
        frames.all.filter { $0["method"] == "session.create" }.map { $0["params"] }
    }

    @Test func aCwdIsSentAsAnExplicitPick() async throws {
        let handle = try await withGateway({ _ in .success(Self.created) }) { connection, frames in
            let handle = try await connection.createSession(cwd: "/work/app", profile: "scout")
            #expect(
                creates(frames) == [
                    [
                        "cols": 96, "source": "desktop",
                        "cwd": "/work/app", "cwd_explicit": true, "profile": "scout",
                    ]
                ])
            return handle
        }
        #expect(handle.runtimeID == "rt1")
    }

    /// No cwd, no provenance: the flag only qualifies a path.
    @Test func noCwdSendsNoFlag() async throws {
        try await withGateway({ _ in .success(Self.created) }) { connection, frames in
            _ = try await connection.createSession(profile: "scout", title: "Bot Chat")
            let params = try #require(creates(frames).first ?? nil)
            #expect(params["cwd"] == nil)
            #expect(params["cwd_explicit"] == nil)
        }
    }

    @Test func anOlderBackendGetsTheCwdWithoutTheFlag() async throws {
        let handle = try await withGateway({ params in
            params?["cwd_explicit"] == nil ? .success(Self.created) : .failure(Self.undeclaredFlag)
        }) { connection, frames in
            let handle = try await connection.createSession(cwd: "/work/app")
            let sent = creates(frames)
            #expect(sent.count == 2)
            #expect(sent.first??["cwd_explicit"] == true)
            #expect(sent.last??["cwd_explicit"] == nil)
            #expect(sent.last??["cwd"] == "/work/app")
            return handle
        }
        #expect(handle.runtimeID == "rt1")
    }

    /// A 4000 about some other key is a real client/backend skew: resending
    /// without the flag can't fix it, so it surfaces untouched.
    @Test func anotherUnknownKeyIsNotRetried() async throws {
        let other = RPCFailure(
            code: 4000, message: "invalid params for session.create: title: Extra inputs are not permitted")
        try await withGateway({ _ in .failure(other) }) { connection, frames in
            await #expect {
                _ = try await connection.createSession(cwd: "/work/app", title: "x")
            } throws: { error in
                (error as? HermesError)?.isUnknownParameter == true
            }
            #expect(creates(frames).count == 1)
        }
    }
}
