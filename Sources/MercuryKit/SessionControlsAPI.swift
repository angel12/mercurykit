import Foundation

// Per-session controls and slash commands, matching what Desktop drives over
// the same desktop-contract socket (hermes-agent v0.23.0). Every method here
// is a regular `methods` entry in `apps/shared/src/gateway-contract.openrpc.json`
// — none needs the canonical (`hermes-gateway-v1`) protocol.

/// `config.set`'s read-back.
public struct ConfigSetResult: Sendable, Equatable {
    public var key: String
    /// The normalised value the server stored (`"on"`, `"high"`, a model id…).
    public var value: String?
    public var warning: String?
    /// An expensive model was picked: nothing changed. Show `confirmMessage`
    /// and resend with `confirmExpensiveModel: true` if the user agrees.
    public var confirmRequired: Bool
    public var confirmMessage: String?

    init(result: JSONValue, key: String) {
        self.key = result["key"]?.stringValue ?? key
        switch result["value"] {
        case .string(let text)?: value = text
        case .bool(let flag)?: value = flag ? "on" : "off"
        default: value = nil
        }
        warning = result["warning"]?.stringValue
        confirmRequired = result["confirm_required"]?.boolValue ?? false
        confirmMessage = result["confirm_message"]?.stringValue
    }
}

/// `model.options` — the providers and models a session may switch to.
public struct ModelOptions: Sendable, Equatable {
    public struct Provider: Sendable, Equatable, Identifiable {
        public var slug: String
        public var name: String
        public var models: [String]
        /// The short list Desktop shows first; empty when the server has none.
        public var featuredModels: [String]
        /// False when the provider has no credentials yet: picking one of
        /// its models would fail.
        public var authenticated: Bool
        public var isCurrent: Bool
        public var warning: String?
        public var id: String { slug }
    }

    public var providers: [Provider]
    public var currentModel: String?
    public var currentProvider: String?

    public init(result: JSONValue) {
        providers = (result["providers"]?.arrayValue ?? []).compactMap { row in
            guard let slug = row["slug"]?.stringValue, !slug.isEmpty else { return nil }
            return Provider(
                slug: slug,
                name: row["name"]?.stringValue ?? slug,
                models: (row["models"]?.arrayValue ?? []).compactMap(\.stringValue),
                featuredModels: (row["featured_models"]?.arrayValue ?? []).compactMap(\.stringValue),
                // Older rows omit the flag; treat absence as usable, like Desktop.
                authenticated: row["authenticated"]?.boolValue ?? true,
                isCurrent: row["is_current"]?.boolValue ?? false,
                warning: row["warning"]?.stringValue)
        }
        currentModel = result["model"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        currentProvider = result["provider"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Reasoning levels `config.set {key: "reasoning"}` accepts
/// (`hermes_constants.VALID_REASONING_EFFORTS` plus `none`).
public enum ReasoningLevels {
    public static let all = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
}

/// The profile's approval mode (`approvals.mode`).
public enum ApprovalMode: String, Sendable, CaseIterable {
    /// Ask before every flagged command.
    case manual
    /// A model reviews flagged commands and asks only when unsure.
    case smart
    /// Never ask.
    case off
}

/// One `complete.slash` row.
public struct SlashCompletion: Sendable, Equatable, Identifiable {
    /// The replacement text, inserted at `SlashCompletions.replaceFrom`.
    public var text: String
    /// What to show (`/model`).
    public var display: String
    /// One-line description.
    public var meta: String
    public var id: String { text }
}

public struct SlashCompletions: Sendable, Equatable {
    public var items: [SlashCompletion]
    /// The offset into the typed text where `text` replaces the rest.
    public var replaceFrom: Int

    init(result: JSONValue, typed: String) {
        items = (result["items"]?.arrayValue ?? []).compactMap { row in
            guard let text = row["text"]?.stringValue, !text.isEmpty else { return nil }
            return SlashCompletion(
                text: text,
                display: row["display"]?.stringValue ?? text,
                meta: row["meta"]?.stringValue ?? "")
        }
        replaceFrom = min(max(result["replace_from"]?.intValue ?? 1, 0), typed.count)
    }

    /// `typed` with `completion` applied, plus a trailing space so the user
    /// can type an argument straight away.
    public func applying(_ completion: SlashCompletion, to typed: String) -> String {
        String(typed.prefix(replaceFrom)) + completion.text + " "
    }
}

/// What a slash command asks the client to do
/// (`apps/shared/src/slash.ts::parseCommandDispatch`).
public enum SlashOutcome: Sendable, Equatable {
    /// Show this text. Command output is terminal-formatted: render monospaced.
    case output(String)
    /// The command is another name for `target`: run `/target <arg>` instead.
    case alias(target: String)
    /// Send `message` as a prompt. `display` is what the user bubble shows
    /// (a skill's expanded body is model-facing and must never be shown);
    /// `notice` is a line to show first.
    case send(message: String, display: String?, notice: String?)
    /// Put `message` in the composer for editing (`/undo`).
    case prefill(message: String, notice: String?)

    /// Narrow a `slash.exec` / `command.dispatch` result. Nil for a shape no
    /// branch recognises.
    init?(result: JSONValue) {
        let type = result["type"]?.stringValue
        let output = result["output"]?.stringValue
        switch type {
        case "alias":
            guard let target = result["target"]?.stringValue else { return nil }
            self = .alias(target: target)
        case "exec", "plugin":
            self = .output(output ?? "")
        case "prefill":
            guard let message = result["message"]?.stringValue else { return nil }
            self = .prefill(message: message, notice: result["notice"]?.stringValue)
        case "send":
            guard let message = result["message"]?.stringValue else { return nil }
            self = .send(
                message: message, display: result["display"]?.stringValue,
                notice: result["notice"]?.stringValue)
        case "skill":
            guard let name = result["name"]?.stringValue else { return nil }
            let message = result["message"]?.stringValue ?? ""
            self = .send(
                message: message, display: result["display"]?.stringValue ?? "/\(name)",
                notice: nil)
        case nil:
            // Plain `slash.exec` output, optionally with a warning.
            guard output != nil || result["warning"] != nil else { return nil }
            var text = output ?? ""
            if let warning = result["warning"]?.stringValue, !warning.isEmpty {
                text = "warning: \(warning)" + (text.isEmpty ? "" : "\n\(text)")
            }
            self = .output(text)
        default:
            return nil
        }
    }
}

/// A parsed `/name arg` line.
public struct SlashCommand: Sendable, Equatable {
    /// Lowercased, without the slash.
    public var name: String
    public var arg: String

    /// Nil unless `text` starts with a slash command (`/name` followed by a
    /// space or the end). A path like `/usr/bin` is not a command.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst()
        let head = body.prefix { !$0.isWhitespace }
        guard !head.isEmpty, !head.contains("/") else { return nil }
        name = head.lowercased()
        arg = body.dropFirst(head.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The command text `slash.exec` takes (no leading slash).
    public var commandText: String { arg.isEmpty ? name : "\(name) \(arg)" }
}

extension HermesConnection {
    // MARK: Session settings

    /// `config.set` for one session. Model, reasoning and YOLO are
    /// session-scoped by default: they never rewrite the profile default.
    public func setConfig(
        sessionID: String?, key: String, value: JSONValue, profile: String? = nil,
        confirmExpensiveModel: Bool = false
    ) async throws -> ConfigSetResult {
        var params: [String: JSONValue] = ["key": .string(key), "value": value]
        if let sessionID { params["session_id"] = .string(sessionID) }
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        if confirmExpensiveModel { params["confirm_expensive_model"] = .bool(true) }
        // A model switch can wait for the agent to finish starting (up to 30s server-side).
        let result = try await request("config.set", params: .object(params), timeout: 60)
        return ConfigSetResult(result: result, key: key)
    }

    /// Switch this session's model. `--session` keeps the profile default
    /// untouched, as Desktop does for a chat it isn't the primary tile of.
    /// Mid-turn, the server defers the switch to the next turn.
    public func setSessionModel(
        sessionID: String, model: String, provider: String, confirmExpensiveModel: Bool = false
    ) async throws -> ConfigSetResult {
        try await setConfig(
            sessionID: sessionID, key: "model",
            value: .string("\(model) --provider \(provider) --session"),
            confirmExpensiveModel: confirmExpensiveModel)
    }

    /// One of `ReasoningLevels.all`, for this session only.
    public func setSessionReasoning(sessionID: String, level: String) async throws -> ConfigSetResult {
        try await setConfig(sessionID: sessionID, key: "reasoning", value: .string(level))
    }

    /// Auto-approve every command in this session.
    public func setSessionYolo(sessionID: String, enabled: Bool) async throws -> ConfigSetResult {
        try await setConfig(sessionID: sessionID, key: "yolo", value: .string(enabled ? "on" : "off"))
    }

    /// The profile's default approval mode. This writes the profile's config,
    /// so it applies to every session in that profile.
    public func setApprovalMode(_ mode: ApprovalMode, profile: String? = nil) async throws
        -> ConfigSetResult
    {
        try await setConfig(
            sessionID: nil, key: "approvals.mode", value: .string(mode.rawValue), profile: profile)
    }

    /// The profile's approval mode, or nil when the server sent a value this
    /// build doesn't know.
    public func approvalMode(profile: String? = nil) async throws -> ApprovalMode? {
        var params: [String: JSONValue] = ["key": "approvals.mode"]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        let result = try await request("config.get", params: .object(params))
        return result["value"]?.stringValue.flatMap(ApprovalMode.init(rawValue:))
    }

    /// `model.options`, parsed.
    public func loadModelOptions(sessionID: String?) async throws -> ModelOptions {
        ModelOptions(result: try await modelOptions(sessionID: sessionID))
    }

    // MARK: Slash commands

    /// `complete.slash` — ranked completions for a `/` token.
    public func slashCompletions(text: String, sessionID: String?) async throws -> SlashCompletions {
        var params: [String: JSONValue] = ["text": .string(text)]
        if let sessionID { params["session_id"] = .string(sessionID) }
        let result = try await request("complete.slash", params: .object(params))
        return SlashCompletions(result: result, typed: text)
    }

    /// Run a slash command the way Desktop does: `slash.exec` first, then
    /// `command.dispatch` for quick, plugin and skill commands the slash
    /// worker doesn't know. When both fail, the `slash.exec` error is the one
    /// thrown: "not a quick/plugin/skill command" from the fallback is only
    /// routing noise.
    public func runSlash(sessionID: String, command: SlashCommand) async throws -> SlashOutcome {
        let execError: Error
        do {
            let result = try await request(
                "slash.exec",
                params: ["session_id": .string(sessionID), "command": .string(command.commandText)],
                timeout: 120)
            return SlashOutcome(result: result) ?? .output("/\(command.name): no output")
        } catch {
            execError = error
        }
        var params: [String: JSONValue] = [
            "session_id": .string(sessionID), "name": .string(command.name),
        ]
        if !command.arg.isEmpty { params["arg"] = .string(command.arg) }
        do {
            let result = try await request("command.dispatch", params: .object(params), timeout: 120)
            guard let outcome = SlashOutcome(result: result) else {
                throw HermesError.malformedResponse("command.dispatch returned no directive")
            }
            return outcome
        } catch let error as HermesError
            where error.rpcMessage?.range(
                of: #"not a quick/plugin/(bundle/)?skill command"#, options: [.regularExpression, .caseInsensitive])
                != nil
        {
            throw execError
        }
    }

    /// `prompt.btw` — a side question answered from a snapshot of the
    /// conversation while the current turn keeps going. The answer arrives
    /// as a `btw.complete` event carrying the returned task id.
    @discardableResult
    public func askSideQuestion(sessionID: String, text: String) async throws -> String {
        let result = try await request(
            "prompt.btw", params: ["session_id": .string(sessionID), "text": .string(text)])
        guard let taskID = result["task_id"]?.stringValue else {
            throw HermesError.malformedResponse("prompt.btw returned no task_id")
        }
        return taskID
    }
}
