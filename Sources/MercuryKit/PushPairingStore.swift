import Foundation
import Security

/// One pairing of this installation with a Hermes server + profile.
public struct PushPairingRecord: Sendable, Equatable, Hashable, Codable {
    /// `ServerEndpoint.key` of the Hermes server.
    public let server: String
    /// The profile name; "" means the server's launch profile.
    public let profile: String
    public let deviceID: String
    public let pairedAt: Date

    public init(server: String, profile: String, deviceID: String, pairedAt: Date) {
        self.server = server
        self.profile = profile
        self.deviceID = deviceID
        self.pairedAt = pairedAt
    }
}

/// Everything the kit persists for Mercury Push. `installationSecret` is a credential.
public struct PushPairingState: Sendable, Equatable, Codable {
    public var installationID: String?
    public var installationSecret: String?
    public var bundleID: String?
    public var environment: PushEnvironment?
    public var deviceToken: String?
    public var pairings: [PushPairingRecord]

    public init(
        installationID: String? = nil, installationSecret: String? = nil, bundleID: String? = nil,
        environment: PushEnvironment? = nil, deviceToken: String? = nil, pairings: [PushPairingRecord] = []
    ) {
        self.installationID = installationID
        self.installationSecret = installationSecret
        self.bundleID = bundleID
        self.environment = environment
        self.deviceToken = deviceToken
        self.pairings = pairings
    }
}

extension PushPairingState: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "PushPairingState(installation: \(installationID ?? "none"), secret: \(installationSecret == nil ? "none" : "<redacted>"), "
            + "bundle: \(bundleID ?? "none"), environment: \(environment?.rawValue ?? "none"), pairings: \(pairings.count))"
    }
    public var debugDescription: String { description }
}

/// Persists `PushPairingState` as ONE Keychain item (generic password, account "mercury-push",
/// service injected by the app), device-only and never iCloud-synchronised.
public struct PushPairingStore: Sendable {
    /// `SecItemCopyMatching`, injectable so tests never touch the real Keychain.
    public typealias Read = @Sendable (CFDictionary) -> (OSStatus, Data?)

    public static let liveRead: Read = { query in
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query, &item)
        return (status, item as? Data)
    }

    static let account = "mercury-push"

    private let service: String
    private let calls: KeychainCalls
    private let read: Read

    public init(service: String, calls: KeychainCalls = .live, read: @escaping Read = PushPairingStore.liveRead) {
        self.service = service
        self.calls = calls
        self.read = read
    }

    /// The stored state, or an empty state when there's no item or it can't be decoded.
    public func load() -> PushPairingState {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = read(query as CFDictionary)
        guard status == errSecSuccess, let data,
            let state = try? JSONDecoder().decode(PushPairingState.self, from: data)
        else { return PushPairingState() }
        return state
    }

    /// - Throws: `KeychainError.encodingFailed` or `.writeFailed`.
    public func save(_ state: PushPairingState) throws {
        guard let data = try? JSONEncoder().encode(state) else { throw KeychainError.encodingFailed }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = calls.update(baseQuery as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = calls.add(add as CFDictionary)
            guard addStatus == errSecSuccess else { throw KeychainError.writeFailed(addStatus) }
        default:
            throw KeychainError.writeFailed(status)
        }
    }

    /// Removes the item. A missing item is success. - Throws: `KeychainError.deleteFailed`.
    public func clear() throws {
        let status = calls.delete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]
    }
}
