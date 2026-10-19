/// A reason the assembler refused an event sequence.
public enum StrokeSequenceError: Error, Hashable, Sendable {
    /// A point arrived while no stroke was open.
    case pointBeforeDown(page: PageIdentity)

    /// An event for a different page arrived while a stroke was open.
    case pageChangedDuringStroke(openPage: PageIdentity, eventPage: PageIdentity)

    /// An up event arrived while no stroke was open.
    case upWithoutDown(page: PageIdentity)

    /// A down event arrived while another stroke was still open.
    case downWhileStrokeOpen(openPage: PageIdentity, eventPage: PageIdentity)
}

/// The result of feeding one event, or of finishing the stream, to the assembler.
public enum StrokeAssemblyOutcome: Hashable, Sendable {
    /// The event changed nothing observable.
    case ignored

    /// A down event opened a stroke.
    case opened

    /// A point was appended to the open stroke.
    case extended

    /// An up event closed the stroke.
    case completed(Stroke)

    /// The stream ended while a stroke was still open.
    ///
    /// The stroke is retained, but it is not a completed stroke and must not be
    /// treated as one.
    case incomplete(Stroke)

    /// The event sequence was invalid and no completed stroke was produced.
    case invalid(StrokeSequenceError)
}

/// Assembles normalized pen events into strokes.
///
/// The assembler holds at most one open stroke. It rejects a point before a down
/// event and a page change during an open stroke, and it never reports a stroke
/// as completed without an up event.
public struct StrokeAssembler: Sendable {
    private struct OpenStroke {
        var page: PageIdentity
        var originTime: PenOriginTime
        var source: PenSource
        var points: [PenPoint]
    }

    private var open: OpenStroke?

    public init() {}

    /// Whether a stroke is currently open.
    public var hasOpenStroke: Bool {
        open != nil
    }

    /// Feeds one event to the assembler.
    ///
    /// When the outcome is `invalid`, the open stroke is discarded and the
    /// assembler is ready for a new down event.
    public mutating func consume(_ event: PenEvent) -> StrokeAssemblyOutcome {
        switch event.phase {
        case .down:
            return consumeDown(event)
        case .move:
            return consumePoint(event)
        case .up:
            return consumeUp(event)
        }
    }

    /// Ends the stream.
    ///
    /// - Returns: `incomplete` with the retained stroke when a stroke was still
    ///   open, otherwise `ignored`.
    public mutating func finish() -> StrokeAssemblyOutcome {
        guard let open else {
            return .ignored
        }
        self.open = nil
        return .incomplete(stroke(from: open))
    }

    private mutating func consumeDown(_ event: PenEvent) -> StrokeAssemblyOutcome {
        if let open {
            self.open = nil
            let pageChanged = open.page != event.context.page
            let error: StrokeSequenceError = pageChanged
                ? .pageChangedDuringStroke(openPage: open.page, eventPage: event.context.page)
                : .downWhileStrokeOpen(openPage: open.page, eventPage: event.context.page)
            self.open = newOpenStroke(from: event)
            return .invalid(error)
        }
        open = newOpenStroke(from: event)
        return .opened
    }

    private mutating func consumePoint(_ event: PenEvent) -> StrokeAssemblyOutcome {
        guard var open else {
            return .invalid(.pointBeforeDown(page: event.context.page))
        }
        guard open.page == event.context.page else {
            let error = StrokeSequenceError.pageChangedDuringStroke(
                openPage: open.page,
                eventPage: event.context.page
            )
            self.open = nil
            return .invalid(error)
        }
        if let point = event.point {
            open.points.append(point)
        }
        self.open = open
        return .extended
    }

    private mutating func consumeUp(_ event: PenEvent) -> StrokeAssemblyOutcome {
        guard var open else {
            return .invalid(.upWithoutDown(page: event.context.page))
        }
        guard open.page == event.context.page else {
            let error = StrokeSequenceError.pageChangedDuringStroke(
                openPage: open.page,
                eventPage: event.context.page
            )
            self.open = nil
            return .invalid(error)
        }
        if let point = event.point {
            open.points.append(point)
        }
        self.open = nil
        return .completed(stroke(from: open))
    }

    private func newOpenStroke(from event: PenEvent) -> OpenStroke {
        var points: [PenPoint] = []
        if let point = event.point {
            points.append(point)
        }
        return OpenStroke(
            page: event.context.page,
            originTime: event.context.originTime,
            source: event.context.source,
            points: points
        )
    }

    private func stroke(from open: OpenStroke) -> Stroke {
        Stroke(
            page: open.page,
            originTime: open.originTime,
            points: open.points,
            source: open.source
        )
    }
}
