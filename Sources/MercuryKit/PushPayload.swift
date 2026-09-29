import Foundation

/// Where a tapped Mercury Push notification should take the user.
public enum PushRoute: Sendable, Equatable {
    /// Open the stored session with this id in `profile`.
    case session(id: String, profile: String)
    /// Only a gateway routing key is known (some approval prompts); the app resolves it.
    case sessionKey(String, profile: String)
    /// No session (cron results, test pushes).
    case none
}

/// The `userInfo["mercury"]` block of a Mercury Push notification (mercury-push envelope v1).
///
/// Decoding is tolerant by design: unknown kinds become `.unknown`, and newer envelope
/// versions still decode their v1 fields, so a relay upgrade never breaks an older app.
public struct PushPayload: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case approval, responseReady, turnFailed, taskDone, cron, test
        case unknown(String)

        init(wire: String) {
            switch wire {
            case "approval": self = .approval
            case "response_ready": self = .responseReady
            case "turn_failed": self = .turnFailed
            case "task_done": self = .taskDone
            case "cron": self = .cron
            case "test": self = .test
            default: self = .unknown(wire)
            }
        }
    }

    public let version: Int
    public let kind: Kind
    public let eventID: String
    public let profile: String
    public let sessionID: String?
    public let sessionKey: String?
    public let requestID: String?
    public let cronJob: String?
    /// The pairing this copy of the notification was delivered for (the plugin's device id).
    /// Map it with `PushPairing.pairing(forDeviceID:)` to find the server and profile. Nil from older plugins.
    public let deviceID: String?

    /// Returns nil when `userInfo` has no well-formed `mercury` block.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let block = userInfo["mercury"] as? [String: Any] else { return nil }
        func text(_ key: String) -> String? {
            guard let value = block[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        guard let kind = text("kind"), let eventID = text("event_id"), let profile = text("profile")
        else { return nil }
        self.version = (block["v"] as? Int) ?? 1
        self.kind = Kind(wire: kind)
        self.eventID = eventID
        self.profile = profile
        self.sessionID = text("session_id")
        self.sessionKey = text("session_key")
        self.requestID = text("request_id")
        self.cronJob = text("cron_job")
        self.deviceID = text("device_id")
    }

    /// Prefer the stored session id, then the routing key, else no session.
    public var route: PushRoute {
        if let sessionID { return .session(id: sessionID, profile: profile) }
        if let sessionKey { return .sessionKey(sessionKey, profile: profile) }
        return .none
    }
}
