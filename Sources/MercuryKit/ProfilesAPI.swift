import Foundation

/// Gateway support for Bot Mode (the desktop `hermes-bots` surface).
///
/// Bot Mode is built on the `profiles.*` WS RPC family, which landed after
/// desktop contract 6 — so its presence cannot be inferred from the contract
/// number alone. The reliable signal is the RPC door itself: `profiles.list`
/// answers on a supporting gateway and returns JSON-RPC -32601 (method not
/// found) on an older one.
public enum BotModeSupport {
    /// Maps a `profiles.list` probe failure to a support verdict.
    ///
    /// - `false`: the gateway answered "unknown method" — definitively
    ///   unsupported until the backend is updated.
    /// - `nil`: transport-shaped failure (timeout, dropped socket, other RPC
    ///   error). Unknown — don't cache a verdict; re-probe next connection.
    public static func verdict(from error: Error) -> Bool? {
        if case HermesError.rpcError(HermesError.RPCCode.methodNotFound, _, _) = error {
            return false
        }
        return nil
    }
}

// MARK: - Roster models

/// A compact session reference on a `profiles.list` row: the profile's
/// canonical "Bot Chat" (`canonical_session`) or its newest human-facing
/// conversation (`last_session`).
///
/// Deliberately separate from `SessionSummary`, as upstream separates them:
/// the desktop's `CanonicalSession` / `SessionPreview` (hermes-bots plugin
/// types) versus `SessionInfo`, and `ProfileCanonicalSession` /
/// `ProfileSessionPreview` versus `SessionListRow` in the wire contracts.
public struct BotSessionStub: Sendable, Equatable, Hashable {
    /// Durable registry row id — what the roster identifies the chat by.
    public var storedID: String
    /// Live tip of the compression lineage — what `session.resume` should
    /// take. Server-resolved on every listing; never cache it across opens.
    public var resolvedID: String?
    public var title: String?
    public var preview: String?
    /// Present on `profiles.list` rows only; upstream `session.list` rows
    /// (`SessionListRow`) carry no `last_active`, so a stub from
    /// `findCanonicalBotChat` leaves this nil.
    public var lastActive: Date?
    public var messageCount: Int?

    public init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, !id.isEmpty else { return nil }
        storedID = id
        resolvedID = json["resolved_id"]?.stringValue
        title = json["title"]?.stringValue
        preview = json["preview"]?.stringValue
        if let epoch = json["last_active"]?.doubleValue, epoch > 0 {
            lastActive = Date(timeIntervalSince1970: epoch)
        }
        messageCount = json["message_count"]?.intValue
    }
}

/// One row of the Bot Mode roster: a Hermes profile plus the presentation
/// metadata the desktop's hermes-bots plugin stores under
/// `ui_meta['hermes-bots']` (backend-synced, so Mercury paints the same
/// roster as every desktop connected to this gateway).
///
/// The `hermes-bots` key is upstream's, not Mercury's: hermes-agent reads it
/// in `tools/bot_mode_probe.py` (`_bots_meta`) and `hermes_cli/profiles.py`
/// (Bot Mode title), and the desktop plugin writes it in
/// `apps/desktop/src/plugins/hermes-bots/data.ts`. The wire shape is
/// `ProfileRow` in `tui_gateway/contracts/profiles_vault_complete_foreign_subagents.py`
/// (checked at upstream `9fe737aef2`).
///
/// Deliberately separate from `ProfileInfo` (REST `/api/profiles`), as the
/// desktop keeps the plugin's `RosterRow` apart from its `ProfileInfo`.
public struct BotSummary: Sendable, Equatable, Hashable, Identifiable {
    /// The profile's `ui_meta` key owned by the desktop hermes-bots plugin.
    static let uiMetaKey = "hermes-bots"

    public var name: String
    public var isDefault: Bool
    public var model: String?
    public var provider: String?
    public var profileDescription: String?
    public var displayName: String?
    public var skillCount: Int
    /// Server has an avatar image for this profile (`profiles.get_asset`).
    public var hasAvatar: Bool

    // ui_meta['hermes-bots'] — all optional; absent on profiles never touched
    // by Bot Mode.
    public var metaTitle: String?
    public var metaDescription: String?
    /// Geometric face vocabulary: circle / squircle / pill / triangle /
    /// hexagon / cloud / drop (plus render-only legacy values like
    /// `blobatar:*` and `sigil-N` that unknown clients draw as a circle).
    public var shape: String?
    /// CSS hex color (e.g. `#8b5cf6`); absent means hash one from the name.
    public var colorHex: String?
    public var hidden: Bool
    public var pinned: Bool

    public var lastSession: BotSessionStub?
    /// The profile's canonical "Bot Chat" — identity is the session NAME,
    /// resolved server-side on every listing (no client-side pointer).
    public var canonicalSession: BotSessionStub?
    /// Newest kanban/tool worker activity — a liveness signal for "working
    /// now" affordances; worker sessions never appear in session lists.
    public var workerLastActive: Date?

    /// The complete `ui_meta['hermes-bots']` object as stored. Writes to
    /// `ui_meta` merge KEY-WISE at the top level — sending the namespace
    /// replaces the whole object — so editors must read-modify-write from
    /// this, never send a partial patch.
    public var uiMetaRaw: JSONValue?
    /// The gateway's CAS revision for the `hermes-bots` ui_meta key
    /// (`ui_meta_revisions`). Pass it back on writes so a concurrent edit
    /// from another client conflicts instead of being clobbered. nil on
    /// gateways predating gateway-owned CAS.
    public var uiMetaRevision: Int?

    public var id: String { name }

    // JSONValue (uiMetaRaw) is Equatable but not Hashable; identity + the
    // CAS revision is plenty of hash discrimination for roster diffing.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(uiMetaRevision)
        hasher.combine(canonicalSession)
        hasher.combine(lastSession)
    }

    /// Display title, matching the desktop's precedence: Bot Mode title,
    /// then the profile's display name, then the raw profile name.
    public var title: String {
        for candidate in [metaTitle, displayName] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                return candidate
            }
        }
        return name
    }

    /// Latest-message excerpt for the roster row: the canonical chat's
    /// preview wins (it is the row's click target), else the newest
    /// conversation's.
    public var preview: String? {
        canonicalSession?.preview?.isEmpty == false
            ? canonicalSession?.preview : lastSession?.preview
    }

    /// Newest activity across the canonical chat, the latest conversation,
    /// and any live worker — what the roster orders by.
    public var lastActivity: Date? {
        [canonicalSession?.lastActive, lastSession?.lastActive, workerLastActive]
            .compactMap { $0 }
            .max()
    }

    public init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue, !name.isEmpty else { return nil }
        self.name = name
        isDefault = json["is_default"]?.truthy ?? false
        model = json["model"]?.stringValue
        provider = json["provider"]?.stringValue
        profileDescription = json["description"]?.stringValue
        displayName = json["display_name"]?.stringValue
        skillCount = json["skill_count"]?.intValue ?? 0
        hasAvatar = json["has_avatar"]?.truthy ?? false

        let meta = json["ui_meta"]?[Self.uiMetaKey]
        uiMetaRaw = meta?.objectValue != nil ? meta : nil
        uiMetaRevision = json["ui_meta_revisions"]?[Self.uiMetaKey]?.intValue
        metaTitle = meta?["title"]?.stringValue
        metaDescription = meta?["description"]?.stringValue
        shape = meta?["shape"]?.stringValue
        colorHex = meta?["color"]?.stringValue
        hidden = meta?["hidden"]?.truthy ?? false
        pinned = meta?["pinned"]?.truthy ?? false

        lastSession = json["last_session"].flatMap(BotSessionStub.init(json:))
        canonicalSession = json["canonical_session"].flatMap(BotSessionStub.init(json:))
        if let epoch = json["worker_session"]?["last_active"]?.doubleValue, epoch > 0 {
            workerLastActive = Date(timeIntervalSince1970: epoch)
        }
    }
}

/// A profile asset fetched via `profiles.get_asset` (today: `avatar`).
public struct ProfileAsset: Sendable, Equatable {
    public var mime: String
    public var data: Data

    /// Parses the RPC result. `found: false` is a normal absence → nil.
    /// A malformed data URL on a `found: true` result also returns nil —
    /// the roster's geometric fallback face covers both.
    public init?(json: JSONValue) {
        guard json["found"]?.truthy == true,
            let dataURL = json["data"]?.stringValue,
            let comma = dataURL.firstIndex(of: ","),
            dataURL.hasPrefix("data:"),
            let decoded = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
        else { return nil }
        data = decoded
        mime = json["mime"]?.stringValue
            ?? String(dataURL.dropFirst(5).prefix(while: { $0 != ";" && $0 != "," }))
    }
}

// MARK: - Routines (cron)

/// One cron job as `cron.manage` reports it. Deliberately its own type: the
/// wire keys the id as `job_id`, carries the schedule as a plain string, and
/// splits errors into separate fields (desktop parity).
///
/// Upstream's row is `CronJobRow` in `tui_gateway/contracts/tools_commands.py`
/// (open, `extra="allow"`). It declares `job_id`, `prompt_preview` and ISO
/// string timestamps; the `id`, `prompt` and epoch-second fallbacks below are
/// for older cron stores and are not part of that contract.
public struct CronJob: Sendable, Equatable, Identifiable {
    public var jobID: String
    /// Bot routines are namespaced `[bot:<name>] <routine>`.
    public var name: String
    public var schedule: String?
    public var prompt: String?
    public var enabled: Bool
    public var state: String?
    public var lastStatus: String?
    public var lastRunAt: Date?
    public var nextRunAt: Date?
    public var lastFireError: String?
    public var deliver: String?

    public var id: String { jobID }

    /// The routine's display name with any `[bot:<name>]` namespace stripped.
    /// The tag matches case-insensitively, like `belongsToBot` and the
    /// desktop's `BOT_TAG_RE`.
    public var displayName: String {
        guard name.lowercased().hasPrefix("[bot:"), let close = name.firstIndex(of: "]") else {
            return name
        }
        let stripped = name[name.index(after: close)...]
            .trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? name : stripped
    }

    /// True when the `[bot:<name>]` namespace matches `botName` — the safe
    /// client-side filter for gateways that ignore the profile scope.
    ///
    /// The namespace is upstream's: the desktop plugin names routines
    /// `` `[bot:${profile}] ${title}` `` and matches them with
    /// `BOT_TAG_RE = /^\[bot:([a-z0-9][a-z0-9_-]*)\]\s*/i`
    /// (`apps/desktop/src/plugins/hermes-bots/cron.tsx`), the `cron.manage`
    /// handler documents it as the fallback filter
    /// (`tui_gateway/methods_tools.py`), and
    /// `website/docs/user-guide/bot-mode.md` specifies it (upstream `9fe737aef2`).
    public func belongsToBot(named botName: String) -> Bool {
        name.lowercased().hasPrefix("[bot:\(botName.lowercased())]")
    }

    public init?(json: JSONValue) {
        guard let jobID = json["job_id"]?.stringValue ?? json["id"]?.stringValue,
            !jobID.isEmpty
        else { return nil }
        self.jobID = jobID
        name = json["name"]?.stringValue ?? jobID
        schedule = json["schedule"]?.stringValue
        prompt = json["prompt"]?.stringValue ?? json["prompt_preview"]?.stringValue
        enabled = json["enabled"]?.truthy ?? true
        state = json["state"]?.stringValue
        lastStatus = json["last_status"]?.stringValue
        lastFireError = json["last_fire_error"]?.stringValue
        deliver = json["deliver"]?.stringValue
        lastRunAt = Self.date(json["last_run_at"])
        nextRunAt = Self.date(json["next_run_at"])
    }

    /// Cron timestamps arrive as ISO strings (with or without fractional
    /// seconds) or epoch seconds, depending on the store's age.
    private static func date(_ value: JSONValue?) -> Date? {
        if let epoch = value?.doubleValue, epoch > 0 {
            return Date(timeIntervalSince1970: epoch)
        }
        guard let iso = value?.stringValue, !iso.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }
}

/// A `cron.manage list` result: the jobs plus whether the gateway honored the
/// profile scope (`scoped`). When it didn't (older gateway), callers must
/// apply the safe `[bot:<name>]` namespace filter themselves.
public struct CronJobList: Sendable, Equatable {
    public var jobs: [CronJob]
    public var scopedToProfile: Bool
}

/// `cron.manage` answered, but the cron tool reported a failure.
///
/// Upstream passes the tool's JSON through (`CronManageResult` in
/// `tui_gateway/contracts/tools_commands.py`), so a missing job or a broken
/// store arrives as a successful RPC result with `success: false` and an
/// `error` string (`tool_error` in `tools/cronjob_tools.py`), not as an RPC
/// error. Results without `success` (the field is optional) are not failures.
public struct CronManageError: Error, LocalizedError, Sendable, Equatable {
    /// The `cron.manage` action: `list`, `pause`, `resume` or `remove`.
    public var action: String
    /// The tool's `error` text, when it sent one.
    public var message: String?

    public init(action: String, message: String?) {
        self.action = action
        self.message = message
    }

    public var errorDescription: String? {
        let base =
            action == "list"
            ? "The routines couldn't be loaded" : "The routine couldn't be updated (\(action))"
        let detail = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return detail.isEmpty ? base + "." : base + ": " + detail
    }

    /// Throws when `result` is an explicit `success: false`.
    static func check(_ result: JSONValue, action: String) throws {
        if result["success"]?.boolValue == false {
            throw CronManageError(action: action, message: result["error"]?.stringValue)
        }
    }
}

// MARK: - Profile creation

/// Optional settings for `HermesConnection.createProfile`. A nil field is
/// left off the wire so the backend's own default applies; an explicit
/// `false` is sent. Mirrors `ProfilesCreateParams` in upstream's
/// `tui_gateway/contracts/profiles_vault_complete_foreign_subagents.py`.
public struct ProfileCreateOptions: Sendable, Equatable {
    public var description: String?
    /// Clone this existing profile. Omitted: a fresh profile with the
    /// bundled skills.
    public var cloneFrom: String?
    /// With `cloneFrom`, copy everything, not just the config.
    public var cloneAll: Bool?
    /// With `cloneFrom`, keep the source's bot tokens and allowlists. Off by
    /// default so two profiles never hold one messaging bot.
    public var cloneChannels: Bool?
    public var noSkills: Bool?
    /// Skip the `hermes-<name>` alias wrapper script.
    public var noAlias: Bool?
    /// Written to the profile's SOUL.md.
    public var soul: String?
    /// Pinned only together with `provider`.
    public var model: String?
    public var provider: String?
    /// Share the launch profile's auth store instead of copying it.
    public var shareAuth: Bool?
    /// Copy the launch profile's .env, auth and voice settings, and inherit
    /// its model when none is pinned. On by default: without it a new
    /// profile has no provider and can't answer.
    public var mirrorCredentials: Bool?

    public init(
        description: String? = nil, cloneFrom: String? = nil, cloneAll: Bool? = nil,
        cloneChannels: Bool? = nil, noSkills: Bool? = nil, noAlias: Bool? = nil,
        soul: String? = nil, model: String? = nil, provider: String? = nil,
        shareAuth: Bool? = nil, mirrorCredentials: Bool? = nil
    ) {
        self.description = description
        self.cloneFrom = cloneFrom
        self.cloneAll = cloneAll
        self.cloneChannels = cloneChannels
        self.noSkills = noSkills
        self.noAlias = noAlias
        self.soul = soul
        self.model = model
        self.provider = provider
        self.shareAuth = shareAuth
        self.mirrorCredentials = mirrorCredentials
    }

    /// The params object: `name` plus exactly the set fields.
    func params(name: String) -> JSONValue {
        var params: [String: JSONValue] = ["name": .string(name)]
        let strings: [(String, String?)] = [
            ("description", description), ("clone_from", cloneFrom), ("soul", soul),
            ("model", model), ("provider", provider),
        ]
        for (key, value) in strings {
            if let value { params[key] = .string(value) }
        }
        let flags: [(String, Bool?)] = [
            ("clone_all", cloneAll), ("clone_channels", cloneChannels), ("no_skills", noSkills),
            ("no_alias", noAlias), ("share_auth", shareAuth), ("mirror_credentials", mirrorCredentials),
        ]
        for (key, value) in flags {
            if let value { params[key] = .bool(value) }
        }
        return .object(params)
    }
}

/// A `profiles.create` result (`ProfilesCreateResult`). The profile is then
/// listed by `profiles.list` under `name`.
public struct CreatedProfile: Sendable, Equatable {
    public var name: String
    public var path: String
    public var soulWritten: Bool
    public var modelSet: Bool
    public var mirrored: Mirrored

    /// What was copied from the launch profile (`ProfileMirrored`).
    public struct Mirrored: Sendable, Equatable {
        public var env: Bool
        public var auth: AuthMirror
        public var modelInherited: Bool
        public var voice: Bool

        public init(env: Bool, auth: AuthMirror, modelInherited: Bool, voice: Bool) {
            self.env = env
            self.auth = auth
            self.modelInherited = modelInherited
            self.voice = voice
        }
    }

    /// `mirrored.auth`: `false`, `true`, or `"shared"` with `shareAuth`.
    public enum AuthMirror: Sendable, Equatable {
        case none
        case copied
        case shared
    }

    /// Fail-closed on what the contract requires (`name`, `path`,
    /// `mirrored`) and on an `auth` value it doesn't allow.
    public init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue, !name.isEmpty,
            let path = json["path"]?.stringValue,
            let mirrored = json["mirrored"], mirrored.objectValue != nil
        else { return nil }
        let auth: AuthMirror
        switch mirrored["auth"] {
        case nil, .bool(false)?: auth = .none
        case .bool(true)?: auth = .copied
        case .string("shared")?: auth = .shared
        default: return nil
        }
        self.name = name
        self.path = path
        self.soulWritten = json["soul_written"]?.boolValue ?? false
        self.modelSet = json["model_set"]?.boolValue ?? false
        self.mirrored = Mirrored(
            env: mirrored["env"]?.boolValue ?? false, auth: auth,
            modelInherited: mirrored["model_inherited"]?.boolValue ?? false,
            voice: mirrored["voice"]?.boolValue ?? false)
    }
}

// MARK: - Bot meta writes

/// Outcome of a `profiles.configure` ui_meta write.
public enum BotMetaWriteOutcome: Sendable, Equatable {
    /// The gateway confirmed the write (`applied.ui_meta == true`).
    case persisted
    /// Per-key CAS rejected the write: another client changed the meta since
    /// this roster row was read. Reload and re-apply.
    case conflict
    /// The gateway answered but did not confirm (`applied.ui_meta` false or
    /// missing) — treat as failed rather than assuming success.
    case failed
}

// MARK: - Canonical Bot Chat

/// The canonical Bot Chat is a forever-chat, identified by its title.
///
/// Composer rules (which slash commands a canonical chat turns into
/// compression) are app UI and live in the consumer, which extends this
/// enum; the kit holds only the upstream-defined identity.
public enum BotChatPolicy {
    /// The canonical registry title. (profile, "Bot Chat") IS the bot's
    /// forever-chat identity — the gateway resolves by this exact name, so
    /// renaming a canonical chat severs the relationship.
    ///
    /// Hardcoded upstream as `BOT_CHAT_TITLE` in `tools/bot_mode_probe.py`,
    /// gating the Bot Mode prompt section (`agent/system_prompt.py`) and DM
    /// tool (`agent/turn_context.py`), cron `bot-chat` delivery
    /// (`cron/scheduler_delivery.py`, `-c "Bot Chat"`) and the archived-row
    /// resurrection in `session.list`'s title lookup
    /// (`tui_gateway/methods_session.py`) (upstream `9fe737aef2`).
    public static let canonicalTitle = "Bot Chat"

    /// Whether a listed/looked-up session row is a canonical Bot Chat.
    /// `profiles.list`'s `canonical_session` reports the durable lineage
    /// root's title as `root_title`; `session.list` rows (including its
    /// exact-title lookup) carry only `title`, which on the title lookup is
    /// the root row's title (desktop parity).
    public static func isCanonicalRow(rootTitle: String?, title: String?) -> Bool {
        let root = rootTitle?.trimmingCharacters(in: .whitespaces) ?? ""
        if !root.isEmpty { return root == canonicalTitle }
        return title?.trimmingCharacters(in: .whitespaces) == canonicalTitle
    }
}

// MARK: - RPCs

extension HermesConnection {
    /// Probe whether this gateway speaks the `profiles.*` RPC family.
    ///
    /// Uses `profiles.list` with `include_sessions: false` — the cheap form
    /// that skips the per-profile state.db walks (last-session previews,
    /// canonical-chat resolution), so the probe stays fast even on gateways
    /// with many profiles.
    public func probeBotModeSupport(timeout: TimeInterval = 20) async -> Bool? {
        do {
            _ = try await request(
                "profiles.list",
                params: .object(["include_sessions": .bool(false)]),
                timeout: timeout)
            return true
        } catch {
            return BotModeSupport.verdict(from: error)
        }
    }

    /// The Bot Mode roster: every profile with its `ui_meta['hermes-bots']`
    /// presentation, latest-conversation preview, and server-resolved
    /// canonical Bot Chat. The session walk makes this the expensive form —
    /// callers should cache and refresh, not poll.
    public func listBots(timeout: TimeInterval = 60) async throws -> [BotSummary] {
        let result = try await request(
            "profiles.list",
            params: .object(["include_sessions": .bool(true)]),
            timeout: timeout)
        return result["profiles"]?.arrayValue?.compactMap(BotSummary.init(json:)) ?? []
    }

    /// Authoritative per-open canonical Bot Chat lookup: `session.list`'s
    /// exact-title fast path on the bot's profile. The gateway resolves the
    /// compression lineage to the live tip (`resolved_id`), resurrects
    /// accidentally-archived canonical rows, and answers `sessions: []` for
    /// confirmed absence. Hidden rows resolve (canonical chats are born
    /// hidden on the desktop). Throws on transport/RPC failure — callers
    /// must fail CLOSED there: a failed registry lookup never reads as
    /// "no Bot Chat exists", because creating on that misreading is how a
    /// forever-chat forks.
    public func findCanonicalBotChat(
        profile: String, timeout: TimeInterval = 30
    ) async throws -> BotSessionStub? {
        let result = try await request(
            "session.list",
            params: .object([
                "profile": .string(profile),
                "title": .string(BotChatPolicy.canonicalTitle),
                "include_hidden": .bool(true),
                "limit": .number(200),
            ]),
            timeout: timeout)
        let rows = result["sessions"]?.arrayValue ?? []
        return rows.lazy
            .filter {
                BotChatPolicy.isCanonicalRow(
                    rootTitle: $0["root_title"]?.stringValue,
                    title: $0["title"]?.stringValue)
            }
            .compactMap(BotSessionStub.init(json:))
            .first
    }

    /// Real context compression for a live session — the RPC behind the
    /// desktop's `/compact`. (`prompt.submit` treats slash text as an
    /// ordinary message, so this is the only way to actually compress.)
    /// Returns the result's `status`: "compressed", "pending" (still running
    /// server-side; the transcript refreshes when it lands), or a host-owned
    /// value like "aborted".
    public func compressSession(
        sessionID: String, timeout: TimeInterval = 300
    ) async throws -> String {
        let result = try await request(
            "session.compress",
            params: .object(["session_id": .string(sessionID)]),
            timeout: timeout)
        return result["status"]?.stringValue ?? "compressed"
    }

    /// A profile's avatar image, or nil when the profile has none
    /// (`found: false`).
    public func profileAvatar(
        name: String, timeout: TimeInterval = 30
    ) async throws -> ProfileAsset? {
        let result = try await request(
            "profiles.get_asset",
            params: .object(["name": .string(name), "asset": .string("avatar")]),
            timeout: timeout)
        return ProfileAsset(json: result)
    }

    /// Store (or clear) a profile's avatar. `dataURL` must be a PNG/JPEG/WebP
    /// data URL ≤ 2MB — downscale on-device first.
    public func setProfileAvatar(
        name: String, dataURL: String?, timeout: TimeInterval = 60
    ) async throws {
        var params: [String: JSONValue] = [
            "name": .string(name), "asset": .string("avatar"),
        ]
        if let dataURL {
            params["data"] = .string(dataURL)
        } else {
            params["clear"] = .bool(true)
        }
        _ = try await request("profiles.set_asset", params: .object(params), timeout: timeout)
    }

    /// Write a bot's COMPLETE `ui_meta['hermes-bots']` object. The gateway
    /// merges ui_meta key-wise at the top level, so `meta` replaces the whole
    /// namespace — build it by modifying the roster row's `uiMetaRaw`, never
    /// from scratch. `expectedRevision` (the row's `uiMetaRevision`) arms the
    /// per-key CAS so a concurrent desktop edit conflicts instead of being
    /// clobbered; pass nil only when the row reported no revision map.
    public func configureBotMeta(
        name: String, meta: JSONValue, expectedRevision: Int?,
        timeout: TimeInterval = 30
    ) async throws -> BotMetaWriteOutcome {
        var params: [String: JSONValue] = [
            "name": .string(name),
            "ui_meta": .object([BotSummary.uiMetaKey: meta]),
        ]
        if let expectedRevision {
            params["ui_meta_expected_revisions"] = .object([
                BotSummary.uiMetaKey: .number(Double(expectedRevision))
            ])
        }
        let result = try await request(
            "profiles.configure", params: .object(params), timeout: timeout)
        return Self.metaWriteOutcome(from: result)
    }

    /// Maps a `profiles.configure` result onto the write outcome — split out
    /// so the CAS interpretation is unit-testable.
    ///
    /// Upstream (`_configure_ui_meta` in `tui_gateway/methods_profiles.py`)
    /// sets `applied.ui_meta` false and fills `applied.ui_meta_conflicts` when
    /// any expected revision mismatches; the whole write is then rejected.
    public static func metaWriteOutcome(from result: JSONValue) -> BotMetaWriteOutcome {
        let applied = result["applied"]
        if applied?["ui_meta_conflicts"]?.objectValue?.isEmpty == false {
            return .conflict
        }
        return applied?["ui_meta"]?.truthy == true ? .persisted : .failed
    }

    /// Create a profile: the WS twin of `POST /api/profiles`, and a new bot
    /// in Bot Mode (give it a look afterwards with `configureBotMeta`).
    /// Throws `rpcError` 4062 (`RPCCode.profileCreateRejected`) when the
    /// name is invalid or taken, or `cloneFrom` doesn't exist, with the
    /// backend's explanation as the message.
    public func createProfile(
        name: String, options: ProfileCreateOptions = ProfileCreateOptions(),
        timeout: TimeInterval = 60
    ) async throws -> CreatedProfile {
        let result = try await request(
            "profiles.create", params: options.params(name: name), timeout: timeout)
        guard let profile = CreatedProfile(json: result) else {
            throw HermesError.malformedResponse("profiles.create returned no name, path or mirrored")
        }
        return profile
    }

    // MARK: Routines

    /// A profile's cron jobs (bot routines are named `[bot:<name>] …`).
    /// Includes paused jobs — excluding them reads as deletion in a toggle
    /// UI. `scopedToProfile` is false on gateways that ignored the profile
    /// param; apply `CronJob.belongsToBot` there. Throws `CronManageError`
    /// when the cron tool reports `success: false`, so a failed read never
    /// looks like an empty store.
    public func listCronJobs(
        profile: String, timeout: TimeInterval = 30
    ) async throws -> CronJobList {
        let result = try await request(
            "cron.manage",
            params: .object([
                "action": .string("list"),
                "include_disabled": .bool(true),
                "profile": .string(profile),
            ]),
            timeout: timeout)
        try CronManageError.check(result, action: "list")
        return CronJobList(
            jobs: result["jobs"]?.arrayValue?.compactMap(CronJob.init(json:)) ?? [],
            scopedToProfile: result["scoped"]?.stringValue == profile)
    }

    /// Pause or resume one cron job in the profile's store. Throws
    /// `CronManageError` when the cron tool reports `success: false` (for
    /// example, an unknown job id).
    public func setCronJobEnabled(
        jobID: String, enabled: Bool, profile: String, timeout: TimeInterval = 30
    ) async throws {
        let action = enabled ? "resume" : "pause"
        let result = try await request(
            "cron.manage",
            params: .object([
                "action": .string(action),
                "name": .string(jobID),
                "profile": .string(profile),
            ]),
            timeout: timeout)
        try CronManageError.check(result, action: action)
    }

    /// Permanently remove one cron job from the profile's store. Throws
    /// `CronManageError` when the cron tool reports `success: false`.
    public func removeCronJob(
        jobID: String, profile: String, timeout: TimeInterval = 30
    ) async throws {
        let result = try await request(
            "cron.manage",
            params: .object([
                "action": .string("remove"),
                "name": .string(jobID),
                "profile": .string(profile),
            ]),
            timeout: timeout)
        try CronManageError.check(result, action: "remove")
    }
}
