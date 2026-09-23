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
}
