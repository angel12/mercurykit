import Foundation
import Security

@testable import MercuryKit

/// `http://127.0.0.1:<port>`, the base URL for a RoutedHTTPServer standing in for the relay.
func pushTestURL(port: UInt16) -> URL {
    URL(string: "http://127.0.0.1:\(port)")!
}

/// Thread-safe box for mutable test state captured by @Sendable server handlers.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
    func mutate<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}

/// A dictionary standing in for the Keychain: implements the injected SecItem closures.
final class InMemoryKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]  // "service|account" → value
    private var _lastAddAttributes: [String: Any] = [:]
    var failWrites: OSStatus?
    /// When set, every read returns this status and no data (e.g. errSecInteractionNotAllowed before first unlock).
    var failReads: OSStatus?

    var lastAddAttributes: [String: Any] { lock.withLock { _lastAddAttributes } }

    func storedValue(service: String, account: String) -> Data? {
        lock.withLock { items["\(service)|\(account)"] }
    }

    func put(service: String, account: String, value: Data) {
        lock.withLock { items["\(service)|\(account)"] = value }
    }

    private static func key(_ query: [String: Any]) -> String {
        "\(query[kSecAttrService as String] as? String ?? "")|\(query[kSecAttrAccount as String] as? String ?? "")"
    }

    var calls: KeychainCalls {
        KeychainCalls(
            update: { [self] query, attributes in
                lock.withLock {
                    if let failWrites { return failWrites }
                    let key = Self.key(query as? [String: Any] ?? [:])
                    guard items[key] != nil else { return errSecItemNotFound }
                    items[key] = (attributes as? [String: Any])?[kSecValueData as String] as? Data
                    return errSecSuccess
                }
            },
            add: { [self] item in
                lock.withLock {
                    if let failWrites { return failWrites }
                    let dict = item as? [String: Any] ?? [:]
                    _lastAddAttributes = dict
                    items[Self.key(dict)] = dict[kSecValueData as String] as? Data
                    return errSecSuccess
                }
            },
            delete: { [self] query in
                lock.withLock {
                    let key = Self.key(query as? [String: Any] ?? [:])
                    return items.removeValue(forKey: key) == nil ? errSecItemNotFound : errSecSuccess
                }
            })
    }

    var read: PushPairingStore.Read {
        { [self] query in
            lock.withLock {
                if let failReads { return (failReads, nil) }
                let data = items[Self.key(query as? [String: Any] ?? [:])]
                return (data == nil ? errSecItemNotFound : errSecSuccess, data)
            }
        }
    }
}

/// Stateful fake of the Mercury Push relay + Hermes plugin behind one RoutedHTTPServer.
final class FakePushBackend: @unchecked Sendable {
    struct Installation { var secret: String; var token: String; var environment: String; var bundle: String }
    struct Device { var id: String; var installation: String; var profile: String; var active: Bool }

    private let lock = NSLock()
    private var installations: [String: Installation] = [:]
    private var codes: [String: String] = [:]  // code → installation id
    private var devices: [String: Device] = [:]
    private var counter = 0
    /// Knobs (consumed once each).
    var failNextPutWith401 = false
    var failNextNewCodeWith401 = false
    var failNextRegisterWith500 = false
    var failNextPutWith500 = false
    var expireNextCodeOnClaim = false
    var pluginStatusOverride: (Int, String)?
    /// The `device_name` of the most recent pairing claim.
    private var _lastDeviceName: String?
    var lastDeviceName: String? { lock.withLock { _lastDeviceName } }

    private var _log: [String] = []
    /// "METHOD path?query" in arrival order.
    var log: [String] { lock.withLock { _log } }

    func installation(_ id: String) -> Installation? { lock.withLock { installations[id] } }
    var installationCount: Int { lock.withLock { installations.count } }
    func device(_ id: String) -> Device? { lock.withLock { devices[id] } }
    func deactivate(_ deviceID: String) { lock.withLock { devices[deviceID]?.active = false } }
    func removeDevice(_ deviceID: String) { lock.withLock { _ = devices.removeValue(forKey: deviceID) } }
    /// Simulates the relay pruning or deleting an installation out from under the app.
    func dropInstallation(_ id: String) { lock.withLock { _ = installations.removeValue(forKey: id) } }

    func handle(_ request: RoutedHTTPServer.Request) -> RoutedHTTPServer.Response {
        lock.withLock {
            _log.append("\(request.method) \(request.path)")
            let parts = request.path.components(separatedBy: "?")
            let path = parts[0]
            let profile = parts.count > 1 ? parts[1].replacingOccurrences(of: "profile=", with: "") : ""
            let body = (try? JSONDecoder().decode(JSONValue.self, from: request.body)) ?? .object([:])
            let bearer = request.headers["authorization"].map { String($0.dropFirst("Bearer ".count)) }
            if path.hasPrefix("/v1/") { return relay(request.method, path, body, bearer) }
            return plugin(request.method, path, profile, body)
        }
    }

    private func next(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)_\(counter)"
    }

    private func newCode(for installation: String) -> RoutedHTTPServer.Response {
        let code = next("CODE")
        codes[code] = installation
        return .init(201, #"{"pairing_code":"\#(code)","pairing_expires_at":"2026-09-21T14:13:20Z"}"#)
    }

    private func relay(_ method: String, _ path: String, _ body: JSONValue, _ bearer: String?) -> RoutedHTTPServer.Response {
        let unauthorized = RoutedHTTPServer.Response(401, #"{"error":"credential_invalid","message":"x"}"#)
        if method == "POST", path == "/v1/installations" {
            if failNextRegisterWith500 { failNextRegisterWith500 = false; return .init(500, #"{"error":"boom"}"#) }
            let id = next("inst")
            let secret = next("secret")
            installations[id] = Installation(
                secret: secret, token: body["device_token"]?.stringValue ?? "",
                environment: body["environment"]?.stringValue ?? "", bundle: body["bundle_id"]?.stringValue ?? "")
            let code = next("CODE")
            codes[code] = id
            return .init(201, #"{"installation_id":"\#(id)","installation_secret":"\#(secret)","pairing_code":"\#(code)","pairing_expires_at":"2026-09-21T14:13:20Z"}"#)
        }
        let segments = path.split(separator: "/").map(String.init)  // ["v1","installations",id,(pairing-codes)]
        guard segments.count >= 3, let current = installations[segments[2]], current.secret == bearer else {
            return unauthorized
        }
        let id = segments[2]
        switch (method, segments.count) {
        case ("PUT", 3):
            if failNextPutWith401 { failNextPutWith401 = false; return unauthorized }
            if failNextPutWith500 { failNextPutWith500 = false; return .init(500, #"{"error":"boom"}"#) }
            if let token = body["device_token"]?.stringValue { installations[id]?.token = token }
            if let env = body["environment"]?.stringValue { installations[id]?.environment = env }
            return .init(200, #"{"ok":true}"#)
        case ("POST", 4):
            if failNextNewCodeWith401 { failNextNewCodeWith401 = false; installations[id] = nil; return unauthorized }
            return newCode(for: id)
        case ("DELETE", 3):
            installations[id] = nil
            return .init(204, "")
        default:
            return .init(404, #"{"error":"not_found"}"#)
        }
    }

    private func plugin(_ method: String, _ path: String, _ profile: String, _ body: JSONValue) -> RoutedHTTPServer.Response {
        if let (status, text) = pluginStatusOverride { return .init(status, text) }
        let base = "/api/plugins/mercury_push/devices"
        if method == "POST", path == base {
            let code = body["pairing_code"]?.stringValue ?? ""
            _lastDeviceName = body["device_name"]?.stringValue
            if expireNextCodeOnClaim { expireNextCodeOnClaim = false; codes[code] = nil }
            guard let installation = codes.removeValue(forKey: code), installations[installation] != nil else {
                return .init(502, #"{"error":"relay_error","relay_error":"pairing_code_invalid"}"#)
            }
            devices = devices.filter { !($0.value.installation == installation && $0.value.profile == profile) }
            let id = next("dev")
            devices[id] = Device(id: id, installation: installation, profile: profile, active: true)
            return .init(201, #"{"device_id":"\#(id)","profile":"\#(profile.isEmpty ? "default" : profile)"}"#)
        }
        if method == "GET", path == base {
            let items = devices.values.filter { $0.profile == profile }.map {
                #"{"device_id":"\#($0.id)","device_name":"iPhone","preferences":{},"paired_at":null,"last_delivery_at":null,"last_error":null,"active":\#($0.active)}"#
            }
            return .init(200, "[\(items.joined(separator: ","))]")
        }
        if method == "DELETE", path.hasPrefix(base + "/") {
            let id = String(path.dropFirst(base.count + 1))
            guard devices[id]?.profile == profile, devices.removeValue(forKey: id) != nil else {
                return .init(404, #"{"error":"device_not_found"}"#)
            }
            return .init(204, "")
        }
        return .init(404, #"{"detail":"Not Found"}"#)
    }
}
