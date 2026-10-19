/// Where a stroke came from.
///
/// The source is recorded on strokes and events for diagnostics, but it is never
/// part of stroke identity.
public enum PenSource: String, Hashable, Sendable, Codable, CaseIterable {
    /// Streamed from the pen while it is connected.
    case live

    /// Retrieved from the pen's offline storage.
    case offline
}

/// The pen-origin start time of a stroke.
///
/// The pen reports stroke start times in milliseconds on its own clock. A pen
/// whose clock is not set, or a capture path that never observed a start time,
/// produces an unreliable origin. Strokes with an unreliable origin are kept but
/// must not be deduplicated across sources, because two different marks would
/// otherwise collapse into one.
public enum PenOriginTime: Hashable, Sendable, Codable {
    /// The pen reported a trustworthy stroke start time in pen milliseconds.
    case reliable(milliseconds: Int64)

    /// The stroke start time is absent or not trustworthy.
    ///
    /// - Parameter reportedMilliseconds: The value the pen sent, when it sent
    ///   one. It is retained for diagnostics and is not used for deduplication.
    case unreliable(reportedMilliseconds: Int64?)

    /// Whether this origin may be used for cross-source deduplication.
    public var isReliable: Bool {
        if case .reliable = self {
            return true
        }
        return false
    }

    /// The trustworthy pen-origin time in milliseconds, when one exists.
    public var reliableMilliseconds: Int64? {
        if case .reliable(let milliseconds) = self {
            return milliseconds
        }
        return nil
    }

    /// The value the pen reported, whether or not it is trustworthy.
    public var reportedMilliseconds: Int64? {
        switch self {
        case .reliable(let milliseconds):
            return milliseconds
        case .unreliable(let reportedMilliseconds):
            return reportedMilliseconds
        }
    }
}

/// The event phase of a normalized pen event.
public enum PenEventPhase: String, Hashable, Sendable, Codable, CaseIterable {
    /// The pen tip touched the page.
    case down

    /// The pen tip moved while touching the page.
    case move

    /// The pen tip left the page.
    case up
}

/// Page, origin time, and source shared by the events of one stroke.
public struct PenEventContext: Hashable, Sendable, Codable {
    /// The page the event belongs to.
    public let page: PageIdentity

    /// The stroke's pen-origin start time.
    public let originTime: PenOriginTime

    /// Where the event came from.
    public let source: PenSource

    public init(page: PageIdentity, originTime: PenOriginTime, source: PenSource) {
        self.page = page
        self.originTime = originTime
        self.source = source
    }
}

/// A normalized pen event, independent of the transport that delivered it.
public struct PenEvent: Hashable, Sendable, Codable {
    /// Page, origin time, and source for this event.
    public let context: PenEventContext

    /// The event phase.
    public let phase: PenEventPhase

    /// The normalized point, or `nil` when the event carries no coordinates.
    public let point: PenPoint?

    public init(context: PenEventContext, phase: PenEventPhase, point: PenPoint?) {
        self.context = context
        self.phase = phase
        self.point = point
    }
}
