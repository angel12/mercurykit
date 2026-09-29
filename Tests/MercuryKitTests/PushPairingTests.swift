import Foundation
import Testing

@testable import MercuryKit

@Suite("PushPairing", .timeLimit(.minutes(1)))
struct PushPairingTests {
    static let bundle = "com.spencermcguire.mercurychat"
    static let tokenA = String(repeating: "ab", count: 32)
    static let tokenB = String(repeating: "cd", count: 32)

    struct Harness {
        let backend: FakePushBackend
        let server: RoutedHTTPServer
        let keychain: InMemoryKeychain
        let store: PushPairingStore
        let hermes: HermesRESTClient

        func coordinator(bundle: String = PushPairingTests.bundle, environment: PushEnvironment = .sandbox) -> PushPairing {
            PushPairing(relay: PushRelayClient(baseURL: pushTestURL(port: server.port)), store: store,
                        bundleID: bundle, environment: environment)
        }
    }

    static func harness() async throws -> Harness {
        let backend = FakePushBackend()
        let server = try await RoutedHTTPServer.start { backend.handle($0) }
        let keychain = InMemoryKeychain()
        let store = PushPairingStore(service: "com.test.push", calls: keychain.calls, read: keychain.read)
        let hermes = HermesRESTClient(
            endpoint: try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint, token: "tok")
        return Harness(backend: backend, server: server, keychain: keychain, store: store, hermes: hermes)
    }

    @Test func hexTokenIsLowercaseHex() {
        #expect(PushPairing.hexToken(Data([0x00, 0xAB, 0xff, 0x10])) == "00abff10")
    }

    @Test func firstTokenRegistersAndPersists() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        try await h.coordinator().updateDeviceToken(Self.tokenA.uppercased())
        let state = (try h.store.load())
        let id = try #require(state.installationID)
        #expect(h.backend.installation(id)?.token == Self.tokenA)  // lowercased
        #expect(state.bundleID == Self.bundle)
        #expect(state.environment == .sandbox)
        #expect(state.deviceToken == Self.tokenA)
    }

    @Test func laterTokensPutEvenWhenUnchanged() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        let pairing = h.coordinator()
        try await pairing.updateDeviceToken(Self.tokenA)
        try await pairing.updateDeviceToken(Self.tokenA)
        try await pairing.updateDeviceToken(Self.tokenB)
        let id = try #require((try h.store.load()).installationID)
        #expect(h.backend.installationCount == 1)
        #expect(h.backend.log.filter { $0.hasPrefix("PUT") }.count == 2)
        #expect(h.backend.installation(id)?.token == Self.tokenB)
    }

    @Test func environmentChangeIsSent() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        try await h.coordinator(environment: .sandbox).updateDeviceToken(Self.tokenA)
        try await h.coordinator(environment: .production).updateDeviceToken(Self.tokenA)
        let id = try #require((try h.store.load()).installationID)
        #expect(h.backend.installation(id)?.environment == "production")
        #expect((try h.store.load()).environment == .production)
    }

    @Test func bundleChangeReregistersAndClearsPairings() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        let chat = h.coordinator()
        try await chat.updateDeviceToken(Self.tokenA)
        _ = try await chat.pair(server: h.hermes, profile: "coder", deviceName: "iPhone")
        let first = try #require((try h.store.load()).installationID)
        try await h.coordinator(bundle: "com.spencermcguire.mercuryvoice.app").updateDeviceToken(Self.tokenA)
        let state = (try h.store.load())
        #expect(state.installationID != first)
        #expect(state.bundleID == "com.spencermcguire.mercuryvoice.app")
        #expect(state.pairings.isEmpty)
    }

    @Test func putUnauthorizedReregistersAndClearsPairings() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        let pairing = h.coordinator()
        try await pairing.updateDeviceToken(Self.tokenA)
        _ = try await pairing.pair(server: h.hermes, profile: "coder", deviceName: "iPhone")
        let first = try #require((try h.store.load()).installationID)
        h.backend.failNextPutWith401 = true
        try await pairing.updateDeviceToken(Self.tokenA)
        let state = (try h.store.load())
        #expect(state.installationID != first)
        #expect(state.pairings.isEmpty)
        #expect(await pairing.pairings().isEmpty)
    }

    @Test func pairWithoutTokenThrows() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        await #expect(throws: PushPairingError.noDeviceToken) {
            _ = try await h.coordinator().pair(server: h.hermes, profile: nil, deviceName: "iPhone")
        }
    }

    @Test func pairRecordsPerServerAndProfileAndReplaces() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        let pairing = h.coordinator()
        try await pairing.updateDeviceToken(Self.tokenA)
        let coder = try await pairing.pair(server: h.hermes, profile: "coder", deviceName: "iPhone")
        let launch = try await pairing.pair(server: h.hermes, profile: nil, deviceName: "iPhone")
        let again = try await pairing.pair(server: h.hermes, profile: "coder", deviceName: "iPhone")
        #expect(coder.profile == "coder")
        #expect(launch.profile == "")
        #expect(coder.server == h.hermes.endpoint.key)
        #expect(await pairing.pairings().count == 2)
        #expect(await pairing.pairings().contains(again))
        #expect(!(await pairing.pairings().contains(coder)))
        #expect(await pairing.isPaired(server: h.hermes.endpoint, profile: "coder"))
        #expect(!(await pairing.isPaired(server: h.hermes.endpoint, profile: "other")))
        #expect(h.backend.log.contains { $0.hasPrefix("POST /api/plugins/mercury_push/devices?profile=coder") })
    }

    @Test func pairRetriesOnceWithFreshCode() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        let pairing = h.coordinator()
        try await pairing.updateDeviceToken(Self.tokenA)
        h.backend.expireNextCodeOnClaim = true
        let record = try await pairing.pair(server: h.hermes, profile: "coder", deviceName: "iPhone")
        #expect(h.backend.device(record.deviceID)?.profile == "coder")
        #expect(h.backend.log.filter { $0.hasSuffix("/pairing-codes") }.count == 2)
    }

    @Test func pairReregistersWhenInstallationWasPruned() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        let pairing = h.coordinator()
        try await pairing.updateDeviceToken(Self.tokenA)
        let first = try #require((try h.store.load()).installationID)
        h.backend.failNextNewCodeWith401 = true
        let record = try await pairing.pair(server: h.hermes, profile: "coder", deviceName: "iPhone")
        let state = (try h.store.load())
        #expect(state.installationID != first)
        #expect(state.pairings == [record])
    }

    @Test func pairSurfacesPluginErrors() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        let pairing = h.coordinator()
        try await pairing.updateDeviceToken(Self.tokenA)
        h.backend.pluginStatusOverride = (409, #"{"error":"plugin_not_enabled","profile":"off"}"#)
        await #expect(throws: PushPairingError.devices(.pluginNotEnabled(profile: "off"))) {
            _ = try await pairing.pair(server: h.hermes, profile: "off", deviceName: "iPhone")
        }
        #expect(await pairing.pairings().isEmpty)
    }

    @Test func syncDropsMissingOrInactiveDevices() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        let pairing = h.coordinator()
        try await pairing.updateDeviceToken(Self.tokenA)
        #expect(try await pairing.syncPairing(server: h.hermes, profile: "coder") == .notPaired)  // no record: no call
        let record = try await pairing.pair(server: h.hermes, profile: "coder", deviceName: "iPhone")
        guard case .paired(let device) = try await pairing.syncPairing(server: h.hermes, profile: "coder") else {
            Issue.record("expected paired"); return
        }
        #expect(device.deviceID == record.deviceID)
        h.backend.deactivate(record.deviceID)
        #expect(try await pairing.syncPairing(server: h.hermes, profile: "coder") == .notPaired)
        #expect(await pairing.pairings().isEmpty)

        let second = try await pairing.pair(server: h.hermes, profile: "coder", deviceName: "iPhone")
        h.backend.removeDevice(second.deviceID)
        #expect(try await pairing.syncPairing(server: h.hermes, profile: "coder") == .notPaired)
        #expect((try h.store.load()).pairings.isEmpty)
    }

    @Test func unpairOutcomes() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        let pairing = h.coordinator()
        try await pairing.updateDeviceToken(Self.tokenA)
        #expect(try await pairing.unpair(server: h.hermes, profile: "coder") == .wasNotPaired)

        let record = try await pairing.pair(server: h.hermes, profile: "coder", deviceName: "iPhone")
        #expect(try await pairing.unpair(server: h.hermes, profile: "coder") == .unpaired)
        #expect(h.backend.device(record.deviceID) == nil)

        _ = try await pairing.pair(server: h.hermes, profile: "coder", deviceName: "iPhone")
        h.backend.pluginStatusOverride = (500, #"{"detail":"boom"}"#)
        #expect(try await pairing.unpair(server: h.hermes, profile: "coder") == .unpairedLocallyOnly)
        #expect(await pairing.pairings().isEmpty)
    }

    @Test func unpairTreatsDeviceNotFoundAsUnpaired() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        let pairing = h.coordinator()
        try await pairing.updateDeviceToken(Self.tokenA)
        let record = try await pairing.pair(server: h.hermes, profile: "coder", deviceName: "iPhone")
        h.backend.removeDevice(record.deviceID)
        #expect(try await pairing.unpair(server: h.hermes, profile: "coder") == .unpaired)
    }

    @Test func unpairAllRevokesInstallationButKeepsToken() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        let pairing = h.coordinator()
        try await pairing.updateDeviceToken(Self.tokenA)
        _ = try await pairing.pair(server: h.hermes, profile: "coder", deviceName: "iPhone")
        let id = try #require((try h.store.load()).installationID)
        try await pairing.unpairAll()
        #expect(h.backend.installation(id) == nil)
        let state = (try h.store.load())
        #expect(state.installationID == nil)
        #expect(state.installationSecret == nil)
        #expect(state.pairings.isEmpty)
        #expect(state.deviceToken == Self.tokenA)
        // pairing again re-registers without a new token
        let record = try await pairing.pair(server: h.hermes, profile: "coder", deviceName: "iPhone")
        #expect((try h.store.load()).pairings == [record])
        // an installation the relay already dropped is fine (relay 401 → treated as gone)
        h.backend.dropInstallation(try #require((try h.store.load()).installationID))
        try await pairing.unpairAll()
        #expect((try h.store.load()).installationID == nil)
    }

    @Test func storageFailureSurfaces() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        h.keychain.failWrites = errSecInteractionNotAllowed
        await #expect(throws: PushPairingError.storage(.writeFailed(errSecInteractionNotAllowed))) {
            try await h.coordinator().updateDeviceToken(Self.tokenA)
        }
    }

    @Test func errorDescriptionsNeverContainSecrets() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        let pairing = h.coordinator()
        try await pairing.updateDeviceToken(Self.tokenA)
        let secret = try #require((try h.store.load()).installationSecret)
        var caught: [PushPairingError] = []
        h.backend.failNextPutWith500 = true
        do { try await pairing.updateDeviceToken(Self.tokenA) } catch let e as PushPairingError { caught.append(e) }
        h.backend.pluginStatusOverride = (409, #"{"error":"plugin_not_enabled","profile":"x"}"#)
        do { _ = try await pairing.pair(server: h.hermes, profile: "x", deviceName: "iPhone") } catch let e as PushPairingError { caught.append(e) }
        #expect(caught.count == 2)
        let code = "CODE_"  // fake codes are all CODE_<n>
        for error in caught {
            for text in [error.errorDescription ?? "", String(describing: error)] {
                #expect(!text.contains(secret))
                #expect(!text.contains(code))
            }
        }
    }

    @Test func concurrentTokenUpdatesRegisterOnce() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        let pairing = h.coordinator()
        async let a: Void = pairing.updateDeviceToken(Self.tokenA)
        async let b: Void = pairing.updateDeviceToken(Self.tokenA)
        _ = try await (a, b)
        #expect(h.backend.installationCount == 1)
    }

    @Test func concurrentPairsBothRecorded() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        let pairing = h.coordinator()
        try await pairing.updateDeviceToken(Self.tokenA)
        async let a = pairing.pair(server: h.hermes, profile: "a", deviceName: "iPhone")
        async let b = pairing.pair(server: h.hermes, profile: "b", deviceName: "iPhone")
        _ = try await (a, b)
        #expect(await pairing.pairings().count == 2)
        #expect((try h.store.load()).pairings.count == 2)
    }

    @Test func pairAndUnpairAllStayConsistent() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        let pairing = h.coordinator()
        try await pairing.updateDeviceToken(Self.tokenA)
        async let p = pairing.pair(server: h.hermes, profile: "a", deviceName: "iPhone")
        async let u: Void = pairing.unpairAll()
        _ = try await (p, u)
        let state = (try h.store.load())
        if state.pairings.isEmpty {
            #expect(state.installationID == nil)
        } else {
            #expect(state.installationID != nil)
        }
        #expect(!(state.installationID == nil && !state.pairings.isEmpty))
    }

    @Test func failedReregistrationLeavesNoStalePairings() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        let pairing = h.coordinator()
        try await pairing.updateDeviceToken(Self.tokenA)
        _ = try await pairing.pair(server: h.hermes, profile: "coder", deviceName: "iPhone")
        h.backend.failNextPutWith401 = true
        h.backend.failNextRegisterWith500 = true
        do {
            try await pairing.updateDeviceToken(Self.tokenA)
            Issue.record("expected throw")
        } catch let error as PushPairingError {
            guard case .relay = error else { Issue.record("expected .relay, got \(error)"); return }
        }
        #expect(await pairing.pairings().isEmpty)
        #expect((try h.store.load()).installationID == nil)
        #expect((try h.store.load()).pairings.isEmpty)
    }

    // MARK: Unreadable Keychain

    @Test func unreadableKeychainNeverRegistersOrOverwrites() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        try await h.coordinator().updateDeviceToken(Self.tokenA)
        let stored = try #require(h.keychain.storedValue(service: "com.test.push", account: "mercury-push"))
        let id = try #require((try h.store.load()).installationID)
        let before = h.backend.log.count

        let pairing = h.coordinator()  // fresh process: Keychain locked before first unlock
        h.keychain.failReads = errSecInteractionNotAllowed
        let locked = PushPairingError.storageUnavailable(errSecInteractionNotAllowed)
        await #expect(throws: locked) { try await pairing.updateDeviceToken(Self.tokenB) }
        await #expect(throws: locked) { _ = try await pairing.pair(server: h.hermes, profile: "coder", deviceName: "iPhone") }
        await #expect(throws: locked) { _ = try await pairing.syncPairing(server: h.hermes, profile: nil) }
        await #expect(throws: locked) { _ = try await pairing.unpair(server: h.hermes, profile: nil) }
        await #expect(throws: locked) { try await pairing.unpairAll() }
        #expect(await pairing.pairings().isEmpty)
        #expect(!(await pairing.isPaired(server: h.hermes.endpoint, profile: nil)))

        #expect(h.backend.log.count == before)  // no network calls at all
        #expect(!h.backend.log.dropFirst(before).contains { $0 == "POST /v1/installations" })
        #expect(h.keychain.storedValue(service: "com.test.push", account: "mercury-push") == stored)

        h.keychain.failReads = nil  // unlocked: the next call retries the read and reuses the installation
        try await pairing.updateDeviceToken(Self.tokenB)
        #expect(h.backend.log.dropFirst(before).map { $0.components(separatedBy: "?")[0] } == ["PUT /v1/installations/\(id)"])
        #expect(h.backend.installationCount == 1)
        #expect(h.backend.installation(id)?.token == Self.tokenB)
    }

    @Test func storageUnavailableDescriptionCarriesNoData() {
        let text = PushPairingError.storageUnavailable(errSecInteractionNotAllowed).errorDescription ?? ""
        #expect(!text.isEmpty)
    }

    // MARK: Pair details

    @Test func deviceNameIsClampedTo64Scalars() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        let pairing = h.coordinator()
        try await pairing.updateDeviceToken(Self.tokenA)
        let long = String(repeating: "\u{1F600}", count: 70)
        _ = try await pairing.pair(server: h.hermes, profile: nil, deviceName: long)
        #expect(h.backend.lastDeviceName?.unicodeScalars.count == 64)
        #expect(h.backend.lastDeviceName == String(long.unicodeScalars.prefix(64)))
        _ = try await pairing.pair(server: h.hermes, profile: nil, deviceName: "iPhone")
        #expect(h.backend.lastDeviceName == "iPhone")
    }

    @Test func pairWithoutInstallationUsesRegistrationCode() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        let pairing = h.coordinator()
        try await pairing.updateDeviceToken(Self.tokenA)
        try await pairing.unpairAll()
        let before = h.backend.log.count
        _ = try await pairing.pair(server: h.hermes, profile: "coder", deviceName: "iPhone")
        let calls = h.backend.log.dropFirst(before)
        #expect(calls.filter { $0 == "POST /v1/installations" }.count == 1)
        #expect(calls.filter { $0.hasSuffix("/pairing-codes") }.isEmpty)
    }

    @Test func pairingForDeviceIDFindsServerAndProfile() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        let pairing = h.coordinator()
        try await pairing.updateDeviceToken(Self.tokenA)
        let coder = try await pairing.pair(server: h.hermes, profile: "coder", deviceName: "iPhone")
        let launch = try await pairing.pair(server: h.hermes, profile: nil, deviceName: "iPhone")
        #expect(await pairing.pairing(forDeviceID: coder.deviceID) == coder)
        #expect(await pairing.pairing(forDeviceID: launch.deviceID)?.profile == "")
        #expect(await pairing.pairing(forDeviceID: coder.deviceID)?.server == h.hermes.endpoint.key)
        #expect(await pairing.pairing(forDeviceID: "dev_unknown") == nil)
    }

    @Test func pairingForDeviceIDIsNilWhileKeychainUnreadable() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        let first = h.coordinator()
        try await first.updateDeviceToken(Self.tokenA)
        let record = try await first.pair(server: h.hermes, profile: "coder", deviceName: "iPhone")
        h.keychain.failReads = errSecInteractionNotAllowed
        let fresh = h.coordinator()  // new instance: nothing cached yet
        #expect(await fresh.pairing(forDeviceID: record.deviceID) == nil)
        h.keychain.failReads = nil
        #expect(await fresh.pairing(forDeviceID: record.deviceID) == record)
    }
}
