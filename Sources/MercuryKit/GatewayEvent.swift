import Foundation

/// A server-push event from `/api/ws`: a JSON-RPC notification with
/// `method == "event"` whose real name is `params.type`.
public struct GatewayEvent: Sendable, Equatable {
    public var type: String
    public var sessionID: String?
    public var payload: JSONValue
    /// Per-session monotonic sequence stamp (v0.20.5+; nil from older
    /// backends). Sibling of `type` in the frame's params, NOT in `payload`.
    /// Basis of the reconnect replay contract (`session.events.since`).
    public var seq: Int?

    public init(type: String, sessionID: String?, payload: JSONValue, seq: Int? = nil) {
        self.type = type
        self.sessionID = sessionID
        self.payload = payload
        self.seq = seq
    }

    /// Decode one event-frame `params` object ({type, session_id, seq,
    /// payload}) — the shape both the live socket and the
    /// `session.events.since` replay batches carry.
    public init?(eventParams params: JSONValue) {
        guard let type = params["type"]?.stringValue else { return nil }
        self.init(
            type: type,
            sessionID: params["session_id"]?.stringValue,
            payload: params["payload"] ?? .null,
            seq: params["seq"]?.intValue)
    }

    /// Well-known event names (open set — unknown types must be tolerated).
    public enum Kind {
        public static let gatewayReady = "gateway.ready"
        public static let messageStart = "message.start"
        public static let messageDelta = "message.delta"
        public static let messageInterim = "message.interim"
        public static let messageComplete = "message.complete"
        public static let thinkingDelta = "thinking.delta"
        public static let reasoningDelta = "reasoning.delta"
        public static let toolGenerating = "tool.generating"
        public static let toolStart = "tool.start"
        public static let toolProgress = "tool.progress"
        public static let toolComplete = "tool.complete"
        public static let statusUpdate = "status.update"
        public static let approvalRequest = "approval.request"
        public static let clarifyRequest = "clarify.request"
        public static let clarifyExpire = "clarify.expire"
        public static let sudoRequest = "sudo.request"
        public static let sudoExpire = "sudo.expire"
        public static let secretRequest = "secret.request"
        public static let secretExpire = "secret.expire"
        public static let mcpSetupRequest = "mcp.setup.request"
        public static let mcpSetupExpire = "mcp.setup.expire"
        public static let sessionUsage = "session.usage"
        public static let sessionInfo = "session.info"
        public static let sessionTitle = "session.title"
        public static let sessionResumeProgress = "session.resume_progress"
        public static let sessionReclaimed = "session.reclaimed"
        public static let sessionsChanged = "sessions.changed"
        public static let notificationShow = "notification.show"
        public static let notificationClear = "notification.clear"
        public static let error = "error"
        /// Nested agent activity arrives as `subagent.*` (open sub-set).
        public static let subagentPrefix = "subagent."
    }
}

/// Result of `session.events.since` — the missed-event replay a reconnecting
/// client requests with its last observed seq.
///
/// A batch is applied *instead of* a full refresh, so everything it does not
/// carry is taken to have never happened. Decoding is therefore fail-closed:
/// the gateway answers every call with `events`, `latest_seq`, `truncated`,
/// `count` and `epoch` (`tui_gateway/methods_session.py`), and a response that
/// leaves any of the gap questions unanswered is reported as unusable rather
/// than read as a reassuring default. `isLossless(under:forSession:after:)` is
/// that verdict.
public struct EventReplayBatch: Sendable, Equatable {
    public var events: [GatewayEvent]
    public var latestSeq: Int?
    /// The requested watermark predates the ring buffer — a gap exists, so
    /// the caller must fall back to a full state refresh instead of replaying.
    /// Also true when the response never answered the question: an absent or
    /// unreadable field is not a "no gap".
    public var truncated: Bool
    /// Process identity of the seq numbering; compare against the
    /// `replay_epoch` learned at `gateway.ready` — a mismatch means the
    /// backend restarted and every watermark is stale.
    public var epoch: String?
    /// The response could not be read as a whole batch: `events` absent or
    /// not an array, an entry that is not a decodable event frame, an
    /// unreadable `truncated`, or a `count` disagreeing with the entries
    /// decoded. The frames in hand are then a subset of what was sent — a
    /// gap, not a replay.
    public var malformed: Bool

    public init(result: JSONValue) {
        let entries = result["events"]?.arrayValue
        // Replay needs structural evidence; the ordinary live decoder remains permissive.
        let decoded =
            entries?.compactMap { entry -> GatewayEvent? in
                guard let type = entry["type"]?.stringValue,
                    !type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    entry["payload"]?.objectValue != nil
                else { return nil }
                return GatewayEvent(eventParams: entry)
            } ?? []
        self.events = decoded
        self.latestSeq = result["latest_seq"]?.intValue
        let gap = result["truncated"]?.boolValue
        self.truncated = gap ?? true
        self.epoch = result["epoch"]?.stringValue
        // `count` is the gateway's own tally of what it put in `events`
        // (`len(frames)`), so it is the one field that can contradict an
        // entry dropped on the way in. A backend that omits it says nothing,
        // and the per-entry check already covers the drop.
        let countField = result["count"]
        self.malformed =
            gap == nil
            || entries == nil
            || entries?.count != decoded.count
            || (countField != nil && countField?.intValue != decoded.count)
    }

    /// Whether these frames are provably every event after `watermark`, for
    /// `sessionID`, under the epoch `expected` — the identity and numbering
    /// the watermark was taken with. False is not "an error occurred": it is
    /// "this answer is not evidence that nothing was missed", and the caller
    /// must refresh instead of replaying.
    ///
    /// Required evidence, based on `tui_gateway/event_replay.py` and
    /// `methods_session.py`. The backend reads frames and metadata separately;
    /// requiring complete coverage may conservatively reject a racing answer:
    ///
    /// - The epoch is present and equal. It has been echoed here since the
    ///   same gateway commit that first advertised `replay_epoch` at
    ///   `gateway.ready`, so a caller holding an epoch is by construction
    ///   talking to a gateway that returns one; an older backend leaves the
    ///   caller with no epoch at all and never reaches this check.
    /// - `latest_seq` is the session's current highest stamp, read straight
    ///   after the frames, so it is never below the watermark the client
    ///   reached — *unless* the ring was evicted, which drops the counter
    ///   with it (`_replay_next_seq.pop`) and restarts the session at 1 while
    ///   `truncated` reads False because the ring is simply gone. A
    ///   `latest_seq` below the watermark (0 for an evicted session), or one
    ///   that is absent or unreadable, is the only trace that renumbering
    ///   leaves, so it is refused.
    /// - Every replayed frame is stamped with an integer `seq` and carries
    ///   the session id it was requested for (`_stamp_event` only records
    ///   frames with a session id, and `events_since` reads that session's
    ///   ring), the ring ascends by exactly one, and `truncated == false`
    ///   means the first frame returned is `watermark + 1`. So the frames
    ///   must be the contiguous run `watermark + 1 … latest_seq`: a hole, a
    ///   repeat, a reordering, an unstamped or fractional seq, or a frame
    ///   from another session invalidates the batch as a whole rather than
    ///   the frame alone — the caller applies all of it or none of it.
    ///
    /// Numeric validation operates on JSONValue's Double representation, not
    /// lexical JSON numbers: rounded fractions and large counters cannot be
    /// recovered here. Int(exactly:) checks the represented value only.
    ///
    /// Residual, and a backend limitation rather than something a client can
    /// see: an evicted session whose new counter catches up to `watermark`
    /// can answer exactly like a real continuation. Only
    /// a per-session epoch (or an `is_truncated` that reported a missing
    /// ring) could distinguish it.
    public func isLossless(
        under expected: String, forSession sessionID: String, after watermark: Int
    ) -> Bool {
        guard !truncated, !malformed, epoch == expected else { return false }
        // Seqs start at 1, so a watermark below 0 was never stamped by this
        // contract, and `latest` must still be at or past where we got to.
        guard watermark >= 0, let latest = latestSeq, latest >= watermark else { return false }
        var previous = watermark
        for event in events {
            guard event.sessionID == sessionID, let seq = event.seq else { return false }
            // `previous + 1` unchecked would trap on a watermark at Int.max.
            let (next, overflowed) = previous.addingReportingOverflow(1)
            guard !overflowed, seq == next else { return false }
            previous = next
        }
        // Separate backend reads can race with stamping. An absent tail is
        // still unproven coverage, even if it might arrive on the live socket.
        return previous == latest
    }
}

// MARK: - Typed payloads

/// `approval.request` — session-keyed: at most one is SHOWN per session;
/// answer with `approval.respond {session_id, choice, request_id?}`. The
/// server queues approvals and resolves the oldest when no `request_id` is
/// given, so pass one when the payload carries it — a queue of several must
/// not resolve a different entry than the card the user saw.
public struct ApprovalRequest: Sendable, Equatable, Identifiable {
    /// Decode the matching pending-prompt snapshot with the full live vocabulary.
    public init?(payload: JSONValue, sessionID: String?) {
        self.init(event: GatewayEvent(type: GatewayEvent.Kind.approvalRequest, sessionID: sessionID, payload: payload))
    }

    public var sessionID: String
    /// Present on current backends (approvals are queued server-side);
    /// absent on older ones, where session-keyed respond is exact.
    public var requestID: String?
    public var command: String?
    public var description: String?
    /// Server-derived subset of once/session/always/deny.
    public var choices: [String]

    public var id: String { requestID ?? sessionID }

    public init?(event: GatewayEvent) {
        guard event.type == GatewayEvent.Kind.approvalRequest,
            let sessionID = event.sessionID
        else { return nil }
        self.sessionID = sessionID
        self.requestID = event.payload["request_id"]?.stringValue
        self.command = event.payload["command"]?.stringValue
        self.description = event.payload["description"]?.stringValue

        if let listed = event.payload["choices"]?.arrayValue?.compactMap(\.stringValue),
            !listed.isEmpty
        {
            self.choices = listed
        } else {
            // Derive like the server does when choices is absent:
            // allow_permanent/allow_session absent mean *allowed* (!= false).
            var derived = ["once"]
            if event.payload["smart_denied"]?.truthy != true {
                if event.payload["allow_session"]?.boolValue != false { derived.append("session") }
                if event.payload["allow_permanent"]?.boolValue != false { derived.append("always") }
            }
            derived.append("deny")
            self.choices = derived
        }
    }
}

/// `clarify.request` — correlated by `request_id`; may be cleared by a
/// matching `clarify.expire`. Empty answer = skip.
///
/// Two wire shapes: the historical single question (`question`/`choices` at
/// the top level), and the batch shape (v0.20.5+) — `questions: [{qid,
/// question, choices, multi_select}]` with NO top-level question. Batch
/// answers go per question via `clarify.respond {request_id, question_id,
/// answer}` (each returns the still-unanswered `remaining` qids; the batch
/// resolves when it empties); a respond with no question_id cancels the
/// whole batch.
public struct ClarifyRequest: Sendable, Equatable, Identifiable {
    /// Decode the matching pending-prompt snapshot with the full live vocabulary.
    public init?(payload: JSONValue, sessionID: String?) {
        self.init(event: GatewayEvent(type: GatewayEvent.Kind.clarifyRequest, sessionID: sessionID, payload: payload))
    }

    public struct Question: Sendable, Equatable, Identifiable {
        public var qid: String
        public var question: String
        public var choices: [String]
        public var multiSelect: Bool

        public var id: String { qid }
    }

    public var requestID: String
    public var sessionID: String?
    public var question: String
    /// nil/empty = free-text question.
    public var choices: [String]
    public var multiSelect: Bool
    /// Non-empty = batch shape; `question`/`choices` above are then empty.
    public var questions: [Question]
    /// Batch answers already locked server-side (qid → answer) — present on
    /// the resume payload's `pending_clarify` snapshot after a reconnect.
    public var lockedAnswers: [String: String]

    public var id: String { requestID }
    public var isBatch: Bool { !questions.isEmpty }

    public init?(event: GatewayEvent) {
        guard event.type == GatewayEvent.Kind.clarifyRequest,
            let requestID = event.payload["request_id"]?.stringValue
        else { return nil }
        self.requestID = requestID
        self.sessionID = event.sessionID
        self.question = event.payload["question"]?.stringValue ?? ""
        self.choices = Self.cleanChoices(event.payload["choices"])
        self.multiSelect = event.payload["multi_select"]?.truthy ?? false
        self.questions =
            event.payload["questions"]?.arrayValue?.compactMap { entry -> Question? in
                guard let qid = entry["qid"]?.stringValue, !qid.isEmpty else { return nil }
                return Question(
                    qid: qid,
                    question: entry["question"]?.stringValue ?? "",
                    choices: Self.cleanChoices(entry["choices"]),
                    multiSelect: entry["multi_select"]?.truthy ?? false)
            } ?? []
        var locked: [String: String] = [:]
        if let answers = event.payload["answers"]?.objectValue {
            for (qid, value) in answers { locked[qid] = value.stringValue ?? "" }
        }
        self.lockedAnswers = locked
    }

    private static func cleanChoices(_ json: JSONValue?) -> [String] {
        json?.arrayValue?
            .compactMap(\.stringValue)
            .filter { !$0.isEmpty && $0.count <= 200 && !$0.contains("\n") } ?? []
    }
}

/// `sudo.request` — the agent needs the user's sudo password. Correlated by
/// `request_id`; answer with `sudo.respond {request_id, password}`. The value
/// must never be logged or persisted. Empty answer = decline.
public struct SudoRequest: Sendable, Equatable, Identifiable {
    public var requestID: String
    public var sessionID: String?

    public var id: String { requestID }

    public init?(event: GatewayEvent) {
        guard event.type == GatewayEvent.Kind.sudoRequest,
            let requestID = event.payload["request_id"]?.stringValue
        else { return nil }
        self.requestID = requestID
        self.sessionID = event.sessionID
    }
}

/// `secret.request` — a skill wants a credential captured into `env_var`.
/// Correlated by `request_id`; answer with `secret.respond {request_id,
/// value}`. The value must never be logged or persisted. Empty answer = skip.
public struct SecretRequest: Sendable, Equatable, Identifiable {
    public var requestID: String
    public var sessionID: String?
    public var prompt: String
    public var envVar: String?

    public var id: String { requestID }

    public init?(event: GatewayEvent) {
        guard event.type == GatewayEvent.Kind.secretRequest,
            let requestID = event.payload["request_id"]?.stringValue
        else { return nil }
        self.requestID = requestID
        self.sessionID = event.sessionID
        self.prompt = event.payload["prompt"]?.stringValue ?? ""
        self.envVar = event.payload["env_var"]?.stringValue
    }
}

/// `mcp.setup.request` — the agent's `setup_mcp` tool proposes installing,
/// enabling, or authorizing an MCP server and blocks (up to 10 minutes) on
/// the user's consent. Correlated by `request_id`; may be cleared by a
/// matching `mcp.setup.expire`. Answer with `mcp.setup.respond {request_id,
/// result}` where `result` is a JSON string `{status, server, detail?}` and
/// status ∈ installed|enabled|authorized|declined|error.
public struct McpSetupRequest: Sendable, Equatable, Identifiable {
    public var requestID: String
    public var sessionID: String?
    /// Catalog or config name of the MCP server.
    public var server: String
    /// One of install/enable/authorize.
    public var action: String
    /// The agent's one-line rationale, for display on the card.
    public var reason: String

    public var id: String { requestID }

    public init?(event: GatewayEvent) {
        guard event.type == GatewayEvent.Kind.mcpSetupRequest,
            let requestID = event.payload["request_id"]?.stringValue
        else { return nil }
        self.requestID = requestID
        self.sessionID = event.sessionID
        self.server = event.payload["server"]?.stringValue ?? ""
        self.action = event.payload["action"]?.stringValue ?? "install"
        self.reason = event.payload["reason"]?.stringValue ?? ""
    }
}

/// Usage counters from `message.complete` / `session.usage`. These are
/// SESSION-CUMULATIVE snapshots (the server reports the agent's lifetime
/// counters, not per-turn deltas) — the latest snapshot replaces the
/// previous one; never sum them.
public struct TurnUsage: Sendable, Equatable {
    public var calls: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var totalTokens: Int
    /// Current context-window occupancy gauge. Only present when the
    /// backend's compressor reports real per-window numbers.
    public var contextUsed: Int?
    public var contextMax: Int?
    public var contextPercent: Int?

    public init?(json: JSONValue?) {
        guard let json, json.objectValue != nil else { return nil }
        self.calls = json["calls"]?.intValue ?? 0
        self.inputTokens = json["input"]?.intValue ?? 0
        self.outputTokens = json["output"]?.intValue ?? 0
        self.totalTokens = json["total"]?.intValue
            ?? (self.inputTokens + self.outputTokens)
        self.contextUsed = json["context_used"]?.intValue
        self.contextMax = json["context_max"]?.intValue
        self.contextPercent = json["context_percent"]?.intValue
    }
}
