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
        #expect(store.load() == PushPairingState())
        try store.save(Self.sample())
        #expect(store.load() == Self.sample())
        var changed = Self.sample()
        changed.deviceToken = String(repeating: "cd", count: 32)
        try store.save(changed)  // update path
        #expect(store.load() == changed)
        try store.clear()
        #expect(store.load() == PushPairingState())
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

    @Test func corruptItemLoadsAsEmpty() {
        let keychain = InMemoryKeychain()
        keychain.put(service: Self.service, account: "mercury-push", value: Data("not json".utf8))
        #expect(PushPairingStore(service: Self.service, calls: keychain.calls, read: keychain.read).load()
            == PushPairingState())
    }

    @Test func writeFailuresThrowKeychainError() {
        let keychain = InMemoryKeychain()
        keychain.failWrites = errSecInteractionNotAllowed
        let store = PushPairingStore(service: Self.service, calls: keychain.calls, read: keychain.read)
        #expect(throws: KeychainError.writeFailed(errSecInteractionNotAllowed)) { try store.save(Self.sample()) }
    }

    @Test func descriptionsRedactTheSecret() {
        let state = Self.sample()
        #expect(!String(describing: state).contains("s3cret"))
        #expect(!String(reflecting: state).contains("s3cret"))
        #expect(String(describing: state).contains("inst_1"))
    }
}
