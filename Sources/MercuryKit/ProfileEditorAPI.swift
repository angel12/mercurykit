import Foundation

/// What hermes desktop's profile editor shows for a profile
/// (`profiles.describe`, `ProfilesDescribeResult`).
public struct ProfileDescription: Sendable, Equatable {
    public struct Capability: Sendable, Equatable, Identifiable {
        public var name: String
        public var enabled: Bool
        public var id: String { name }
        public init(name: String, enabled: Bool) { self.name = name; self.enabled = enabled }
    }

    public struct Toolset: Sendable, Equatable, Identifiable {
        public var name: String
        public var label: String
        public var description: String
        public var toolCount: Int
        public var enabled: Bool
        public var id: String { name }
        public init(name: String, label: String, description: String, toolCount: Int, enabled: Bool) {
            self.name = name; self.label = label; self.description = description
            self.toolCount = toolCount; self.enabled = enabled
        }
    }

    public struct MCPServer: Sendable, Equatable, Identifiable {
        public var name: String
        public var enabled: Bool
        /// `stdio`, or the HTTP transport for a `url` server.
        public var transport: String
        public var id: String { name }
        public init(name: String, enabled: Bool, transport: String) {
            self.name = name; self.enabled = enabled; self.transport = transport
        }
    }

    /// A pinned model. Upstream pins the two together.
    public struct ModelPin: Sendable, Equatable {
        public var provider: String
        public var model: String
        public init(provider: String, model: String) { self.provider = provider; self.model = model }
    }

    public var name: String
    public var description: String
    public var soul: String
    /// nil when the profile pins no model (it inherits the launch profile's).
    public var model: ModelPin?
    public var skills: [Capability]
    public var toolsets: [Toolset]
    /// Whether the toolsets are an explicit pin rather than the platform default.
    public var toolsetsPinned: Bool
    public var mcpServers: [MCPServer]

    /// nil when `name` or `model` is missing (both required by the contract).
    public init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue, let model = json["model"]?.objectValue else { return nil }
        self.name = name
        description = json["description"]?.stringValue ?? ""
        soul = json["soul"]?.stringValue ?? ""
        let provider = model["provider"]?.stringValue ?? ""
        let pinned = model["default"]?.stringValue ?? ""
        self.model = provider.isEmpty || pinned.isEmpty ? nil : ModelPin(provider: provider, model: pinned)
        skills = (json["skills"]?.arrayValue ?? []).compactMap { row in
            row["name"]?.stringValue.map { Capability(name: $0, enabled: row["enabled"]?.truthy ?? true) }
        }
        toolsets = (json["toolsets"]?.arrayValue ?? []).compactMap { row in
            row["name"]?.stringValue.map {
                Toolset(
                    name: $0, label: row["label"]?.stringValue ?? "",
                    description: row["description"]?.stringValue ?? "",
                    toolCount: row["tool_count"]?.intValue ?? 0, enabled: row["enabled"]?.truthy ?? true)
            }
        }
        toolsetsPinned = json["toolsets_pinned"]?.truthy ?? false
        mcpServers = (json["mcp_servers"]?.arrayValue ?? []).compactMap { row in
            row["name"]?.stringValue.map {
                MCPServer(
                    name: $0, enabled: row["enabled"]?.truthy ?? true,
                    transport: row["transport"]?.stringValue ?? "stdio")
            }
        }
    }
}

/// The editor sections to save with `profiles.configure`. A nil field is
/// left out, and upstream leaves that section untouched. `ui_meta` isn't
/// here: `configureBotMeta` writes it with its CAS revision.
public struct ProfileChanges: Sendable, Equatable {
    public var soul: String?
    public var description: String?
    public var model: ProfileDescription.ModelPin?
    /// Resend a guarded model after the user confirmed it.
    public var confirmExpensiveModel: Bool?
    /// The complete list of disabled skills.
    public var disabledSkills: [String]?
    /// The toolset pin; empty clears it (the platform default applies).
    public var enabledToolsets: [String]?
    /// The complete list of enabled MCP servers.
    public var enabledMCPServers: [String]?

    public init(
        soul: String? = nil, description: String? = nil, model: ProfileDescription.ModelPin? = nil,
        confirmExpensiveModel: Bool? = nil, disabledSkills: [String]? = nil,
        enabledToolsets: [String]? = nil, enabledMCPServers: [String]? = nil
    ) {
        self.soul = soul; self.description = description; self.model = model
        self.confirmExpensiveModel = confirmExpensiveModel; self.disabledSkills = disabledSkills
        self.enabledToolsets = enabledToolsets; self.enabledMCPServers = enabledMCPServers
    }

    func params(name: String) -> JSONValue {
        var params: [String: JSONValue] = ["name": .string(name)]
        if let soul { params["soul"] = .string(soul) }
        if let description { params["description"] = .string(description) }
        if let model {
            params["model"] = .string(model.model)
            params["provider"] = .string(model.provider)
        }
        if let confirmExpensiveModel { params["confirm_expensive_model"] = .bool(confirmExpensiveModel) }
        if let disabledSkills { params["disabled_skills"] = .array(disabledSkills.map(JSONValue.string)) }
        if let enabledToolsets { params["enabled_toolsets"] = .array(enabledToolsets.map(JSONValue.string)) }
        if let enabledMCPServers { params["enabled_mcp_servers"] = .array(enabledMCPServers.map(JSONValue.string)) }
        return .object(params)
    }
}

/// What `profiles.configure` reports for each section it was sent.
public struct ProfileConfigureOutcome: Sendable, Equatable {
    public enum Section: String, Sendable, CaseIterable {
        case soul, description, model, skills, toolsets
        case mcpServers = "mcp_servers"
    }

    /// Only the sections the request carried. A pending model is absent.
    public var applied: [Section: Bool]
    /// The model section wrote nothing: ask the user, then resend only the
    /// model with `confirmExpensiveModel: true`.
    public var confirmationRequired: Bool
    public var confirmationMessage: String?

    public var failedSections: [Section] { Section.allCases.filter { applied[$0] == false } }

    init?(json: JSONValue) {
        guard let applied = json["applied"]?.objectValue else { return nil }
        var sections: [Section: Bool] = [:]
        for section in Section.allCases {
            if let value = applied[section.rawValue], value != .null { sections[section] = value.truthy }
        }
        self.applied = sections
        confirmationRequired = json["confirm_required"]?.truthy ?? false
        confirmationMessage = json["confirm_message"]?.stringValue
    }
}

extension HermesConnection {
    /// The profile editor's snapshot. Throws `rpcError` 4064
    /// (`RPCCode.profileUnavailable`) for an unknown profile.
    public func describeProfile(name: String, timeout: TimeInterval = 30) async throws -> ProfileDescription {
        let result = try await request("profiles.describe", params: .object(["name": .string(name)]), timeout: timeout)
        guard let profile = ProfileDescription(json: result) else {
            throw HermesError.malformedResponse("profiles.describe returned no name or model")
        }
        return profile
    }

    /// Save editor sections (`profiles.configure`). Sections apply
    /// independently. Check `failedSections`, and `confirmationRequired`
    /// when `changes.model` is set.
    public func configureProfile(
        name: String, changes: ProfileChanges, timeout: TimeInterval = 60
    ) async throws -> ProfileConfigureOutcome {
        let result = try await request("profiles.configure", params: changes.params(name: name), timeout: timeout)
        guard let outcome = ProfileConfigureOutcome(json: result) else {
            throw HermesError.malformedResponse("profiles.configure returned no applied")
        }
        return outcome
    }
}
