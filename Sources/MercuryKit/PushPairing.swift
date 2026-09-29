import Foundation
import Security

/// Result of `PushPairing.syncPairing`.
public enum PushPairingStatus: Sendable, Equatable {
    case paired(PushDevice)
    case notPaired
}

/// Result of `PushPairing.unpair`.
public enum PushUnpairResult: Sendable, Equatable {
    /// Hermes removed the device (or already had), and the local record is gone.
    case unpaired
    /// Hermes couldn't be told; the local record is gone anyway. The app may want to say so.
    case unpairedLocallyOnly
    case wasNotPaired
}

/// Errors from `PushPairing`. Descriptions never include credentials.
public enum PushPairingError: Error, Sendable, Equatable, LocalizedError {
    /// `pair` was called before `updateDeviceToken` ever stored a token.
    case noDeviceToken
    case relay(PushRelayError)
    case devices(PushDevicesError)
    case storage(KeychainError)
    /// The Keychain item couldn't be read (for example before first unlock). Nothing was sent
    /// to the relay or Hermes and nothing was written; retry later.
    case storageUnavailable(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .noDeviceToken: return "This device hasn't registered for notifications yet."
        case .relay(let error): return error.errorDescription
        case .devices(let error): return error.errorDescription
        case .storage(let error): return error.errorDescription
        case .storageUnavailable: return "The saved push pairing isn't readable right now. Try again after unlocking the device."
        }
    }
}

/// Registers this app install with the Mercury Push relay and pairs it with Hermes servers and
/// profiles, applying the relay's and the plugin's recovery rules. It owns protocol only: the
/// app requests permission, registers for remote notifications, and decides when to pair.
///
/// Mutating calls (`updateDeviceToken`, `pair`, `syncPairing`, `unpair`, `unpairAll`) are
/// serialised in FIFO order, so concurrent callers never interleave across network awaits.
/// `pairings()` and `isPaired` are unsynchronised reads of the current state.
///
/// Use one instance per process and Keychain service; separate instances would each cache their
/// own copy of the state and overwrite one another. Pass profiles consistently: `nil` (the
/// server's launch profile) and `"default"` are different local records.
///
/// The Keychain item is read lazily inside each mutating call, retrying until a read succeeds.
/// An unreadable item (for example before first unlock) throws `PushPairingError.storageUnavailable`
/// before any network call; it is never treated as empty.
public actor PushPairing {
    private let relay: PushRelayClient
    private let store: PushPairingStore
    private let bundleID: String
    private let environment: PushEnvironment
    private var state = PushPairingState()
    private var loaded = false
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(
        relay: PushRelayClient = PushRelayClient(), store: PushPairingStore, bundleID: String,
        environment: PushEnvironment
    ) {
        self.relay = relay
        self.store = store
        self.bundleID = bundleID
        self.environment = environment
    }

    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` data as lowercase hex.
    public static func hexToken(_ deviceToken: Data) -> String {
        deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    /// Call on every launch and whenever APNs issues a token. Registers on first use (or after
    /// a bundle change); otherwise PUTs, which also refreshes the relay's 90-day idle clock.
    /// A relay 401 re-registers once and clears every pairing record (the app should re-pair).
    /// - Throws: `PushPairingError`.
    public func updateDeviceToken(_ token: String) async throws {
        await acquire()
        defer { release() }
        try ensureLoaded()
        let token = token.lowercased()
        guard let id = state.installationID, let secret = state.installationSecret, state.bundleID == bundleID
        else {
            _ = try await registerFresh(token: token)
            return
        }
        do {
            try await relay.update(
                installationID: id, secret: secret, deviceToken: token,
                environment: state.environment == environment ? nil : environment)
        } catch PushRelayError.credentialInvalid {
            // Dead installation: forget it (and its pairings) before re-registering.
            state = PushPairingState(bundleID: state.bundleID, environment: state.environment, deviceToken: state.deviceToken)
            try persist()
            _ = try await registerFresh(token: token)
            return
        } catch let error as PushRelayError {
            throw PushPairingError.relay(error)
        }
        state.deviceToken = token
        state.environment = environment
        try persist()
    }

    /// Pairs this installation with `profile` on `server` (nil/"" = the server's launch profile),
    /// replacing any earlier pairing for the same server and profile.
    /// - Throws: `PushPairingError`.
    public func pair(
        server: HermesRESTClient, profile: String?, deviceName: String, preferences: PushPreferences? = nil
    ) async throws -> PushPairingRecord {
        await acquire()
        defer { release() }
        try ensureLoaded()
        guard let token = state.deviceToken else { throw PushPairingError.noDeviceToken }
        // freshCode registers when there's no installation and then uses that registration's code.
        var code = try await freshCode(token: token)
        let pairing: PushDevicePairing
        do {
            pairing = try await claim(server: server, profile: profile, code: code, deviceName: deviceName, preferences: preferences)
        } catch PushDevicesError.relayError(code: "pairing_code_invalid") {
            code = try await freshCode(token: token)
            do {
                pairing = try await claim(server: server, profile: profile, code: code, deviceName: deviceName, preferences: preferences)
            } catch let error as PushDevicesError {
                throw PushPairingError.devices(error)
            }
        } catch let error as PushDevicesError {
            throw PushPairingError.devices(error)
        }
        let record = PushPairingRecord(
            server: server.endpoint.key, profile: profile ?? "", deviceID: pairing.deviceID, pairedAt: Date())
        state.pairings.removeAll { $0.server == record.server && $0.profile == record.profile }
        state.pairings.append(record)
        try persist()
        return record
    }

    /// Asks Hermes whether our pairing for `profile` still exists and is active; drops the local
    /// record if not. No network call when there is no local record.
    /// - Throws: `PushPairingError`.
    public func syncPairing(server: HermesRESTClient, profile: String?) async throws -> PushPairingStatus {
        await acquire()
        defer { release() }
        try ensureLoaded()
        guard let record = record(server: server.endpoint.key, profile: profile) else { return .notPaired }
        let devices: [PushDevice]
        do {
            devices = try await server.pushDevices(profile: profile)
        } catch let error as PushDevicesError {
            throw PushPairingError.devices(error)
        }
        if let device = devices.first(where: { $0.deviceID == record.deviceID }), device.active {
            return .paired(device)
        }
        try remove(record)
        return .notPaired
    }

    /// Unpairs `profile` on `server`. The local record is removed even when Hermes can't be told:
    /// any error other than `deviceNotFound` (including `.unauthorized` and cancellation) yields
    /// `.unpairedLocallyOnly`.
    /// - Throws: `PushPairingError.storage` or `.storageUnavailable` only.
    public func unpair(server: HermesRESTClient, profile: String?) async throws -> PushUnpairResult {
        await acquire()
        defer { release() }
        try ensureLoaded()
        guard let record = record(server: server.endpoint.key, profile: profile) else { return .wasNotPaired }
        var result = PushUnpairResult.unpaired
        do {
            try await server.unpairPushDevice(profile: profile, deviceID: record.deviceID)
        } catch PushDevicesError.deviceNotFound {
            result = .unpaired
        } catch {
            result = .unpairedLocallyOnly
        }
        try remove(record)
        return result
    }

    /// Revokes the whole relay installation (every pairing, no Hermes server needed) and forgets it.
    /// The device token, bundle and environment are kept so `pair` can re-register right away.
    /// - Throws: `PushPairingError`.
    public func unpairAll() async throws {
        await acquire()
        defer { release() }
        try ensureLoaded()
        if let id = state.installationID, let secret = state.installationSecret {
            do {
                try await relay.delete(installationID: id, secret: secret)
            } catch PushRelayError.credentialInvalid {
                // already gone
            } catch let error as PushRelayError {
                throw PushPairingError.relay(error)
            }
        }
        state = PushPairingState(
            bundleID: state.bundleID, environment: state.environment, deviceToken: state.deviceToken)
        try persist()
    }

    /// The cached pairings, or `[]` when the Keychain hasn't been readable yet. Tries to load
    /// if nothing has loaded, ignoring errors.
    public func pairings() -> [PushPairingRecord] {
        try? ensureLoaded()
        return state.pairings
    }

    /// The pairing a notification's `PushPayload.deviceID` belongs to, or nil when none matches
    /// or the Keychain hasn't been readable yet. An unsynchronised read, like `pairings()`.
    public func pairing(forDeviceID deviceID: String) -> PushPairingRecord? {
        try? ensureLoaded()
        return state.pairings.first { $0.deviceID == deviceID }
    }

    /// Whether a pairing is cached; false when the Keychain hasn't been readable yet.
    public func isPaired(server: ServerEndpoint, profile: String?) -> Bool {
        try? ensureLoaded()
        return record(server: server.key, profile: profile) != nil
    }

    // MARK: Internals

    /// Reads the Keychain once it succeeds; each call retries until then. Never treats an
    /// unreadable item as empty. - Throws: `PushPairingError.storageUnavailable`.
    private func ensureLoaded() throws {
        guard !loaded else { return }
        do {
            state = try store.load()
            loaded = true
        } catch PushPairingStoreError.readFailed(let status) {
            throw PushPairingError.storageUnavailable(status)
        } catch {
            throw PushPairingError.storageUnavailable(errSecInternalError)
        }
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }  // ownership is handed over on resume
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    private func record(server: String, profile: String?) -> PushPairingRecord? {
        state.pairings.first { $0.server == server && $0.profile == (profile ?? "") }
    }

    private func remove(_ record: PushPairingRecord) throws {
        state.pairings.removeAll { $0 == record }
        try persist()
    }

    /// New installation for `token`; clears every pairing (they belonged to the old installation).
    private func registerFresh(token: String) async throws -> PushRegistration {
        let registration: PushRegistration
        do {
            registration = try await relay.register(bundleID: bundleID, deviceToken: token, environment: environment)
        } catch let error as PushRelayError {
            throw PushPairingError.relay(error)
        }
        state = PushPairingState(
            installationID: registration.installationID, installationSecret: registration.installationSecret,
            bundleID: bundleID, environment: environment, deviceToken: token, pairings: [])
        try persist()
        return registration
    }

    /// A fresh pairing code; a relay 401 (installation pruned) re-registers once and uses that code.
    private func freshCode(token: String) async throws -> PushPairingCode {
        guard let id = state.installationID, let secret = state.installationSecret else {
            return try await registerFresh(token: token).pairingCode
        }
        do {
            return try await relay.newPairingCode(installationID: id, secret: secret)
        } catch PushRelayError.credentialInvalid {
            return try await registerFresh(token: token).pairingCode
        } catch let error as PushRelayError {
            throw PushPairingError.relay(error)
        }
    }

    private func claim(
        server: HermesRESTClient, profile: String?, code: PushPairingCode, deviceName: String,
        preferences: PushPreferences?
    ) async throws -> PushDevicePairing {
        guard let id = state.installationID else { throw PushPairingError.relay(.credentialInvalid) }
        return try await server.pairPushDevice(
            profile: profile, installationID: id, pairingCode: code.code, deviceName: deviceName,
            preferences: preferences)
    }

    private func persist() throws {
        do {
            try store.save(state)
        } catch let error as KeychainError {
            throw PushPairingError.storage(error)
        } catch {
            throw PushPairingError.storage(.encodingFailed)
        }
    }
}
