import Foundation
import Security
import Testing

@testable import MercuryKit

@Suite("PushPairingStore")
struct PushPairingStoreTests {
    static let service = "com.test.push"

    static func sample() -> PushPairingState {
        PushPairingState(
            installationID: "inst_1", installationSecret: "s3cret", bundleID: "com.spencermcguire.mercurychat",
            environment: .sandbox, deviceToken: String(repeating: "ab", count: 32),
            pairings: [PushPairingRecord(
                server: "https://hermes.example:443", profile: "coder", deviceID: "dev_1",
                pairedAt: Date(timeIntervalSince1970: 1_790_000_000))])
    }

    @Test func roundTrips() throws {
        let keychain = InMemoryKeychain()
        let store = PushPairingStore(service: Self.service, calls: keychain.calls, read: keychain.read)
        #expect(try store.load() == PushPairingState())
        try store.save(Self.sample())
        #expect(try store.load() == Self.sample())
        var changed = Self.sample()
        changed.deviceToken = String(repeating: "cd", count: 32)
        try store.save(changed)  // update path
        #expect(try store.load() == changed)
        try store.clear()
        #expect(try store.load() == PushPairingState())
        try store.clear()  // clearing a missing item is success
    }

    @Test func itemIsDeviceOnlyAndNeverSynchronizable() throws {
        let keychain = InMemoryKeychain()
        try PushPairingStore(service: Self.service, calls: keychain.calls, read: keychain.read).save(Self.sample())
        let attributes = keychain.lastAddAttributes
        #expect(attributes[kSecAttrAccount as String] as? String == "mercury-push")
        #expect(attributes[kSecAttrService as String] as? String == Self.service)
        #expect(attributes[kSecAttrAccessible as String] as? String
            == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(attributes[kSecAttrSynchronizable as String] == nil)
    }

    @Test func corruptItemLoadsAsEmpty() throws {
        let keychain = InMemoryKeychain()
        keychain.put(service: Self.service, account: "mercury-push", value: Data("not json".utf8))
        #expect(try PushPairingStore(service: Self.service, calls: keychain.calls, read: keychain.read).load()
            == PushPairingState())
    }

    @Test func unreadableKeychainThrowsInsteadOfLoadingEmpty() throws {
        let keychain = InMemoryKeychain()
        let store = PushPairingStore(service: Self.service, calls: keychain.calls, read: keychain.read)
        try store.save(Self.sample())
        keychain.failReads = errSecInteractionNotAllowed
        #expect(throws: PushPairingStoreError.readFailed(errSecInteractionNotAllowed)) { try store.load() }
        keychain.failReads = nil
        #expect(try store.load() == Self.sample())
    }

    @Test func readFailureDescriptionCarriesNoData() {
        let text = PushPairingStoreError.readFailed(errSecInteractionNotAllowed).errorDescription ?? ""
        #expect(!text.isEmpty)
        #expect(!text.contains("s3cret"))
    }

    @Test func writeFailuresThrowKeychainError() {
        let keychain = InMemoryKeychain()
        keychain.failWrites = errSecInteractionNotAllowed
        let store = PushPairingStore(service: Self.service, calls: keychain.calls, read: keychain.read)
        #expect(throws: KeychainError.writeFailed(errSecInteractionNotAllowed)) { try store.save(Self.sample()) }
    }

    @Test func dumpAndMirrorRedactSecrets() {
        let state = Self.sample()
        let registration = PushRegistration(
            installationID: "inst_1", installationSecret: "s3cret",
            pairingCode: PushPairingCode(code: "ABCDE-FGHJK", expiresAt: Date(timeIntervalSince1970: 0)))
        var dumped = ""
        dump(state, to: &dumped)
        dump(registration, to: &dumped)
        dump(registration.pairingCode, to: &dumped)
        #expect(!dumped.contains("s3cret"))
        #expect(!dumped.contains("ABCDE-FGHJK"))
        #expect(dumped.contains("<redacted>"))
        func flatten(_ value: Any) -> String {
            Mirror(reflecting: value).children.map { "\($0.label ?? ""):\($0.value)" }.joined(separator: "|")
        }
        for value in [state as Any, registration, registration.pairingCode] {
            let text = flatten(value)
            #expect(!text.contains("s3cret"))
            #expect(!text.contains("ABCDE-FGHJK"))
        }
    }

    @Test func descriptionsRedactTheSecret() {
        let state = Self.sample()
        #expect(!String(describing: state).contains("s3cret"))
        #expect(!String(reflecting: state).contains("s3cret"))
        #expect(String(describing: state).contains("inst_1"))
    }
}
