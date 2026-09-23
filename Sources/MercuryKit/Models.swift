import Foundation

// MARK: - Server status

public struct ServerStatus: Sendable, Equatable {
    public var version: String?
    public var authRequired: Bool
    public var activeSessions: Int?
    /// `["cookie"]` and/or `["cookie","native_pkce"]` — native_pkce is the
    /// RFC 8252 browser sign-in Mercury can drive for OAuth-only servers.
    public var authFlows: [String]
    public var raw: JSONValue

    public var supportsNativePKCE: Bool { authFlows.contains("native_pkce") }

    public init(raw: JSONValue) {
        self.raw = raw
        self.version = raw["version"]?.stringValue
        self.authRequired = raw["auth_required"]?.truthy ?? false
        self.activeSessions = raw["active_sessions"]?.intValue
        self.authFlows = raw["auth_flows"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

// MARK: - Profiles

public struct ProfileInfo: Sendable, Equatable, Identifiable {
    public var name: String
    /// Human-facing profile name, falling back to its stable identifier.
    public var displayName: String
    public var path: String?
    public var isDefault: Bool
    public var model: String?
    public var provider: String?
    public var skillCount: Int?
    public var hasEnv: Bool

    public var id: String { name }

    public init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue, !name.isEmpty else { return nil }
        self.name = name
        let display = json["display_name"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
        self.displayName = display.isEmpty ? name : display
        self.path = json["path"]?.stringValue
        self.isDefault = json["is_default"]?.truthy ?? false
        self.model = json["model"]?.stringValue
        self.provider = json["provider"]?.stringValue
        self.skillCount = json["skill_count"]?.intValue
        self.hasEnv = json["has_env"]?.truthy ?? false
    }
}

// MARK: - Sessions

/// A row from the session lists (`/api/sessions`, `/api/profiles/sessions`,
/// `session.list`, `projects.tree` previews). The id here is always the
/// durable **stored** id (`YYYYMMDD_HHMMSS_<hex>`), never a runtime id.
public struct SessionSummary: Sendable, Equatable, Hashable, Identifiable {
    public var storedID: String
    public var title: String?
    public var cwd: String?
    public var gitRepoRoot: String?
    public var gitBranch: String?
    public var profile: String?
    public var pinned: Bool
    public var updatedAt: Date?
    public var messageCount: Int?

    public var id: String { storedID }

    public init?(json: JSONValue) {
        // Different surfaces name the id differently.
        guard
            let storedID = json["session_id"]?.stringValue
                ?? json["id"]?.stringValue
                ?? json["stored_session_id"]?.stringValue,
            !storedID.isEmpty
        else { return nil }
        self.storedID = storedID
        self.title = json["title"]?.stringValue
        self.cwd = json["cwd"]?.stringValue
        self.gitRepoRoot = json["git_repo_root"]?.stringValue
        self.gitBranch = json["git_branch"]?.stringValue
        self.profile = json["profile"]?.stringValue
        self.pinned = json["pinned"]?.truthy ?? false
        self.messageCount = json["message_count"]?.intValue
        // Timestamps arrive as epoch seconds or ISO strings depending on
        // surface; accept both.
        if let epoch = (json["updated_at"] ?? json["last_active"] ?? json["created_at"])?
            .doubleValue
        {
            self.updatedAt = Date(timeIntervalSince1970: epoch)
        } else if let iso = (json["updated_at"] ?? json["last_active"] ?? json["created_at"])?
            .stringValue
        {
            self.updatedAt = ISO8601DateFormatter().date(from: iso)
        }
    }
}

// MARK: - Projects

public struct ProjectInfo: Sendable, Equatable, Identifiable {
    /// Session rows of a hydrated `projects.project_sessions` node. Contract
    /// v5 nests them repo → lane → sessions (`repos[].groups[].sessions`);
    /// lanes are already newest-first, so flatten in server order.
    public static func hydratedSessions(in project: JSONValue) -> [SessionSummary] {
        var rows: [SessionSummary] = []
        for repo in project["repos"]?.arrayValue ?? [] {
            for lane in repo["groups"]?.arrayValue ?? [] {
                rows.append(
                    contentsOf: lane["sessions"]?.arrayValue?
                        .compactMap(SessionSummary.init(json:)) ?? [])
            }
        }
        return rows
    }

    /// The Home / no-workspace bucket id used by `projects.tree`.
    public static let noProjectID = "__no_project__"

    public var id: String
    public var name: String
    public var primaryPath: String?
    public var kind: String?
    public var previewSessions: [SessionSummary]
    public var sessionCount: Int?

    public var isHomeBucket: Bool { id == Self.noProjectID }

    public init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue ?? json["project_id"]?.stringValue else {
            return nil
        }
        self.id = id
        // The live backend speaks camelCase here (`label`, `previewSessions`,
        // `sessionCount`); keep the snake_case fallbacks for older builds.
        self.name = json["label"]?.stringValue
            ?? json["name"]?.stringValue
            ?? json["title"]?.stringValue
            ?? id
        self.primaryPath =
            json["path"]?.stringValue
            ?? json["primary_path"]?.stringValue
            ?? json["root"]?.stringValue
        self.kind = json["kind"]?.stringValue ?? json["type"]?.stringValue
        self.previewSessions =
            (json["previewSessions"] ?? json["sessions"] ?? json["preview_sessions"])?
            .arrayValue?
            .compactMap(SessionSummary.init(json:)) ?? []
        self.sessionCount = json["sessionCount"]?.intValue ?? json["session_count"]?.intValue
    }
}

public struct ProjectTree: Sendable, Equatable {
    public var projects: [ProjectInfo]
    public var activeID: String?
    /// Stored session ids already shown inside a project group — exclude
    /// these from the flat Recents list.
    public var scopedSessionIDs: Set<String>

    public init(json: JSONValue) {
        self.projects = json["projects"]?.arrayValue?.compactMap(ProjectInfo.init(json:)) ?? []
        self.activeID = json["active_id"]?.stringValue
        self.scopedSessionIDs = Set(
            json["scoped_session_ids"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }
}

// MARK: - Live session handle

/// Result of `session.create` / `session.resume`.
///
/// Two-ID model: `runtimeID` is what every subsequent RPC takes but is
/// recycled on backend restart; `storedID` is the durable DB id used to
/// re-resume after any reconnect.
public struct SessionHandle: Sendable, Equatable {
    public var runtimeID: String
    public var storedID: String?
    public var cwd: String?
    /// Display name of the project the session's cwd belongs to: the
    /// contract's `info.project.name` (falling back to its slug, then id), or
    /// the bare string an older backend sent.
    public var project: String?
    /// `info.project` as the contract types it (`ProjectRef` in
    /// `tui_gateway/contracts/common.py`); nil when absent, unusable, or a
    /// bare string from an older backend.
    public var projectRef: ProjectRef?
    public var profileName: String?
    public var model: String?
    public var title: String?
    public var desktopContract: Int?
    public var raw: JSONValue

    public init?(result: JSONValue) {
        guard let runtimeID = result["session_id"]?.stringValue, !runtimeID.isEmpty else {
            return nil
        }
        self.runtimeID = runtimeID
        self.storedID = result["stored_session_id"]?.stringValue
        let info = result["info"] ?? .null
        self.cwd = info["cwd"]?.stringValue
        let projectRef = ProjectRef(json: info["project"])
        self.projectRef = projectRef
        self.project = projectRef?.displayName
            ?? info["project"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        self.profileName = info["profile_name"]?.stringValue
        self.model = info["model"]?.stringValue
        self.title = info["title"]?.stringValue ?? result["title"]?.stringValue
        self.desktopContract = info["desktop_contract"]?.intValue
            ?? result["desktop_contract"]?.intValue
        self.raw = result
    }

    /// `open_requests` of a `session.resume` result (contract ≥ 7): the
    /// server requests still waiting for an answer, `[]` when absent. Nil
    /// when present but unreadable; then take the prompts from
    /// `activateSession`, which refuses such a payload outright. Takes
    /// priority over `pending_approval`/`pending_clarify` (see
    /// `LiveSessionSnapshot.openRequests`).
    public var openRequests: [ServerRequest]? { ServerRequest.openRequests(in: raw) }

    /// `{id, slug, name, primary_path?}` — the project `session.info`
    /// reports for the session's cwd (`_project_info_for_cwd`).
    public struct ProjectRef: Sendable, Equatable {
        public var id: String
        public var slug: String?
        public var name: String?
        public var primaryPath: String?

        public init(id: String, slug: String? = nil, name: String? = nil, primaryPath: String? = nil) {
            self.id = id
            self.slug = slug
            self.name = name
            self.primaryPath = primaryPath
        }

        /// nil unless `json` is an object with a non-empty string `id`.
        init?(json: JSONValue?) {
            guard let id = json?["id"]?.stringValue, !id.isEmpty else { return nil }
            self.init(
                id: id,
                slug: json?["slug"]?.stringValue,
                name: json?["name"]?.stringValue,
                primaryPath: json?["primary_path"]?.stringValue)
        }

        var displayName: String {
            [name, slug].compactMap { $0 }.first { !$0.isEmpty } ?? id
        }
    }
}

// MARK: - Usage

/// The gateway's usage dict (`_get_usage` in tui_gateway/server.py), carried
/// by `session.usage` ticks (~1/s while a turn runs) and authoritatively by
/// `message.complete.usage`. The `context*` gauge fields are present only
/// when the backend reports real current-window occupancy — absent means
/// unknown, and no gauge should be rendered.
public struct SessionUsage: Sendable, Equatable {
    public var model: String?
    public var totalTokens: Int?
    public var apiCalls: Int?
    public var contextUsed: Int?
    public var contextMax: Int?
    /// 0–100, already clamped server-side.
    public var contextPercent: Int?
    public var activeSubagents: Int?

    public init?(json: JSONValue) {
        guard case .object = json else { return nil }
        self.model = json["model"]?.stringValue
        self.totalTokens = json["total"]?.intValue
        self.apiCalls = json["calls"]?.intValue
        self.contextUsed = json["context_used"]?.intValue
        self.contextMax = json["context_max"]?.intValue
        self.contextPercent = json["context_percent"]?.intValue
        self.activeSubagents = json["active_subagents"]?.intValue
    }
}

// MARK: - Audio

public struct TranscriptionResult: Sendable, Equatable {
    public var transcript: String
    public var provider: String?

    /// Empty transcript = silence; a normal outcome, not an error.
    public var isSilence: Bool {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct SpokenClip: Sendable, Equatable {
    public var dataURL: String
    public var mimeType: String?
}

// MARK: - Transcript hydration

/// A persisted message row from `GET /api/sessions/{id}/messages` (the REST
/// transcript path) or a `session.resume` result's message list.
///
/// The durable row id is named `id` by REST (`SELECT *`) but `row_id` by the
/// gateway resume path — read both. Payload shapes vary by backend version,
/// so everything but `role` is optional and the raw JSON is retained.
public struct TranscriptMessage: Sendable, Equatable, Identifiable {
    public var rowID: Int?
    public var role: String
    public var text: String
    public var reasoning: String?
    public var toolName: String?
    public var toolCallID: String?
    /// Tool args/context preview for `role == "tool"` rows.
    public var context: String?
    /// `tool_calls` on an assistant row (OpenAI shape): the arguments each
    /// following `role == "tool"` row was invoked with.
    public var toolCalls: [ToolCallRef] = []
    public var displayKind: String?
    public var timestamp: Date?
    public var raw: JSONValue

    /// Stable identity for list rendering: the durable row id when the row
    /// has been persisted, else a content-derived fallback.
    public var id: String {
        if let rowID { return "row-\(rowID)" }
        let stamp = timestamp?.timeIntervalSince1970 ?? 0
        return "ephemeral-\(role)-\(stamp)-\(text.hashValue)"
    }

    public init?(json: JSONValue) {
        guard let role = json["role"]?.stringValue, !role.isEmpty else { return nil }
        self.role = role
        self.rowID = json["row_id"]?.intValue ?? json["id"]?.intValue
        // Content is usually a string; tolerate structured content by
        // falling back to a `text` field or empty (empty means "nothing",
        // never an error).
        // display_content (v0.20.5+) is the server's display projection of a
        // compaction-summary row; the physical `content` is kept for tooling.
        // Prefer it so Mercury renders what desktop renders.
        self.text = json["display_content"]?.stringValue ?? json["content"]?.stringValue
            ?? json["text"]?.stringValue
            ?? ""
        self.reasoning = json["reasoning"]?.stringValue
            ?? json["reasoning_content"]?.stringValue
        self.toolName = json["tool_name"]?.stringValue ?? json["name"]?.stringValue
        self.toolCallID = json["tool_call_id"]?.stringValue
        self.context = json["context"]?.stringValue
        self.toolCalls = json["tool_calls"]?.arrayValue?.compactMap(ToolCallRef.init(json:)) ?? []
        self.displayKind = json["display_kind"]?.stringValue
        if let epoch = json["timestamp"]?.doubleValue {
            self.timestamp = Date(timeIntervalSince1970: epoch)
        }
        self.raw = json
    }
}

/// One entry of an assistant row's `tool_calls`. Arguments are the raw
/// JSON-encoded string the model produced (occasionally an object on older
/// backends — re-encoded to text either way).
public struct ToolCallRef: Sendable, Equatable {
    public var id: String
    public var name: String?
    public var arguments: String

    public init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, !id.isEmpty else { return nil }
        self.id = id
        let function = json["function"]
        self.name = function?["name"]?.stringValue ?? json["name"]?.stringValue
        let rawArgs = function?["arguments"] ?? json["arguments"]
        switch rawArgs {
        case .string(let text)?: self.arguments = text
        case .none, .null?: self.arguments = ""
        case let value?: self.arguments = value.encodedString()
        }
    }
}

/// One page of `GET /api/sessions/{id}/messages`. The server pages this
/// endpoint unconditionally (≤500 rows); `order == "latest"` pages are still
/// returned in chronological order.
public struct TranscriptPage: Sendable, Equatable {
    public var sessionID: String?
    public var messages: [TranscriptMessage]
    public var limit: Int?
    public var offset: Int?
    public var returned: Int?

    public init(json: JSONValue) {
        self.sessionID = json["session_id"]?.stringValue
        self.messages = json["messages"]?.arrayValue?
            .compactMap(TranscriptMessage.init(json:)) ?? []
        let pagination = json["pagination"]
        self.limit = pagination?["limit"]?.intValue
        self.offset = pagination?["offset"]?.intValue
        self.returned = pagination?["returned"]?.intValue
    }
}

// MARK: - Model options

/// One row from `model.options` (model picker).
public struct ModelOption: Sendable, Equatable, Identifiable {
    public var value: String
    public var label: String
    public var provider: String?
    public var isCurrent: Bool

    public var id: String { value }

    public init?(json: JSONValue) {
        guard
            let value = json["value"]?.stringValue
                ?? json["model"]?.stringValue
                ?? json["id"]?.stringValue,
            !value.isEmpty
        else { return nil }
        self.value = value
        self.label = json["label"]?.stringValue ?? json["name"]?.stringValue ?? value
        self.provider = json["provider"]?.stringValue
        self.isCurrent = json["current"]?.truthy ?? json["selected"]?.truthy ?? false
    }
}
