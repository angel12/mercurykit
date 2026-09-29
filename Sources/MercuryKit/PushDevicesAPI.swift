import Foundation

/// Which event kinds a paired device receives. Every kind defaults to on.
public struct PushPreferences: Sendable, Equatable, Codable {
    public var approval: Bool
    public var responseReady: Bool
    public var turnFailed: Bool
    public var taskDone: Bool
    public var cron: Bool

    public init(
        approval: Bool = true, responseReady: Bool = true, turnFailed: Bool = true,
        taskDone: Bool = true, cron: Bool = true
    ) {
        self.approval = approval
        self.responseReady = responseReady
        self.turnFailed = turnFailed
        self.taskDone = taskDone
        self.cron = cron
    }

    /// Missing or non-boolean keys default to `true`; unknown keys are dropped.
    init(json: JSONValue?) {
        func flag(_ key: String) -> Bool { json?[key]?.boolValue ?? true }
        self.init(
            approval: flag("approval"), responseReady: flag("response_ready"), turnFailed: flag("turn_failed"),
            taskDone: flag("task_done"), cron: flag("cron"))
    }

    var json: JSONValue {
        .object([
            "approval": .bool(approval), "response_ready": .bool(responseReady), "turn_failed": .bool(turnFailed),
            "task_done": .bool(taskDone), "cron": .bool(cron),
        ])
    }
}

/// A device paired with one Hermes profile, as the plugin reports it (credentials never leave Hermes).
public struct PushDevice: Sendable, Equatable {
    public let deviceID: String
    public let deviceName: String
    public let preferences: PushPreferences
    public let pairedAt: Date?
    public let lastDeliveryAt: Date?
    public let lastError: String?
    /// False once the relay has unpaired the device (for example, the app was deleted).
    public let active: Bool

    public init(
        deviceID: String, deviceName: String, preferences: PushPreferences, pairedAt: Date?,
        lastDeliveryAt: Date?, lastError: String?, active: Bool
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.preferences = preferences
        self.pairedAt = pairedAt
        self.lastDeliveryAt = lastDeliveryAt
        self.lastError = lastError
        self.active = active
    }

    init?(json: JSONValue) {
        guard let id = json["device_id"]?.stringValue, let name = json["device_name"]?.stringValue else { return nil }
        self.init(
            deviceID: id, deviceName: name, preferences: PushPreferences(json: json["preferences"]),
            pairedAt: json["paired_at"]?.stringValue.flatMap(PushDate.parse),
            lastDeliveryAt: json["last_delivery_at"]?.stringValue.flatMap(PushDate.parse),
            lastError: json["last_error"]?.stringValue, active: json["active"]?.boolValue ?? true)
    }
}

/// The plugin's answer to a successful pairing.
public struct PushDevicePairing: Sendable, Equatable {
    public let deviceID: String
    public let profile: String

    public init(deviceID: String, profile: String) {
        self.deviceID = deviceID
        self.profile = profile
    }
}

/// Errors from the `mercury_push` plugin routes. Descriptions never include credentials or bodies.
public enum PushDevicesError: Error, Sendable, Equatable, LocalizedError {
    /// 502: Hermes reached the relay and the relay refused (e.g. `pairing_code_invalid`).
    case relayError(code: String)
    /// 503: the plugin's `relay_url` setting is invalid.
    case relayURLInvalid
    /// 404 `device_not_found`.
    case deviceNotFound
    /// 404 `profile_not_found`.
    case profileNotFound
    /// 400 `invalid_profile`.
    case invalidProfile
    /// 409: the plugin is disabled in this profile, so its hooks would never fire.
    case pluginNotEnabled(profile: String)
    /// 404 with no plugin error code: the plugin isn't installed, or its routes aren't mounted.
    case pluginUnavailable
    /// Hermes rejected the credentials, even after one refresh.
    case unauthorized
    /// Any other non-2xx status, with the `error` code when the body had one.
    case http(status: Int, code: String?)
    /// The request never completed.
    case transport(String)
    /// A 2xx response without the documented fields.
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .relayError(let code): return "Hermes couldn't reach the push relay (\(code))."
        case .relayURLInvalid: return "Mercury Push on this server has an invalid relay URL."
        case .deviceNotFound: return "This device isn't paired with that profile."
        case .profileNotFound: return "That Hermes profile doesn't exist."
        case .invalidProfile: return "That isn't a valid Hermes profile name."
        case .pluginNotEnabled(let profile): return "Mercury Push isn't enabled for profile \(profile)."
        case .pluginUnavailable: return "Mercury Push isn't installed on this server."
        case .unauthorized: return "Hermes didn't accept the saved sign-in."
        case .http(let status, let code): return "Hermes returned HTTP \(status)\(code.map { " (\($0))" } ?? "")."
        case .transport(let detail): return "Couldn't reach Hermes (\(detail))."
        case .malformedResponse: return "Hermes sent an unexpected response."
        }
    }

    init(status: Int, json: JSONValue?) {
        let code = json?["error"]?.stringValue
        switch (status, code) {
        case (502, "relay_error"): self = .relayError(code: json?["relay_error"]?.stringValue ?? "unknown")
        case (503, "relay_url_invalid"): self = .relayURLInvalid
        case (404, "device_not_found"): self = .deviceNotFound
        case (404, "profile_not_found"): self = .profileNotFound
        case (404, _): self = .pluginUnavailable
        case (400, "invalid_profile"): self = .invalidProfile
        case (409, "plugin_not_enabled"): self = .pluginNotEnabled(profile: json?["profile"]?.stringValue ?? "")
        default: self = .http(status: status, code: code)
        }
    }
}

extension HermesRESTClient {
    static let pushDevicesPath = "/api/plugins/mercury_push/devices"

    /// `POST …/devices?profile=`: pair this relay installation with `profile`. Throws `PushDevicesError`.
    public func pairPushDevice(
        profile: String?, installationID: String, pairingCode: String, deviceName: String,
        preferences: PushPreferences?
    ) async throws -> PushDevicePairing {
        var body: [String: JSONValue] = [
            "installation_id": .string(installationID), "pairing_code": .string(pairingCode),
            "device_name": .string(deviceName),
        ]
        if let preferences { body["preferences"] = preferences.json }
        let json = try await pushRequest("POST", Self.pushDevicesPath, profile: profile, body: .object(body))
        guard let id = json["device_id"]?.stringValue, let paired = json["profile"]?.stringValue else {
            throw PushDevicesError.malformedResponse
        }
        return PushDevicePairing(deviceID: id, profile: paired)
    }

    /// `GET …/devices?profile=`: every device paired with `profile`. Throws `PushDevicesError`.
    public func pushDevices(profile: String?) async throws -> [PushDevice] {
        let json = try await pushRequest("GET", Self.pushDevicesPath, profile: profile, body: nil)
        guard let items = json.arrayValue else { throw PushDevicesError.malformedResponse }
        return items.compactMap(PushDevice.init(json:))
    }

    /// `PATCH …/devices/:id?profile=`. Throws `PushDevicesError`.
    public func updatePushPreferences(
        profile: String?, deviceID: String, _ preferences: PushPreferences
    ) async throws -> PushDevice {
        let json = try await pushRequest(
            "PATCH", Self.pushDevicePath(deviceID), profile: profile, body: .object(["preferences": preferences.json]))
        guard let device = PushDevice(json: json) else { throw PushDevicesError.malformedResponse }
        return device
    }

    /// `POST …/devices/:id/test?profile=`: returns the queued event id. Throws `PushDevicesError`.
    public func sendTestPush(profile: String?, deviceID: String) async throws -> String {
        let json = try await pushRequest("POST", Self.pushDevicePath(deviceID) + "/test", profile: profile, body: nil)
        guard let eventID = json["event_id"]?.stringValue else { throw PushDevicesError.malformedResponse }
        return eventID
    }

    /// `DELETE …/devices/:id?profile=`: also revokes the relay pairing (best effort, server side).
    /// Throws `PushDevicesError`.
    public func unpairPushDevice(profile: String?, deviceID: String) async throws {
        _ = try await pushRequest("DELETE", Self.pushDevicePath(deviceID), profile: profile, body: nil)
    }

    private static func pushDevicePath(_ deviceID: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return pushDevicesPath + "/" + (deviceID.addingPercentEncoding(withAllowedCharacters: allowed) ?? deviceID)
    }

    private func pushRequest(
        _ method: String, _ path: String, profile: String?, body: JSONValue?
    ) async throws -> JSONValue {
        var query: [URLQueryItem] = []
        if let profile, !profile.isEmpty { query.append(URLQueryItem(name: "profile", value: profile)) }
        var request = URLRequest(url: endpoint.restURL(path, query: query))
        request.httpMethod = method
        request.timeoutInterval = 30
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(body)
        }
        let status: Int
        let json: JSONValue?
        do {
            (status, json) = try await performAuthenticatedRaw(request)
        } catch HermesError.unauthorized {
            throw PushDevicesError.unauthorized
        } catch let error as URLError {
            throw PushDevicesError.transport("network error \(error.code.rawValue)")
        } catch {
            throw PushDevicesError.transport("unexpected response")
        }
        guard (200..<300).contains(status) else { throw PushDevicesError(status: status, json: json) }
        return json ?? .object([:])
    }
}
