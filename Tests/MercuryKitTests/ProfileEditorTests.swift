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

    private static let appliedAll = #"{"ok": true, "applied": {"soul": true, "model": true, "skills": true, "toolsets": true, "mcp_servers": true}}"#

    @Test func onlyTheChangedSectionsAreSent() async throws {
        try await withGateway(.result(#"{"ok": true, "applied": {"soul": true}}"#)) { connection, frames in
            let outcome = try await connection.configureProfile(name: "scout", changes: ProfileChanges(soul: "# Scout"))
            #expect(frames.last?["method"] == "profiles.configure")
            #expect(frames.last?["params"] == ["name": "scout", "soul": "# Scout"])
            #expect(outcome.applied == [.soul: true])
            #expect(outcome.failedSections.isEmpty)
            #expect(!outcome.confirmationRequired)
        }
    }

    @Test func everySectionMapsToItsDeclaredKey() async throws {
        let changes = ProfileChanges(
            soul: "s", description: "d", model: .init(provider: "openai-codex", model: "gpt-5.6-sol"),
            confirmExpensiveModel: true, disabledSkills: ["pdf"], enabledToolsets: [], enabledMCPServers: ["linear"])
        try await withGateway(.result(Self.appliedAll)) { connection, frames in
            _ = try await connection.configureProfile(name: "scout", changes: changes)
            #expect(frames.last?["params"] == [
                "name": "scout", "soul": "s", "description": "d", "model": "gpt-5.6-sol",
                "provider": "openai-codex", "confirm_expensive_model": true, "disabled_skills": ["pdf"],
                "enabled_toolsets": [], "enabled_mcp_servers": ["linear"],
            ])
        }
    }

    /// An empty list is a choice (clear the pin, enable nothing), not an
    /// omission, so it must reach the wire.
    @Test func anEmptyListIsSent() async throws {
        try await withGateway(.result(#"{"ok": true, "applied": {"mcp_servers": true}}"#)) { connection, frames in
            _ = try await connection.configureProfile(name: "scout", changes: ProfileChanges(enabledMCPServers: []))
            #expect(frames.last?["params"] == ["name": "scout", "enabled_mcp_servers": []])
        }
    }

    @Test func aFailedSectionIsReported() async throws {
        try await withGateway(.result(#"{"ok": false, "applied": {"soul": true, "skills": false}}"#)) { connection, _ in
            let outcome = try await connection.configureProfile(
                name: "scout", changes: ProfileChanges(soul: "s", disabledSkills: []))
            #expect(outcome.failedSections == [.skills])
        }
    }

    /// A guarded (expensive or data-policy) model writes nothing until the
    /// client resends with `confirm_expensive_model`. The other sections
    /// were applied; the model section is pending, not failed.
    @Test func aGuardedModelAsksForConfirmation() async throws {
        let reply = #"{"ok": true, "applied": {"soul": true}, "confirm_required": true, "confirm_message": "This model costs $$$"}"#
        try await withGateway(.result(reply)) { connection, _ in
            let outcome = try await connection.configureProfile(
                name: "scout", changes: ProfileChanges(soul: "s", model: .init(provider: "p", model: "m")))
            #expect(outcome.confirmationRequired)
            #expect(outcome.confirmationMessage == "This model costs $$$")
            #expect(outcome.failedSections.isEmpty)
        }
    }

    @Test func aResultWithoutAppliedThrows() async throws {
        let caught = try await withGateway(.result(#"{"ok": true}"#)) { connection, _ -> Error? in
            do { _ = try await connection.configureProfile(name: "a", changes: ProfileChanges(soul: "s")); return nil }
            catch { return error }
        }
        guard case HermesError.malformedResponse = try #require(caught) else {
            Issue.record("expected malformedResponse, got \(String(describing: caught))")
            return
        }
    }

    private static let inventory = #"""
        {"model": "gpt-5.6-sol", "provider": "openai-codex",
         "providers": [
           {"slug": "openai-codex", "name": "OpenAI Codex", "models": ["gpt-5.6-sol", "gpt-5.6-mini"],
            "is_current": true, "authenticated": true, "unavailable_models": ["gpt-5.6-mini"]},
           {"slug": "anthropic", "name": "Anthropic", "models": [], "warning": "No API key"},
           {"name": "no slug, skipped"}]}
        """#

    /// Scoped to the bot's profile, so the picker shows what that profile
    /// can reach.
    @Test func theInventoryIsAskedForTheProfile() async throws {
        let inventory = try await withGateway(.result(Self.inventory)) { connection, frames in
            let inventory = try await connection.modelInventory(profile: "scout")
            #expect(frames.last?["method"] == "model.options")
            #expect(frames.last?["params"] == ["profile": "scout"])
            return inventory
        }
        #expect(inventory.currentModel == "gpt-5.6-sol")
        #expect(inventory.currentProvider == "openai-codex")
        #expect(inventory.providers.map(\.slug) == ["openai-codex", "anthropic"])
        #expect(inventory.providers[0] == .init(
            slug: "openai-codex", name: "OpenAI Codex", models: ["gpt-5.6-sol", "gpt-5.6-mini"], isCurrent: true,
            authenticated: true, warning: nil, unavailableModels: ["gpt-5.6-mini"]))
        #expect(inventory.providers[1].warning == "No API key")
        #expect(inventory.providers[1].authenticated == nil)
    }

    @Test func anInventoryWithoutProvidersThrows() async throws {
        let caught = try await withGateway(.result(#"{"model": "m"}"#)) { connection, _ -> Error? in
            do { _ = try await connection.modelInventory(profile: "a"); return nil } catch { return error }
        }
        guard case HermesError.malformedResponse = try #require(caught) else {
            Issue.record("expected malformedResponse, got \(String(describing: caught))")
            return
        }
    }
}
