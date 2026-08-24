import Foundation
import LiraCore

/// Deterministic clock for timeout tests. Not used in production.
final class TestClock: LifecycleClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.current = now
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current.addTimeInterval(interval)
    }
}
