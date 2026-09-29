import Foundation

/// The APNs environment a device token belongs to. Builds run from Xcode get sandbox tokens;
/// TestFlight and App Store builds get production tokens. The app knows which; the kit never guesses.
public enum PushEnvironment: String, Sendable, Codable, CaseIterable {
    case sandbox, production
}

/// A single-use relay pairing code (10-minute lifetime).
public struct PushPairingCode: Sendable, Equatable {
    public let code: String
    public let expiresAt: Date

    public init(code: String, expiresAt: Date) {
        self.code = code
        self.expiresAt = expiresAt
    }
}

extension PushPairingCode: CustomReflectable {
    public var customMirror: Mirror {
        Mirror(self, children: ["code": "<redacted>", "expiresAt": expiresAt], displayStyle: .struct)
    }
}

extension PushPairingCode: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "PushPairingCode(<redacted>, expiresAt: \(expiresAt))" }
    public var debugDescription: String { description }
}

/// A new relay installation. `installationSecret` authenticates every later relay call.
public struct PushRegistration: Sendable, Equatable {
    public let installationID: String
    public let installationSecret: String
    public let pairingCode: PushPairingCode

    public init(installationID: String, installationSecret: String, pairingCode: PushPairingCode) {
        self.installationID = installationID
        self.installationSecret = installationSecret
        self.pairingCode = pairingCode
    }
}

extension PushRegistration: CustomReflectable {
    public var customMirror: Mirror {
        Mirror(self, children: [
            "installationID": installationID, "installationSecret": "<redacted>", "pairingCode": pairingCode,
        ], displayStyle: .struct)
    }
}

extension PushRegistration: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "PushRegistration(\(installationID), secret: <redacted>)" }
    public var debugDescription: String { description }
}

/// Errors from the Mercury Push relay. Descriptions never include secrets, URLs or bodies.
public enum PushRelayError: Error, Sendable, Equatable, LocalizedError {
    /// 401: the installation or its secret is unknown. Register again.
    case credentialInvalid
    /// 400 `bundle_not_allowed`: this relay doesn't serve the app's bundle ID.
    case bundleNotAllowed
    /// 422: the relay rejected the request body.
    case invalidRequest
    /// 429: too many requests. Honour `retryAfter` (seconds) when present.
    case rateLimited(retryAfter: TimeInterval?)
    /// Any other non-2xx status, with the relay's `error` code when the body had one.
    case http(status: Int, code: String?)
    /// The request never completed (DNS, TLS, connection, timeout).
    case transport(String)
    /// A 2xx response whose body didn't have the documented fields.
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .credentialInvalid: return "The push relay no longer recognises this device."
        case .bundleNotAllowed: return "The push relay doesn't serve this app."
        case .invalidRequest: return "The push relay rejected the request."
        case .rateLimited: return "The push relay is rate-limiting this device. Try again later."
        case .http(let status, let code): return "The push relay returned HTTP \(status)\(code.map { " (\($0))" } ?? "")."
        case .transport(let detail): return "Couldn't reach the push relay (\(detail))."
        case .malformedResponse: return "The push relay sent an unexpected response."
        }
    }
}

/// Parses the relay's and plugin's timestamps: `YYYY-MM-DDTHH:MM:SS[.fraction]Z`
/// (Python `isoformat()` output; the fraction appears only when non-zero).
enum PushDate {
    private static var pattern: Regex<(Substring, base: Substring, fraction: Substring?, zone: Substring)> {
        #/^(?<base>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?<fraction>\.\d+)?(?<zone>Z|[+-]\d{2}:\d{2})$/#
    }

    static func parse(_ raw: String) -> Date? {
        guard let match = raw.wholeMatch(of: pattern) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let whole = formatter.date(from: String(match.base) + String(match.zone)) else { return nil }
        let fraction = match.fraction.flatMap { Double("0" + $0) } ?? 0
        return whole.addingTimeInterval(fraction)
    }
}

/// Client for the Mercury Push relay's installation endpoints (`/v1/installations…`).
///
/// The relay has no Hermes auth: registration is open (rate-limited), and later calls
/// authenticate with `Authorization: Bearer <installation secret>`. Throws `PushRelayError` only.
public struct PushRelayClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://mpns.angelsolutionsnm.com")!

    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = PushRelayClient.defaultBaseURL, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.session = session ?? URLSession(configuration: HermesHTTP.cookieFreeConfig())
    }

    /// `POST /v1/installations`. `deviceToken` is lowercase hex.
    public func register(
        bundleID: String, deviceToken: String, environment: PushEnvironment
    ) async throws -> PushRegistration {
        let json = try await send("POST", "/v1/installations", secret: nil, body: [
            "bundle_id": .string(bundleID),
            "device_token": .string(deviceToken),
            "environment": .string(environment.rawValue),
        ])
        guard let id = json["installation_id"]?.stringValue,
            let secret = json["installation_secret"]?.stringValue,
            let code = Self.pairingCode(in: json)
        else { throw PushRelayError.malformedResponse }
        return PushRegistration(installationID: id, installationSecret: secret, pairingCode: code)
    }

    /// `PUT /v1/installations/:id`. Nil fields are omitted. An empty body still refreshes the
    /// relay's idle clock.
    public func update(
        installationID: String, secret: String, deviceToken: String?, environment: PushEnvironment?
    ) async throws {
        var body: [String: JSONValue] = [:]
        if let deviceToken { body["device_token"] = .string(deviceToken) }
        if let environment { body["environment"] = .string(environment.rawValue) }
        _ = try await send("PUT", "/v1/installations/\(Self.segment(installationID))", secret: secret, body: body)
    }

    /// `POST /v1/installations/:id/pairing-codes`.
    public func newPairingCode(installationID: String, secret: String) async throws -> PushPairingCode {
        let json = try await send(
            "POST", "/v1/installations/\(Self.segment(installationID))/pairing-codes", secret: secret, body: nil)
        guard let code = Self.pairingCode(in: json) else { throw PushRelayError.malformedResponse }
        return code
    }

    /// `DELETE /v1/installations/:id`. This revokes every pairing of the installation.
    public func delete(installationID: String, secret: String) async throws {
        _ = try await send("DELETE", "/v1/installations/\(Self.segment(installationID))", secret: secret, body: nil)
    }

    // MARK: Transport

    private func send(
        _ method: String, _ path: String, secret: String?, body: [String: JSONValue]?
    ) async throws -> JSONValue {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = path
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 30
        if let secret { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(JSONValue.object(body))
        }

        let response: HTTPURLResponse
        let data: Data
        do {
            (response, data) = try await HermesHTTP.load(request, on: session)
        } catch let error as URLError {
            throw PushRelayError.transport("network error \(error.code.rawValue)")
        } catch {
            throw PushRelayError.transport("unexpected response")
        }

        let json = data.isEmpty ? nil : try? JSONDecoder().decode(JSONValue.self, from: data)
        switch response.statusCode {
        case 200..<300:
            return json ?? .object([:])
        case 401:
            throw PushRelayError.credentialInvalid
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw PushRelayError.rateLimited(retryAfter: retryAfter)
        case 422:
            throw PushRelayError.invalidRequest
        default:
            let code = json?["error"]?.stringValue
            if response.statusCode == 400, code == "bundle_not_allowed" { throw PushRelayError.bundleNotAllowed }
            throw PushRelayError.http(status: response.statusCode, code: code)
        }
    }

    private static func pairingCode(in json: JSONValue) -> PushPairingCode? {
        guard let code = json["pairing_code"]?.stringValue,
            let raw = json["pairing_expires_at"]?.stringValue,
            let expiresAt = PushDate.parse(raw)
        else { return nil }
        return PushPairingCode(code: code, expiresAt: expiresAt)
    }

    /// Relay ids are `inst_<hex>`, but encode defensively so an id can never splice a path.
    private static func segment(_ raw: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }
}
