import NeoCore

/// The result of decoding one frame into domain behavior.
public enum PenDecodeOutcome: Hashable, Sendable {
    /// The pen reported a protocol version this build supports.
    case versionObserved(ProtocolVersion)

    /// The pen reported a page identity.
    case pageObserved(PageIdentity)

    /// Normalized domain events, in order.
    case events([PenEvent])

    /// The frame produced nothing observable.
    case ignored(reason: String)

    /// The frame could not be decoded or is not authorized.
    case error(PenProtocolError)
}

/// Turns decoded protocol frames into normalized NeoCore events.
///
/// The decoder enforces the evidence boundary: a command whose evidence is
/// provisional is ignored, a blocked command fails, and an unsupported command
/// or version returns an explicit unsupported result. Only production-authorized
/// commands can emit events, so a provisional mapping can never produce a
/// completed domain stroke.
///
/// A dot can only become an event once the pen has reported a page. Until then
/// the frame is ignored rather than attributed to a fabricated page.
public struct PenEventDecoder: Sendable {
    private let registry: CommandEvidenceRegistry
    private let versionPolicy: ProtocolVersionPolicy
    private let penClockIsTrusted: Bool
    private let source: PenSource

    private var penTimeCursor: Int64?
    private var strokeStartTime: Int64?
    private var firstPointTime: Int64?

    /// The most recent protocol version the pen reported.
    public private(set) var observedVersion: ProtocolVersion?

    /// The support level of the observed version.
    public private(set) var versionSupport: ProtocolVersionSupport = .unknown

    /// The most recent page the pen reported.
    public private(set) var currentPage: PageIdentity?

    public init(
        registry: CommandEvidenceRegistry = .neoSDK3,
        versionPolicy: ProtocolVersionPolicy = .neoSDK3,
        penClockIsTrusted: Bool = true,
        source: PenSource = .live
    ) {
        self.registry = registry
        self.versionPolicy = versionPolicy
        self.penClockIsTrusted = penClockIsTrusted
        self.source = source
    }

    /// Decodes one frame.
    public mutating func decode(_ frame: PenFrame) -> PenDecodeOutcome {
        guard let command = frame.command else {
            return .error(.unknownCommand(byte: frame.commandByte))
        }

        if case .unsupported(let version) = versionSupport {
            return .error(.unsupportedVersion(version))
        }

        switch registry.authorization(for: command) {
        case .unsupported:
            return .error(.unsupportedCommand(command: command))
        case .blocked(let reason):
            return .error(.blockedCommand(command: command, reason: reason))
        case .inspectionOnly(let reason):
            return .ignored(reason: "provisional mapping is inspection only: \(reason)")
        case .production:
            break
        }

        switch command {
        case .responseVersionInfo:
            return decodeVersionInfo(frame.payload)
        case .eventPenNewId, .eventNewPenNewId:
            return decodePageInfo(command: command, payload: frame.payload)
        case .eventPenUpDown:
            return decodeUpDown(frame.payload)
        case .eventNewPenDown:
            return decodeDown(frame.payload)
        case .eventNewPenUp:
            return decodeUp(frame.payload)
        case .eventPenDotCode, .eventNewPenDot:
            return decodeDot(command: command, payload: frame.payload)
        default:
            return .ignored(reason: "no domain mapping for \(command)")
        }
    }

    private mutating func decodeVersionInfo(_ payload: [UInt8]) -> PenDecodeOutcome {
        guard let info = PenVersionInfo(payload: payload) else {
            return .error(
                .malformedPayload(command: .responseVersionInfo, reason: "payload is too short")
            )
        }
        guard let version = info.protocolVersion else {
            return .error(
                .malformedPayload(
                    command: .responseVersionInfo,
                    reason: "protocol version text is not a version"
                )
            )
        }

        observedVersion = version
        versionSupport = versionPolicy.support(for: version)
        guard versionSupport.isSupported else {
            return .error(.unsupportedVersion(version))
        }
        return .versionObserved(version)
    }

    private mutating func decodePageInfo(command: PenCommand, payload: [UInt8]) -> PenDecodeOutcome {
        guard let info = PenPageInfo(payload: payload) else {
            return .error(.malformedPayload(command: command, reason: "page payload is too short"))
        }
        currentPage = info.page
        return .pageObserved(info.page)
    }

    private mutating func decodeUpDown(_ payload: [UInt8]) -> PenDecodeOutcome {
        guard let event = PenUpDownEvent(payload: payload) else {
            return .error(.malformedPayload(command: .eventPenUpDown, reason: "up/down payload is invalid"))
        }
        switch event.direction {
        case .down:
            return startStroke(at: event.timeMilliseconds)
        case .up:
            return endStroke(at: event.timeMilliseconds)
        case .move:
            return .error(
                .malformedPayload(command: .eventPenUpDown, reason: "move is not a valid up/down direction")
            )
        }
    }

    private mutating func decodeDown(_ payload: [UInt8]) -> PenDecodeOutcome {
        guard let event = PenDownEvent(payload: payload) else {
            return .error(.malformedPayload(command: .eventNewPenDown, reason: "down payload is too short"))
        }
        return startStroke(at: event.timeMilliseconds)
    }

    private mutating func decodeUp(_ payload: [UInt8]) -> PenDecodeOutcome {
        guard let event = PenUpEvent(payload: payload) else {
            return .error(.malformedPayload(command: .eventNewPenUp, reason: "up payload is too short"))
        }
        return endStroke(at: event.timeMilliseconds)
    }

    private mutating func startStroke(at time: Int64) -> PenDecodeOutcome {
        guard let page = currentPage else {
            return .ignored(reason: "down event arrived before the pen reported a page")
        }
        penTimeCursor = time
        strokeStartTime = time
        firstPointTime = time
        return .events([PenEvent(context: context(for: page), phase: .down, point: nil)])
    }

    private mutating func endStroke(at time: Int64) -> PenDecodeOutcome {
        guard let page = currentPage else {
            return .ignored(reason: "up event arrived before the pen reported a page")
        }
        penTimeCursor = time
        let outcome = PenDecodeOutcome.events([
            PenEvent(context: context(for: page), phase: .up, point: nil)
        ])
        strokeStartTime = nil
        firstPointTime = nil
        return outcome
    }

    private mutating func decodeDot(command: PenCommand, payload: [UInt8]) -> PenDecodeOutcome {
        guard let dot = PenDot(payload: payload) else {
            return .error(.malformedPayload(command: command, reason: "dot payload is invalid"))
        }
        guard let page = currentPage else {
            return .ignored(reason: "dot arrived before the pen reported a page")
        }

        let cursor = (penTimeCursor ?? 0) &+ Int64(dot.timeDeltaMilliseconds)
        penTimeCursor = cursor
        if firstPointTime == nil {
            firstPointTime = cursor
        }

        let sample = RawPenSample(
            integerX: dot.sample.integerX,
            hundredthsX: dot.sample.hundredthsX,
            integerY: dot.sample.integerY,
            hundredthsY: dot.sample.hundredthsY,
            penTimeOffsetMilliseconds: cursor - (strokeStartTime ?? firstPointTime ?? cursor),
            pressure: dot.sample.pressure
        )

        guard let point = PenSampleNormalizer.normalize(sample) else {
            return .error(
                .malformedPayload(command: command, reason: "coordinate hundredths are out of range")
            )
        }

        return .events([PenEvent(context: context(for: page), phase: .move, point: point)])
    }

    private func context(for page: PageIdentity) -> PenEventContext {
        let origin: PenOriginTime
        if let strokeStartTime {
            origin = penClockIsTrusted
                ? .reliable(milliseconds: strokeStartTime)
                : .unreliable(reportedMilliseconds: strokeStartTime)
        } else {
            origin = .unreliable(reportedMilliseconds: nil)
        }
        return PenEventContext(page: page, originTime: origin, source: source)
    }
}
