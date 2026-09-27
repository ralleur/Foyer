import Foundation

/// Minimal clock abstraction so time-dependent logic can be unit tested.
public protocol Clock: Sendable {
    var now: Date { get }
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}

public final class ManualClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        current = start
    }

    public var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}
