import Foundation
import Testing

@testable import MercuryKit

/// `profiles.create` (#27 Phase 3, the create-bot quick path). Since
/// contract 7 upstream rejects an undeclared param key with 4000, so the
/// exact params are the contract; every shape here passes
/// `validate_params` at upstream `16fe260aab` (see VERIFICATION.md).
@Suite("Profile create", .timeLimit(.minutes(1)))
struct ProfileCreateTests {
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

    private static let created = #"""
        {"ok": true, "name": "scout", "path": "/home/u/.hermes/profiles/scout",
         "soul_written": false, "model_set": false,
         "mirrored": {"env": true, "auth": true, "model_inherited": true, "voice": false}}
        """#

    // MARK: Params

    /// The quick path sends only the name: every backend default applies,
    /// including `mirror_credentials` (on), so the new bot has a provider.
    @Test func aBareCreateSendsOnlyTheName() async throws {
        let profile = try await withGateway(.result(Self.created)) { connection, frames in
            let profile = try await connection.createProfile(name: "scout")
            #expect(frames.last?["method"] == "profiles.create")
            #expect(frames.last?["params"] == ["name": "scout"])
            return profile
        }
        #expect(profile.name == "scout")
        #expect(profile.path == "/home/u/.hermes/profiles/scout")
    }

    @Test func everyOptionMapsToItsDeclaredKey() async throws {
        let options = ProfileCreateOptions(
            description: "Finds things out", cloneFrom: "default", cloneAll: false,
            cloneChannels: false, noSkills: true, noAlias: true, soul: "You are Scout.",
            model: "gpt-5.6-sol", provider: "openai-codex", shareAuth: true,
            mirrorCredentials: false)
        try await withGateway(.result(Self.created)) { connection, frames in
            _ = try await connection.createProfile(name: "scout", options: options)
            #expect(
                frames.last?["params"]
                    == [
                        "name": "scout", "description": "Finds things out", "clone_from": "default",
                        "clone_all": false, "clone_channels": false, "no_skills": true, "no_alias": true,
                        "soul": "You are Scout.", "model": "gpt-5.6-sol", "provider": "openai-codex",
                        "share_auth": true, "mirror_credentials": false,
                    ])
        }
    }

    /// An explicit false is a choice, not an omission: it must reach the
    /// wire, or the backend default (true for `mirror_credentials`) wins.
    @Test func anExplicitFalseIsSent() async throws {
        try await withGateway(.result(Self.created)) { connection, frames in
            _ = try await connection.createProfile(
                name: "scout", options: ProfileCreateOptions(mirrorCredentials: false))
            #expect(frames.last?["params"] == ["name": "scout", "mirror_credentials": false])
        }
    }

    // MARK: Result

    @Test(arguments: [
        ("true", CreatedProfile.AuthMirror.copied),
        ("false", CreatedProfile.AuthMirror.none),
        (#""shared""#, CreatedProfile.AuthMirror.shared),
    ])
    func authMirrorDecodes(wire: String, expected: CreatedProfile.AuthMirror) throws {
        let json = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(
                #"{"ok": true, "name": "a", "path": "/p", "soul_written": true, "model_set": true, "mirrored": {"env": false, "auth": \#(wire), "model_inherited": false, "voice": true}}"#
                    .utf8))
        let profile = try #require(CreatedProfile(json: json))
        #expect(profile.mirrored.auth == expected)
        #expect(profile.soulWritten)
        #expect(profile.modelSet)
        #expect(profile.mirrored.voice)
        #expect(!profile.mirrored.env)
    }

    @Test func theFullResultDecodes() async throws {
        let profile = try await withGateway(.result(Self.created)) { connection, _ in
            try await connection.createProfile(name: "scout")
        }
        #expect(!profile.soulWritten)
        #expect(!profile.modelSet)
        #expect(profile.mirrored == .init(env: true, auth: .copied, modelInherited: true, voice: false))
    }

    /// A result missing what the contract requires, or with an `auth` the
    /// contract doesn't allow, is refused rather than guessed at.
    @Test(arguments: [
        #"{"ok": true, "path": "/p", "mirrored": {}}"#,
        #"{"ok": true, "name": "a", "mirrored": {}}"#,
        #"{"ok": true, "name": "a", "path": "/p"}"#,
        #"{"ok": true, "name": "a", "path": "/p", "mirrored": {"auth": "copied"}}"#,
    ])
    func aMalformedResultThrows(result: String) async throws {
        let caught = try await withGateway(.result(result)) { connection, _ -> Error? in
            do {
                _ = try await connection.createProfile(name: "a")
                return nil
            } catch {
                return error
            }
        }
        guard case HermesError.malformedResponse = try #require(caught) else {
            Issue.record("expected malformedResponse, got \(String(describing: caught))")
            return
        }
    }

    // MARK: Errors

    /// 4062: an invalid or taken name, or a missing clone source. The
    /// backend's message says which, so it reaches the caller intact.
    @Test func aRejectedNameSurfacesTheBackendsMessage() async throws {
        let caught = try await withGateway(.error(4062, "Profile 'scout' already exists")) {
            connection, _ -> Error? in
            do {
                _ = try await connection.createProfile(name: "scout")
                return nil
            } catch {
                return error
            }
        }
        guard case HermesError.rpcError(let code, let message, _) = try #require(caught) else {
            Issue.record("expected rpcError, got \(String(describing: caught))")
            return
        }
        #expect(code == HermesError.RPCCode.profileCreateRejected)
        #expect(message == "Profile 'scout' already exists")
    }

    @Test func profileCreateCodesArePublic() {
        #expect(HermesError.RPCCode.profileNameRequired == 4061)
        #expect(HermesError.RPCCode.profileCreateRejected == 4062)
    }
}
