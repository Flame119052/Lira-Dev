import Foundation

/// Wall-clock source for deadline checks. Injected so tests can cross a
/// deadline without waiting and without a background timer thread.
///
/// Named `LifecycleClock` because Swift's standard library already has `Clock`.
public protocol LifecycleClock: Sendable {
    var now: Date { get }
}

/// Production clock: `Date()`.
public struct SystemClock: LifecycleClock, Sendable {
    public init() {}
    public var now: Date { Date() }
}
