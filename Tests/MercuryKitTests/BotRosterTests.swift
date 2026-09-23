import Foundation
import Testing

@testable import MercuryKit

// Moved from Chat (angel12/mercurychat #78/#79, f94bfaf). The
// `isCompactCommand` cases stay in Chat: that composer rule is app UI and
// lives in ChatCore as an extension of `BotChatPolicy`.

private func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

@Suite("BotSummary parsing")
struct BotSummaryTests {
    /// A realistic `profiles.list` row from a v0.21.x gateway with Bot Mode
    /// metadata, a canonical chat, and a live worker.
    static let fullRow = """
        {
          "name": "researcher", "path": "/home/u/.hermes/profiles/researcher",
          "is_default": false, "model": "gpt-5.6-sol", "provider": "openai-codex",
          "description": "Deep-dive research agent", "display_name": "Researcher",
          "skill_count": 12, "has_avatar": true,
          "ui_meta": {
            "hermes-bots": {
              "title": "Radar", "description": "Finds things out",
              "shape": "hexagon", "color": "#8b5cf6",
              "hidden": false, "pinned": true, "created": 1756000000000
            }
          },
          "ui_meta_revisions": {"hermes-bots": 7},
          "last_session": {
            "id": "20260907_101010_aa11", "title": "Group: ops",
            "preview": "On it.", "started_at": 1757000000,
            "last_active": 1757260000, "message_count": 41
          },
          "canonical_session": {
            "id": "20260830_090000_bb22", "resolved_id": "20260906_120000_cc33",
            "root_title": "Bot Chat", "title": "Bot Chat",
            "preview": "Here's the summary you asked for.",
            "started_at": 1756500000, "last_active": 1757250000, "message_count": 230
          },
          "worker_session": {
            "id": "20260908_070000_dd44", "source": "kanban",
            "title": "worker", "last_active": 1757310000
          }
        }
        """

    @Test func parsesFullRow() throws {
        let bot = try #require(BotSummary(json: try json(Self.fullRow)))
        #expect(bot.name == "researcher")
        #expect(bot.id == "researcher")
        #expect(bot.title == "Radar")  // ui_meta title beats display_name
        #expect(bot.displayName == "Researcher")
        #expect(bot.profileDescription == "Deep-dive research agent")
        #expect(bot.metaDescription == "Finds things out")
        #expect(bot.model == "gpt-5.6-sol")
        #expect(bot.provider == "openai-codex")
        #expect(bot.shape == "hexagon")
        #expect(bot.colorHex == "#8b5cf6")
        #expect(bot.pinned)
        #expect(!bot.hidden)
        #expect(bot.hasAvatar)
        #expect(bot.skillCount == 12)

        let canonical = try #require(bot.canonicalSession)
        #expect(canonical.storedID == "20260830_090000_bb22")
        #expect(canonical.resolvedID == "20260906_120000_cc33")
        #expect(canonical.messageCount == 230)
        #expect(canonical.lastActive == Date(timeIntervalSince1970: 1_757_250_000))
        let last = try #require(bot.lastSession)
        #expect(last.resolvedID == nil)
        #expect(last.title == "Group: ops")
        #expect(bot.workerLastActive == Date(timeIntervalSince1970: 1_757_310_000))

        // The canonical chat's preview is the row's click target, so it
        // wins over the newer last_session preview.
        #expect(bot.preview == "Here's the summary you asked for.")
        // Activity = max(canonical, last, worker) — the worker is newest.
        #expect(bot.lastActivity == Date(timeIntervalSince1970: 1_757_310_000))
    }

    /// Editors read-modify-write the whole namespace, so the raw object must
    /// survive untouched (including keys the kit doesn't model), and the CAS
    /// revision must be carried for the write.
    @Test func keepsTheRawNamespaceAndItsRevision() throws {
        let bot = try #require(BotSummary(json: try json(Self.fullRow)))
        #expect(bot.uiMetaRevision == 7)
        #expect(bot.uiMetaRaw?["created"] == 1_756_000_000_000)
        #expect(bot.uiMetaRaw?.objectValue?.count == 7)
    }

    @Test func parsesBareProfileWithoutBotMeta() throws {
        // A profile Bot Mode never touched: no ui_meta, no sessions walked
        // (include_sessions=false shape).
        let bot = try #require(
            BotSummary(
                json: try json(
                    """
                    {"name": "default", "path": "/h", "is_default": true,
                     "model": null, "provider": null, "description": "",
                     "display_name": "", "skill_count": 0, "ui_meta_revisions": {}}
                    """)))
        #expect(bot.isDefault)
        #expect(bot.title == "default")  // empty display_name falls through
        #expect(!bot.hidden && !bot.pinned && !bot.hasAvatar)
        #expect(bot.canonicalSession == nil)
        #expect(bot.preview == nil)
        #expect(bot.lastActivity == nil)
        #expect(bot.uiMetaRaw == nil)
        #expect(bot.uiMetaRevision == nil)
    }

    @Test func whitespaceTitlesFallThroughAndEmptyCanonicalPreviewYields() throws {
        let bot = try #require(
            BotSummary(
                json: try json(
                    """
                    {"name": "ops", "display_name": "  ", "ui_meta": {"hermes-bots": {"title": " "}},
                     "canonical_session": {"id": "c", "resolved_id": "c", "preview": ""},
                     "last_session": {"id": "l", "preview": "latest"}}
                    """)))
        #expect(bot.title == "ops")
        #expect(bot.preview == "latest")
    }

    @Test func nonObjectNamespaceIsIgnored() throws {
        let bot = try #require(
            BotSummary(json: try json(#"{"name": "x", "ui_meta": {"hermes-bots": "junk"}}"#)))
        #expect(bot.uiMetaRaw == nil)
        #expect(bot.metaTitle == nil)
    }

    @Test func rowWithoutNameIsRejected() throws {
        #expect(BotSummary(json: try json(#"{"is_default": false}"#)) == nil)
        #expect(BotSummary(json: try json(#"{"name": ""}"#)) == nil)
    }

    @Test func sessionStubWithoutIDIsRejected() throws {
        #expect(BotSessionStub(json: try json(#"{"title": "Bot Chat"}"#)) == nil)
        #expect(BotSessionStub(json: try json(#"{"id": "", "title": "Bot Chat"}"#)) == nil)
        // A zero epoch means "unknown", not 1970.
        #expect(BotSessionStub(json: try json(#"{"id": "a", "last_active": 0}"#))?.lastActive == nil)
    }
}

@Suite("ProfileAsset parsing")
struct ProfileAssetTests {
    @Test func decodesDataURL() throws {
        let payload = Data("PNGBYTES".utf8).base64EncodedString()
        let asset = try #require(
            ProfileAsset(
                json: try json(
                    """
                    {"found": true, "mime": "image/png", "size": 8,
                     "data": "data:image/png;base64,\(payload)"}
                    """)))
        #expect(asset.mime == "image/png")
        #expect(asset.data == Data("PNGBYTES".utf8))
    }

    @Test func mimeFallsBackToTheDataURL() throws {
        let payload = Data("W".utf8).base64EncodedString()
        let asset = try #require(
            ProfileAsset(json: try json(#"{"found": true, "data": "data:image/webp;base64,\#(payload)"}"#)))
        #expect(asset.mime == "image/webp")
    }

    @Test func absentAssetIsNil() throws {
        #expect(ProfileAsset(json: try json(#"{"found": false}"#)) == nil)
    }

    @Test func malformedDataURLIsNil() throws {
        #expect(
            ProfileAsset(json: try json(#"{"found": true, "data": "not-a-data-url"}"#)) == nil)
        #expect(
            ProfileAsset(json: try json(#"{"found": true, "data": "data:image/png;base64,***"}"#)) == nil)
    }
}

@Suite("CronJob parsing")
struct CronJobTests {
    @Test func parsesFullRow() throws {
        let job = try #require(
            CronJob(
                json: try json(
                    """
                    {"job_id": "job-1", "name": "[bot:researcher] Morning digest",
                     "schedule": "0 7 * * *", "prompt": "Summarize my inbox",
                     "enabled": false, "state": "paused", "last_status": "ok",
                     "last_fire_error": "boom",
                     "last_run_at": "2026-09-21T07:00:02.150Z",
                     "next_run_at": "2026-09-23T07:00:00Z",
                     "deliver": "bot-chat"}
                    """)))
        #expect(job.jobID == "job-1")
        #expect(job.id == "job-1")
        #expect(job.displayName == "Morning digest")
        #expect(job.belongsToBot(named: "researcher"))
        #expect(!job.belongsToBot(named: "other"))
        #expect(!job.enabled)
        #expect(job.schedule == "0 7 * * *")
        #expect(job.prompt == "Summarize my inbox")
        #expect(job.state == "paused")
        #expect(job.lastStatus == "ok")
        #expect(job.lastFireError == "boom")
        #expect(job.deliver == "bot-chat")
        // Fractional and whole-second ISO timestamps both parse.
        let lastRun = try #require(job.lastRunAt?.timeIntervalSince1970)
        #expect(abs(lastRun - 1_789_974_002.150) < 0.001)
        #expect(job.nextRunAt == Date(timeIntervalSince1970: 1_790_146_800))
    }

    @Test func unnamespacedJobKeepsItsName() throws {
        let job = try #require(
            CronJob(json: try json(#"{"job_id": "j2", "name": "nightly backup"}"#)))
        #expect(job.displayName == "nightly backup")
        #expect(!job.belongsToBot(named: "nightly"))
        #expect(job.enabled)  // default on
    }

    /// Older stores key the id as `id`, and the gateway's row carries
    /// `prompt_preview` rather than `prompt` (`CronJobRow`).
    @Test func fieldFallbacks() throws {
        let job = try #require(
            CronJob(json: try json(#"{"id": "legacy", "prompt_preview": "Check the build"}"#)))
        #expect(job.jobID == "legacy")
        #expect(job.name == "legacy")  // a missing name falls back to the id
        #expect(job.prompt == "Check the build")
        #expect(job.schedule == nil)
        #expect(job.lastRunAt == nil && job.nextRunAt == nil)

        let both = try #require(
            CronJob(json: try json(#"{"job_id": "new", "id": "old", "prompt": "p", "prompt_preview": "pp"}"#)))
        #expect(both.jobID == "new")
        #expect(both.prompt == "p")
    }

    @Test func rowWithoutAnIDIsRejected() throws {
        #expect(CronJob(json: try json(#"{"name": "orphan"}"#)) == nil)
        #expect(CronJob(json: try json(#"{"job_id": ""}"#)) == nil)
    }

    @Test func dateFallbacks() throws {
        let epoch = try #require(
            CronJob(json: try json(#"{"job_id": "e", "last_run_at": 1757000000, "next_run_at": 0}"#)))
        #expect(epoch.lastRunAt == Date(timeIntervalSince1970: 1_757_000_000))
        #expect(epoch.nextRunAt == nil)  // zero is "never", not 1970

        let junk = try #require(
            CronJob(json: try json(#"{"job_id": "j", "last_run_at": "yesterday", "next_run_at": ""}"#)))
        #expect(junk.lastRunAt == nil)
        #expect(junk.nextRunAt == nil)

        let offset = try #require(
            CronJob(json: try json(#"{"job_id": "o", "next_run_at": "2026-09-23T09:00:00+02:00"}"#)))
        #expect(offset.nextRunAt == Date(timeIntervalSince1970: 1_790_146_800))
    }

    @Test func botNamespaceMatchingIsCaseInsensitiveAndExact() throws {
        let job = try #require(
            CronJob(json: try json(#"{"job_id": "a", "name": "[bot:Researcher]Digest"}"#)))
        #expect(job.belongsToBot(named: "researcher"))
        #expect(job.displayName == "Digest")
        #expect(!job.belongsToBot(named: "research"))  // prefix of the name is not the name

        let bare = try #require(CronJob(json: try json(#"{"job_id": "b", "name": "[bot:ops]  "}"#)))
        #expect(bare.displayName == "[bot:ops]  ")  // nothing after the tag: keep the raw name
    }
}

@Suite("Bot meta write outcomes")
struct BotMetaWriteOutcomeTests {
    @Test func confirmedWriteIsPersisted() throws {
        let result = try json(#"{"ok": true, "applied": {"ui_meta": true, "ui_meta_revisions": {"hermes-bots": 8}}}"#)
        #expect(HermesConnection.metaWriteOutcome(from: result) == .persisted)
    }

    @Test func casConflictIsSurfaced() throws {
        // The gateway rejects the WHOLE write on any per-key mismatch and
        // reports the conflicting keys + live revisions.
        let result = try json(
            """
            {"ok": false, "applied": {"ui_meta": false,
             "ui_meta_conflicts": {"hermes-bots": {"expected": 3, "actual": 5}},
             "ui_meta_revisions": {"hermes-bots": 5}}}
            """)
        #expect(HermesConnection.metaWriteOutcome(from: result) == .conflict)
    }

    @Test func unconfirmedWriteIsFailed() throws {
        // Older gateways answer without `applied` at all; a false success
        // here previously masked dropped writes (desktop's serverOutcome).
        #expect(HermesConnection.metaWriteOutcome(from: try json(#"{"ok": true}"#)) == .failed)
        #expect(
            HermesConnection.metaWriteOutcome(
                from: try json(#"{"applied": {"ui_meta": false}}"#)) == .failed)
        // An empty conflict map is not a conflict.
        #expect(
            HermesConnection.metaWriteOutcome(
                from: try json(#"{"applied": {"ui_meta": false, "ui_meta_conflicts": {}}}"#)) == .failed)
    }
}

@Suite("BotChatPolicy")
struct BotChatPolicyTests {
    /// hermes-agent `tools/bot_mode_probe.py` `BOT_CHAT_TITLE`.
    @Test func canonicalTitleMatchesUpstream() {
        #expect(BotChatPolicy.canonicalTitle == "Bot Chat")
    }

    @Test func canonicalRowRecognition() {
        // Exact-lookup gateways report the lineage root's title.
        #expect(BotChatPolicy.isCanonicalRow(rootTitle: "Bot Chat", title: "anything"))
        // Windowed listings carry only the plain title.
        #expect(BotChatPolicy.isCanonicalRow(rootTitle: nil, title: "Bot Chat"))
        #expect(BotChatPolicy.isCanonicalRow(rootTitle: "", title: " Bot Chat "))
        // A non-canonical root title is disqualifying even when the tip's
        // display title matches.
        #expect(!BotChatPolicy.isCanonicalRow(rootTitle: "Notes", title: "Bot Chat"))
        #expect(!BotChatPolicy.isCanonicalRow(rootTitle: nil, title: "Bot Chats"))
        #expect(!BotChatPolicy.isCanonicalRow(rootTitle: nil, title: "bot chat"))
        #expect(!BotChatPolicy.isCanonicalRow(rootTitle: nil, title: nil))
    }
}
