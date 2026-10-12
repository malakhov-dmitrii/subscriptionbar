import Foundation

/// Per-account spacing after a usage service answers 429: the interval doubles on
/// every refusal, halves after every success, and pacing ends once it would be
/// shorter than a minute.
public struct UsagePacing: Sendable, Equatable {
    public static let minimum: TimeInterval = 60
    public static let maximum: TimeInterval = 900
    /// An explicit Retry-After is honoured beyond `maximum`, up to this ceiling.
    public static let serverCeiling: TimeInterval = 3600

    public let interval: TimeInterval
    public let nextFetch: Date

    public static func refused(_ current: UsagePacing?, retryAfter: TimeInterval?, now: Date) -> UsagePacing {
        let doubled = min(maximum, (current?.interval ?? minimum) * 2)
        let interval = min(serverCeiling, max(doubled, retryAfter ?? 0))
        return UsagePacing(interval: interval, nextFetch: now.addingTimeInterval(interval))
    }

    public static func succeeded(_ current: UsagePacing?, now: Date) -> UsagePacing? {
        guard let current, current.interval / 2 >= minimum else { return nil }
        let interval = current.interval / 2
        return UsagePacing(interval: interval, nextFetch: now.addingTimeInterval(interval))
    }

    public func allowsFetch(at now: Date) -> Bool { now >= nextFetch }
}

public enum ReadingState: Sendable, Equatable {
    case current, delayed, unavailable
}

/// What the interface may show for one account. Automatic switching does not use
/// this: it keeps requiring `UsageSnapshot.isFresh`.
public enum ReadingFreshness {
    /// A paced reading this young is the newest one the app intends to have.
    public static let pacedCurrent: TimeInterval = 300
    /// Older paced readings are still shown, marked as delayed, up to this age.
    public static let pacedDelayed: TimeInterval = 1800

    public static func state(_ snapshot: UsageSnapshot?, failed: Bool, paced: Bool, now: Date) -> ReadingState {
        guard !failed, let snapshot else { return .unavailable }
        if snapshot.isFresh(at: now) { return .current }
        guard paced else { return .unavailable }
        if snapshot.isFresh(at: now, maxAge: pacedCurrent) { return .current }
        if snapshot.isFresh(at: now, maxAge: pacedDelayed) { return .delayed }
        return .unavailable
    }
}
