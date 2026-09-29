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
                let data = items[Self.key(query as? [String: Any] ?? [:])]
                return (data == nil ? errSecItemNotFound : errSecSuccess, data)
            }
        }
    }
}
