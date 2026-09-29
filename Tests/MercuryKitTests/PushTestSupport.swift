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
