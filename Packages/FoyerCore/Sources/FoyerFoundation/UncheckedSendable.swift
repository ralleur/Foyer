import Foundation

/// Wraps a reference type that is documented as thread-safe (e.g. DateFormatter for
/// formatting, NSRegularExpression) so it can be stored in a static without Sendable warnings.
public struct UncheckedSendable<Value>: @unchecked Sendable {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}
