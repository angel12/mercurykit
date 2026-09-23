import Foundation

/// `connection.request` (contract ≥ 7, hermes-agent e0ef0eb9c3): a connection
/// operation (install / enable / authorize an MCP server, connect a
/// connector, a catalog plugin or skill) opened a consent card on the
/// session. It replaces `mcp.setup.request`; there is no wire compatibility
/// with the old names. Answer it with `HermesConnection.respondConnection`.
///
/// Later `connection.update` events carry the operation's full snapshot.
/// A frame whose `seq` is not above the one the card holds is older and
/// must not move any row.
///
/// Decoding is fail-closed on the fields the contract requires
/// (`ConnectionRequestPayload`): a card shown without its operation id,
/// deadline or a readable target list could not be answered correctly.
public struct ConnectionRequest: Sendable, Equatable, Identifiable {
    public var opID: String
    public var sessionID: String?
    /// Monotonic write counter for the operation.
    public var seq: Int
    /// Epoch seconds at which the backend stops waiting.
    public var deadlineAt: Double
    public var timeoutSeconds: Double
    public var targets: [Target]
    /// The model's id for the tool call that opened the operation; the card
    /// belongs to that tool row only.
    public var toolCallID: String?

    public var id: String { opID }

    /// One row of the card (`ConnectionOperationTarget`). The contract's
    /// catalog-row fields and any later additions stay readable in `raw`.
    public struct Target: Sendable, Equatable, Identifiable {
        public var name: String
        /// connector | mcp | plugin | skill (open set).
        public var kind: String
        /// authorize | connect | enable | install | reconnect (open set).
        public var action: String
        /// pending | initiated | connected | skipped | failed | expired |
        /// not_connected (open set).
        public var state: String
        public var detail: String?
        public var instructions: String?
        public var connectURL: String?
        /// Credentials an MCP install still needs; send the values back in
        /// `ConnectionAnswer.Target.env`. Never log or persist them.
        public var requiredEnv: [EnvField]
        public var raw: JSONValue

        public var id: String { name }

        init?(json: JSONValue) {
            guard json.objectValue != nil,
                let name = json["name"]?.stringValue, !name.isEmpty,
                let kind = json["kind"]?.stringValue,
                let action = json["action"]?.stringValue,
                let state = json["state"]?.stringValue
            else { return nil }
            var requiredEnv: [EnvField] = []
            if let field = json["required_env"], field != .null {
                guard let entries = field.arrayValue else { return nil }
                for entry in entries {
                    guard let env = EnvField(json: entry) else { return nil }
                    requiredEnv.append(env)
                }
            }
            self.name = name
            self.kind = kind
            self.action = action
            self.state = state
            self.detail = json["detail"]?.stringValue
            self.instructions = json["instructions"]?.stringValue
            self.connectURL = json["connect_url"]?.stringValue
            self.requiredEnv = requiredEnv
            self.raw = json
        }
    }

    /// One credential field an MCP install asks for (`ConnectionTargetEnvField`).
    public struct EnvField: Sendable, Equatable, Identifiable {
        public var name: String
        public var required: Bool
        /// Render as a secure field.
        public var secret: Bool
        public var defaultValue: String
        public var prompt: String?

        public var id: String { name }

        init?(json: JSONValue) {
            guard let name = json["name"]?.stringValue, !name.isEmpty,
                let required = json["required"]?.boolValue,
                let secret = json["secret"]?.boolValue,
                let defaultValue = json["default"]?.stringValue
            else { return nil }
            self.name = name
            self.required = required
            self.secret = secret
            self.defaultValue = defaultValue
            self.prompt = json["prompt"]?.stringValue
        }
    }

    public init?(event: GatewayEvent) {
        guard event.type == GatewayEvent.Kind.connectionRequest else { return nil }
        self.init(payload: event.payload, sessionID: event.sessionID)
    }

    /// Also decodes the `pending_connection` resume snapshot (same shape).
    public init?(payload: JSONValue, sessionID: String?) {
        guard let opID = payload["op_id"]?.stringValue, !opID.isEmpty,
            let seq = payload["seq"]?.intValue,
            let deadlineAt = payload["deadline_at"]?.doubleValue,
            let timeoutSeconds = payload["timeout_seconds"]?.doubleValue,
            let rawTargets = payload["targets"]?.arrayValue
        else { return nil }
        var targets: [Target] = []
        for entry in rawTargets {
            guard let target = Target(json: entry) else { return nil }
            targets.append(target)
        }
        self.opID = opID
        self.sessionID = sessionID
        self.seq = seq
        self.deadlineAt = deadlineAt
        self.timeoutSeconds = timeoutSeconds
        self.targets = targets
        self.toolCallID = payload["tool_call_id"]?.stringValue
    }
}

/// The card's answer to a `ConnectionRequest` (`ConnectionAnswer` in the
/// contract): per-target approve/skip, plus an optional Continue. The card
/// never reports an outcome itself; the backend derives settlement from the
/// target states afterwards.
public struct ConnectionAnswer: Sendable, Equatable {
    public enum Status: String, Sendable {
        case approved
        case skipped
    }

    public struct Target: Sendable, Equatable {
        public var name: String
        public var status: Status
        public var detail: String?
        /// Values for the target's `requiredEnv` fields. Never log them.
        public var env: [String: String]?

        public init(name: String, status: Status, detail: String? = nil, env: [String: String]? = nil) {
            self.name = name
            self.status = status
            self.detail = detail
            self.env = env
        }
    }

    public var targets: [Target]
    /// True sends `settled_by: "continue"`: the user chose to continue
    /// without waiting for the remaining targets.
    public var continueOperation: Bool

    public init(targets: [Target], continueOperation: Bool = false) {
        self.targets = targets
        self.continueOperation = continueOperation
    }

    /// Exactly the declared keys; the backend refuses others with 4000.
    var json: JSONValue {
        var object: [String: JSONValue] = [
            "targets": .array(
                targets.map { target in
                    var row: [String: JSONValue] = [
                        "name": .string(target.name), "status": .string(target.status.rawValue),
                    ]
                    if let detail = target.detail { row["detail"] = .string(detail) }
                    if let env = target.env { row["env"] = .object(env.mapValues(JSONValue.string)) }
                    return .object(row)
                })
        ]
        if continueOperation { object["settled_by"] = .string("continue") }
        return .object(object)
    }
}
