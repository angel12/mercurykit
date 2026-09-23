import Foundation
import Testing

@testable import MercuryKit

/// Request capture for Chat's Bot Mode RPCs (angel12/mercurychat #78/#79).
/// Since contract 7 upstream rejects an undeclared param key with 4000, so
/// the exact method names and params are the contract. Every shape below was
/// validated with `tui_gateway.contracts.registry.validate_params` at
/// upstream `9fe737aef2` (see VERIFICATION.md).
@Suite("Bot Mode RPCs", .timeLimit(.minutes(1)))
struct BotModeRPCTests {
    private final class Frames: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [(text: String, frame: JSONValue)] = []
        func append(_ text: String, _ frame: JSONValue) { lock.withLock { values.append((text, frame)) } }
        var last: JSONValue? { lock.withLock { values.last?.frame } }
        var lastText: String? { lock.withLock { values.last?.text } }
        var count: Int { lock.withLock { values.count } }
    }

    private enum Reply {
        case result(String)
        case error(Int, String)
    }

    private func server(_ frames: Frames, reply: Reply) async throws -> LocalGatewayServer {
        try await LocalGatewayServer.start(onText: { text, server in
            guard let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
                let id = frame["id"]?.intValue
            else { return }
            frames.append(text, frame)
            switch reply {
            case .result(let result): server.respond(id: id, result: result)
            case .error(let code, let message): server.respondError(id: id, code: code, message: message)
            }
        })
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

    /// Runs `body` against a gateway that answers every request with `reply`.
    private func withGateway<T>(
        _ reply: Reply, _ body: (HermesConnection, Frames) async throws -> T
    ) async throws -> T {
        let frames = Frames()
        let server = try await server(frames, reply: reply)
        defer { server.stop() }
        let connection = try await connected(server.port)
        do {
            let value = try await body(connection, frames)
            await connection.stop()
            return value
        } catch {
            await connection.stop()
            throw error
        }
    }

    // MARK: profiles.list

    @Test func listBotsAsksForSessions() async throws {
        let bots = try await withGateway(
            .result(
                #"{"profiles":[{"name":"researcher","path":"/p","ui_meta_revisions":{"hermes-bots":2}},{"path":"/nameless"}],"bot_mode_protocol":true}"#
            )
        ) { connection, frames in
            let bots = try await connection.listBots()
            #expect(frames.last?["method"] == "profiles.list")
            #expect(frames.last?["params"] == ["include_sessions": true])
            return bots
        }
        #expect(bots.map(\.name) == ["researcher"])  // nameless rows are dropped
        #expect(bots.first?.uiMetaRevision == 2)
    }

    // MARK: session.list (canonical Bot Chat)

    @Test func findCanonicalBotChatUsesTheExactTitleLookupOnTheProfile() async throws {
        let stub = try await withGateway(
            .result(
                #"{"sessions":[{"id":"20260830_090000_bb22","resolved_id":"20260906_120000_cc33","title":"Bot Chat","preview":"hi","started_at":1,"message_count":3,"source":"desktop"}]}"#
            )
        ) { connection, frames in
            let stub = try await connection.findCanonicalBotChat(profile: "researcher")
            #expect(frames.last?["method"] == "session.list")
            #expect(
                frames.last?["params"]
                    == ["profile": "researcher", "title": "Bot Chat", "include_hidden": true, "limit": 200])
            return stub
        }
        let found = try #require(stub)
        #expect(found.storedID == "20260830_090000_bb22")
        #expect(found.resolvedID == "20260906_120000_cc33")
        #expect(found.messageCount == 3)
    }

    @Test func findCanonicalBotChatReportsConfirmedAbsenceAsNil() async throws {
        let stub = try await withGateway(.result(#"{"sessions":[]}"#)) { connection, _ in
            try await connection.findCanonicalBotChat(profile: "researcher")
        }
        #expect(stub == nil)
    }

    @Test func findCanonicalBotChatSkipsRowsThatAreNotCanonical() async throws {
        let stub = try await withGateway(
            .result(#"{"sessions":[{"id":"a","title":"Bot Chats"},{"id":"b","root_title":"Notes","title":"Bot Chat"}]}"#)
        ) { connection, _ in
            try await connection.findCanonicalBotChat(profile: "researcher")
        }
        #expect(stub == nil)
    }

    /// A failed lookup must never read as "no Bot Chat exists": creating on
    /// that misreading is how a forever-chat forks.
    @Test(arguments: [
        (HermesError.RPCCode.methodNotFound, "unknown method"),
        (5006, "state.db is locked"),
    ])
    func findCanonicalBotChatThrowsOnAnRPCError(code: Int, message: String) async throws {
        let caught = try await withGateway(.error(code, message)) { connection, _ -> Error? in
            do {
                _ = try await connection.findCanonicalBotChat(profile: "researcher")
                return nil
            } catch {
                return error
            }
        }
        let error = try #require(caught)
        guard case HermesError.rpcError(let got, _, _) = error else {
            Issue.record("expected rpcError, got \(error)")
            return
        }
        #expect(got == code)
    }

    @Test func findCanonicalBotChatThrowsWhenTheSocketDrops() async throws {
        let frames = Frames()
        let server = try await LocalGatewayServer.start(onText: { text, server in
            if let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) {
                frames.append(text, frame)
            }
            server.close(code: 1011)
        })
        defer { server.stop() }
        let connection = try await connected(server.port)
        await #expect(throws: (any Error).self) {
            _ = try await connection.findCanonicalBotChat(profile: "researcher", timeout: 5)
        }
        await connection.stop()
    }

    // MARK: session.compress

    @Test(arguments: [
        (#"{"status":"pending"}"#, "pending"),
        (#"{"status":"compressed","removed":12}"#, "compressed"),
        (#"{"removed":12}"#, "compressed"),  // older gateways omit status
    ])
    func compressSessionSendsOnlyTheRuntimeID(result: String, status: String) async throws {
        let got = try await withGateway(.result(result)) { connection, frames in
            let got = try await connection.compressSession(sessionID: "rt-42")
            #expect(frames.last?["method"] == "session.compress")
            #expect(frames.last?["params"] == ["session_id": "rt-42"])
            return got
        }
        #expect(got == status)
    }

    // MARK: profiles.get_asset / set_asset

    @Test func profileAvatarRequestsTheAvatarAsset() async throws {
        let payload = Data("PNG".utf8).base64EncodedString()
        let asset = try await withGateway(
            .result(#"{"found":true,"mime":"image/png","size":3,"data":"data:image/png;base64,\#(payload)"}"#)
        ) { connection, frames in
            let asset = try await connection.profileAvatar(name: "researcher")
            #expect(frames.last?["method"] == "profiles.get_asset")
            #expect(frames.last?["params"] == ["name": "researcher", "asset": "avatar"])
            return asset
        }
        #expect(asset?.data == Data("PNG".utf8))
    }

    @Test func profileAvatarAbsenceIsNil() async throws {
        let asset = try await withGateway(.result(#"{"found":false}"#)) { connection, _ in
            try await connection.profileAvatar(name: "researcher")
        }
        #expect(asset == nil)
    }

    @Test func setProfileAvatarSendsData() async throws {
        try await withGateway(.result(#"{"ok":true,"asset":"avatar","size":3}"#)) { connection, frames in
            try await connection.setProfileAvatar(name: "researcher", dataURL: "data:image/png;base64,UE5H")
            #expect(frames.last?["method"] == "profiles.set_asset")
            #expect(
                frames.last?["params"]
                    == ["name": "researcher", "asset": "avatar", "data": "data:image/png;base64,UE5H"])
        }
    }

    @Test func setProfileAvatarNilClears() async throws {
        try await withGateway(.result(#"{"ok":true,"asset":"avatar","size":0,"removed":1}"#)) { connection, frames in
            try await connection.setProfileAvatar(name: "researcher", dataURL: nil)
            #expect(frames.last?["params"] == ["name": "researcher", "asset": "avatar", "clear": true])
        }
    }

    // MARK: profiles.configure (ui_meta CAS)

    @Test func configureBotMetaArmsTheCASWithAnIntegerRevision() async throws {
        let meta: JSONValue = ["title": "Radar", "pinned": true]
        let outcome = try await withGateway(
            .result(#"{"ok":true,"applied":{"ui_meta":true,"ui_meta_revisions":{"hermes-bots":8}}}"#)
        ) { connection, frames in
            let outcome = try await connection.configureBotMeta(
                name: "researcher", meta: meta, expectedRevision: 7)
            #expect(frames.last?["method"] == "profiles.configure")
            #expect(
                frames.last?["params"]
                    == [
                        "name": "researcher",
                        "ui_meta": ["hermes-bots": meta],
                        "ui_meta_expected_revisions": ["hermes-bots": 7],
                    ])
            // Upstream's CAS rejects a non-int revision (`isinstance(wanted,
            // int)`), so 7.0 on the wire would always conflict.
            let text = try #require(frames.lastText)
            #expect(text.contains(#""ui_meta_expected_revisions":{"hermes-bots":7}"#))
            return outcome
        }
        #expect(outcome == .persisted)
    }

    @Test func configureBotMetaWithoutARevisionOmitsTheCASKey() async throws {
        try await withGateway(.result(#"{"ok":true,"applied":{"ui_meta":true}}"#)) { connection, frames in
            _ = try await connection.configureBotMeta(
                name: "researcher", meta: ["hidden": true], expectedRevision: nil)
            #expect(frames.last?["params"] == ["name": "researcher", "ui_meta": ["hermes-bots": ["hidden": true]]])
            #expect(frames.last?["params"]?["ui_meta_expected_revisions"] == nil)
        }
    }

    @Test func configureBotMetaReportsAConflict() async throws {
        let outcome = try await withGateway(
            .result(
                #"{"ok":false,"applied":{"ui_meta":false,"ui_meta_conflicts":{"hermes-bots":{"expected":7,"actual":9}},"ui_meta_revisions":{"hermes-bots":9}}}"#
            )
        ) { connection, _ in
            try await connection.configureBotMeta(name: "researcher", meta: [:], expectedRevision: 7)
        }
        #expect(outcome == .conflict)
    }

    // MARK: cron.manage

    @Test(arguments: [
        (#"{"success":true,"count":1,"scoped":"researcher","jobs":[{"job_id":"j1","name":"[bot:researcher] Digest"}]}"#, true),
        (#"{"success":true,"count":1,"jobs":[{"job_id":"j1","name":"[bot:researcher] Digest"}]}"#, false),
        (#"{"success":true,"count":1,"scoped":"other","jobs":[{"job_id":"j1","name":"[bot:researcher] Digest"}]}"#, false),
    ])
    func listCronJobsIncludesPausedJobsInTheProfileStore(result: String, scoped: Bool) async throws {
        let list = try await withGateway(.result(result)) { connection, frames in
            let list = try await connection.listCronJobs(profile: "researcher")
            #expect(frames.last?["method"] == "cron.manage")
            #expect(
                frames.last?["params"]
                    == ["action": "list", "include_disabled": true, "profile": "researcher"])
            return list
        }
        #expect(list.jobs.map(\.jobID) == ["j1"])
        #expect(list.scopedToProfile == scoped)
    }

    @Test(arguments: [(true, "resume"), (false, "pause")])
    func setCronJobEnabledPausesOrResumesByJobID(enabled: Bool, action: String) async throws {
        try await withGateway(.result(#"{"success":true,"job":{"job_id":"j1"}}"#)) { connection, frames in
            try await connection.setCronJobEnabled(jobID: "j1", enabled: enabled, profile: "researcher")
            #expect(frames.last?["method"] == "cron.manage")
            #expect(frames.last?["params"] == ["action": .string(action), "name": "j1", "profile": "researcher"])
        }
    }

    @Test func removeCronJobRemovesByJobID() async throws {
        try await withGateway(.result(#"{"success":true,"removed_job":{"id":"j1"}}"#)) { connection, frames in
            try await connection.removeCronJob(jobID: "j1", profile: "researcher")
            #expect(frames.last?["method"] == "cron.manage")
            #expect(frames.last?["params"] == ["action": "remove", "name": "j1", "profile": "researcher"])
        }
    }
}
