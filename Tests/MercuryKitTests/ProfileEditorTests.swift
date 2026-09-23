import Foundation
import Testing

@testable import MercuryKit

/// The advanced profile editor (#27 Phase 3): `profiles.describe`, the
/// editor sections of `profiles.configure`, and a profile-scoped
/// `model.options`. Every params shape here passes upstream
/// `validate_params` at `520fead094` (see VERIFICATION.md).
@Suite("Profile editor", .timeLimit(.minutes(1)))
struct ProfileEditorTests {
    private final class Frames: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [JSONValue] = []
        func append(_ frame: JSONValue) { lock.withLock { values.append(frame) } }
        var last: JSONValue? { lock.withLock { values.last } }
    }

    private enum Reply {
        case result(String)
        case error(Int, String)
    }

    private func withGateway<T>(
        _ reply: Reply, _ body: (HermesConnection, Frames) async throws -> T
    ) async throws -> T {
        let frames = Frames()
        let server = try await LocalGatewayServer.start(onText: { text, server in
            guard let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
                let id = frame["id"]?.intValue
            else { return }
            frames.append(frame)
            switch reply {
            case .result(let result): server.respond(id: id, result: result)
            case .error(let code, let message): server.respondError(id: id, code: code, message: message)
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

    private static let described = #"""
        {"name": "scout", "description": "Researcher", "soul": "# Scout\n",
         "model": {"provider": "openai-codex", "default": "gpt-5.6-sol"},
         "skills": [{"name": "arxiv", "enabled": true}, {"name": "pdf", "enabled": false}],
         "toolsets": [{"name": "web", "label": "Web", "description": "Search", "tool_count": 3, "enabled": true},
                      {"name": "terminal", "enabled": false}],
         "toolsets_pinned": true,
         "mcp_servers": [{"name": "linear", "enabled": false, "transport": "http"}]}
        """#

    @Test func describeSendsOnlyTheName() async throws {
        try await withGateway(.result(Self.described)) { connection, frames in
            _ = try await connection.describeProfile(name: "scout")
            #expect(frames.last?["method"] == "profiles.describe")
            #expect(frames.last?["params"] == ["name": "scout"])
        }
    }

    @Test func theSnapshotDecodes() async throws {
        let profile = try await withGateway(.result(Self.described)) { connection, _ in
            try await connection.describeProfile(name: "scout")
        }
        #expect(profile.name == "scout")
        #expect(profile.description == "Researcher")
        #expect(profile.soul == "# Scout\n")
        #expect(profile.model == .init(provider: "openai-codex", model: "gpt-5.6-sol"))
        #expect(profile.skills == [.init(name: "arxiv", enabled: true), .init(name: "pdf", enabled: false)])
        #expect(profile.toolsets == [
            .init(name: "web", label: "Web", description: "Search", toolCount: 3, enabled: true),
            .init(name: "terminal", label: "", description: "", toolCount: 0, enabled: false),
        ])
        #expect(profile.toolsetsPinned)
        #expect(profile.mcpServers == [.init(name: "linear", enabled: false, transport: "http")])
    }

    /// The contract's defaults: a bare snapshot is an empty editor, and an
    /// unpinned model is empty strings (read as no pin).
    @Test func contractDefaultsApply() throws {
        let json = try JSONDecoder().decode(
            JSONValue.self, from: Data(#"{"name": "a", "model": {}, "skills": [{"name": "s"}], "mcp_servers": [{"name": "m"}]}"#.utf8))
        let profile = try #require(ProfileDescription(json: json))
        #expect(profile.model == nil)
        #expect(profile.skills == [.init(name: "s", enabled: true)])
        #expect(profile.mcpServers == [.init(name: "m", enabled: true, transport: "stdio")])
        #expect(!profile.toolsetsPinned)
        #expect(profile.soul.isEmpty)
    }

    @Test(arguments: [#"{"model": {}}"#, #"{"name": "a"}"#])
    func aSnapshotMissingRequiredFieldsThrows(result: String) async throws {
        let caught = try await withGateway(.result(result)) { connection, _ -> Error? in
            do { _ = try await connection.describeProfile(name: "a"); return nil } catch { return error }
        }
        guard case HermesError.malformedResponse = try #require(caught) else {
            Issue.record("expected malformedResponse, got \(String(describing: caught))")
            return
        }
    }

    @Test func anUnknownProfileSurfacesItsCode() async throws {
        let caught = try await withGateway(.error(4064, "profile 'ghost' not found")) { connection, _ -> Error? in
            do { _ = try await connection.describeProfile(name: "ghost"); return nil } catch { return error }
        }
        guard case HermesError.rpcError(let code, let message, _) = try #require(caught) else {
            Issue.record("expected rpcError, got \(String(describing: caught))")
            return
        }
        #expect(code == HermesError.RPCCode.profileUnavailable)
        #expect(message == "profile 'ghost' not found")
    }
}
