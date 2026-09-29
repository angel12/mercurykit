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
        let state = h.store.load()
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
        let id = try #require(h.store.load().installationID)
        #expect(h.backend.installationCount == 1)
        #expect(h.backend.log.filter { $0.hasPrefix("PUT") }.count == 2)
        #expect(h.backend.installation(id)?.token == Self.tokenB)
    }

    @Test func environmentChangeIsSent() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        try await h.coordinator(environment: .sandbox).updateDeviceToken(Self.tokenA)
        try await h.coordinator(environment: .production).updateDeviceToken(Self.tokenA)
        let id = try #require(h.store.load().installationID)
        #expect(h.backend.installation(id)?.environment == "production")
        #expect(h.store.load().environment == .production)
    }

    @Test func bundleChangeReregistersAndClearsPairings() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        let chat = h.coordinator()
        try await chat.updateDeviceToken(Self.tokenA)
        _ = try await chat.pair(server: h.hermes, profile: "coder", deviceName: "iPhone")
        let first = try #require(h.store.load().installationID)
        try await h.coordinator(bundle: "com.spencermcguire.mercuryvoice.app").updateDeviceToken(Self.tokenA)
        let state = h.store.load()
        #expect(state.installationID != first)
        #expect(state.bundleID == "com.spencermcguire.mercuryvoice.app")
        #expect(state.pairings.isEmpty)
    }

    @Test func putUnauthorizedReregistersAndClearsPairings() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        let pairing = h.coordinator()
        try await pairing.updateDeviceToken(Self.tokenA)
        _ = try await pairing.pair(server: h.hermes, profile: "coder", deviceName: "iPhone")
        let first = try #require(h.store.load().installationID)
        h.backend.failNextPutWith401 = true
        try await pairing.updateDeviceToken(Self.tokenA)
        let state = h.store.load()
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
        let first = try #require(h.store.load().installationID)
        h.backend.failNextNewCodeWith401 = true
        let record = try await pairing.pair(server: h.hermes, profile: "coder", deviceName: "iPhone")
        let state = h.store.load()
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
        #expect(h.store.load().pairings.isEmpty)
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
        let id = try #require(h.store.load().installationID)
        try await pairing.unpairAll()
        #expect(h.backend.installation(id) == nil)
        let state = h.store.load()
        #expect(state.installationID == nil)
        #expect(state.installationSecret == nil)
        #expect(state.pairings.isEmpty)
        #expect(state.deviceToken == Self.tokenA)
        // pairing again re-registers without a new token
        let record = try await pairing.pair(server: h.hermes, profile: "coder", deviceName: "iPhone")
        #expect(h.store.load().pairings == [record])
        // an installation the relay already dropped is fine (relay 401 → treated as gone)
        h.backend.dropInstallation(try #require(h.store.load().installationID))
        try await pairing.unpairAll()
        #expect(h.store.load().installationID == nil)
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
        try await h.coordinator().updateDeviceToken(Self.tokenA)
        let secret = try #require(h.store.load().installationSecret)
        let errors: [PushPairingError] = [
            .noDeviceToken, .relay(.credentialInvalid), .devices(.relayError(code: "x")),
            .storage(.encodingFailed),
        ]
        for error in errors {
            #expect(!(error.errorDescription ?? "").contains(secret))
            #expect(!String(describing: error).contains(secret))
        }
    }
}
