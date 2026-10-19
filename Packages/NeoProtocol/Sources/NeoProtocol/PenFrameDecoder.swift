/// The framing limits applied by `PenFrameDecoder`.
///
/// The 16-bit length field caps a frame's payload at 65,535 bytes, so the largest
/// well-formed frame body the decoder can buffer is `4 + 65,535 = 65,539` bytes.
/// A response header is one byte longer than an event header, because it carries
/// an error code between the command and the length. The decoder undoes byte
/// stuffing as bytes arrive, so a frame's length on the wire does not count
/// against `maxBufferedBytes`.
///
/// The default `maxBufferedBytes` of 131,072 leaves headroom above the largest
/// legal body, so with the default limits only a frame whose body outgrows what
/// its declared length allows — an unterminated or over-long frame — can reach
/// it. A smaller configured value is a stricter limit that also rejects
/// well-formed frames larger than it. The SDK's own `PACKET_MAX_LEN` is 32,000
/// bytes, so A1 traffic is expected to stay well below both defaults.
public struct FrameLimits: Hashable, Sendable {
    /// Maximum decoded payload size.
    ///
    /// The default is the protocol's own maximum: the length field is a 16-bit
    /// unsigned integer. Configure a smaller value to enforce a stricter limit,
    /// such as the SDK's `PACKET_MAX_LEN` of 32,000 bytes.
    public let maxPayloadBytes: Int

    /// Maximum bytes buffered inside a frame that has not ended yet.
    ///
    /// A frame that never ends is discarded once this limit is crossed, so a
    /// stalled or hostile peer cannot grow the buffer without bound. With the
    /// default limits only a frame whose body outgrows its declared length can
    /// reach it; see `FrameLimits` for how this relates to `maxPayloadBytes`.
    public let maxBufferedBytes: Int

    /// The protocol defaults.
    public static let `default` = FrameLimits()

    public init(maxPayloadBytes: Int = 65_535, maxBufferedBytes: Int = 131_072) {
        self.maxPayloadBytes = maxPayloadBytes
        self.maxBufferedBytes = maxBufferedBytes
    }
}

/// Decodes the A1's byte-stuffed framing into packets.
///
/// Framing evidence: Neo iOS SDK 3.0 `Global.swift`, `FunctionUtil.swift`, and
/// `PenCommParser.parsePenDataPacket`. A frame starts with `0xC0`, ends with
/// `0xC1`, and escapes a literal `0xC0`, `0xC1`, or `0x7D` as `0x7D` followed by
/// the byte XOR `0x20`. The frame body is `command (1 byte) | optional error code
/// (1 byte) | length (UInt16 little-endian) | payload (length bytes)`. A response
/// carries the error code; an event, a request, and the pen's offline data stream
/// do not. Which layout an identifier uses is a property of the identifier, taken
/// from `PenCommand.frameKind`, so a command the evidence does not classify is
/// rejected rather than parsed with a guessed layout.
///
/// The decoder is a value type that keeps only framing state, so it can be
/// copied or stored freely. After any error it discards the frame in progress
/// and resynchronizes on the next start marker.
public struct PenFrameDecoder: Sendable {
    private let limits: FrameLimits
    private var buffer: [UInt8] = []
    private var isEscaped = false
    private var isInFrame = false

    public init(limits: FrameLimits = .default) {
        self.limits = limits
    }

    /// Decodes every frame contained in one transport chunk.
    ///
    /// - Parameter chunk: The inbound bytes, in arrival order.
    /// - Returns: One outcome per decoded frame or error, in order.
    public mutating func ingest(_ chunk: [UInt8]) -> [PenFrameDecodeOutcome] {
        var outcomes: [PenFrameDecodeOutcome] = []

        for byte in chunk {
            if isEscaped {
                isEscaped = false
                if isInFrame, let outcome = append(byte ^ 0x20) {
                    outcomes.append(outcome)
                }
                continue
            }

            switch byte {
            case PenFraming.start:
                buffer.removeAll(keepingCapacity: true)
                isInFrame = true
            case PenFraming.end:
                if isInFrame {
                    outcomes.append(decodeFrame())
                    isInFrame = false
                }
            case PenFraming.escape:
                if isInFrame {
                    isEscaped = true
                }
            default:
                if isInFrame, let outcome = append(byte) {
                    outcomes.append(outcome)
                }
            }
        }

        return outcomes
    }

    /// Discards any partially decoded frame.
    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        isEscaped = false
        isInFrame = false
    }

    private mutating func append(_ byte: UInt8) -> PenFrameDecodeOutcome? {
        buffer.append(byte)
        guard buffer.count > limits.maxBufferedBytes else {
            return nil
        }
        buffer.removeAll(keepingCapacity: true)
        isInFrame = false
        return .error(.bufferedInputExceedsLimit(limit: limits.maxBufferedBytes))
    }

    private mutating func decodeFrame() -> PenFrameDecodeOutcome {
        defer { buffer.removeAll(keepingCapacity: true) }

        guard let commandByte = buffer.first else {
            return .error(.packetTooShortForHeader(byteCount: 0))
        }
        guard let command = PenCommand(rawValue: commandByte), let kind = command.frameKind else {
            // The body layout is a property of the identifier, so an identifier
            // with no classification leaves no way to find the length field.
            return .error(.unknownCommand(byte: commandByte))
        }

        let headerByteCount = kind == .response ? 4 : 3
        guard buffer.count >= headerByteCount else {
            return .error(.packetTooShortForHeader(byteCount: buffer.count))
        }

        let errorCode: UInt8?
        let declared: Int
        switch kind {
        case .response:
            errorCode = buffer[1]
            declared = Int(buffer[2]) | Int(buffer[3]) << 8
        case .event:
            errorCode = nil
            declared = Int(buffer[1]) | Int(buffer[2]) << 8
        }

        guard declared <= limits.maxPayloadBytes else {
            return .error(.payloadExceedsLimit(declared: declared, limit: limits.maxPayloadBytes))
        }

        let available = buffer.count - headerByteCount
        guard available >= declared else {
            return .error(.truncatedPacket(declared: declared, available: available))
        }
        guard available <= declared else {
            return .error(.payloadLengthMismatch(declared: declared, available: available))
        }

        return .frame(
            PenFrame(
                commandByte: commandByte,
                command: command,
                errorCode: errorCode,
                payload: Array(buffer[headerByteCount...])
            )
        )
    }
}

/// The framing control bytes.
public enum PenFraming {
    /// Start-of-frame marker.
    public static let start: UInt8 = 0xC0

    /// End-of-frame marker.
    public static let end: UInt8 = 0xC1

    /// Byte-stuffing escape marker.
    public static let escape: UInt8 = 0x7D
}

/// Builds byte-stuffed frames.
///
/// The encoder mirrors `makeWholePacket` in Neo iOS SDK 3.0 and exists so tests
/// and fixture builders can produce the exact bytes a pen sends.
public enum PenFrameEncoder {
    /// Encodes one packet using the framing its identifier implies.
    ///
    /// - Parameters:
    ///   - command: The command identifier.
    ///   - payload: The payload bytes.
    ///   - errorCode: The error code to report for a response frame. An event
    ///     frame has no error-code position, so the value is ignored.
    /// - Returns: `0xC0`, the escaped body, and `0xC1`, or `nil` when the
    ///   identifier has no framing evidence, so a caller cannot invent a layout
    ///   for it.
    public static func encode(
        command: PenCommand,
        payload: [UInt8],
        errorCode: UInt8 = 0
    ) -> [UInt8]? {
        guard let kind = command.frameKind else {
            return nil
        }
        return encode(command: command.rawValue, payload: payload, kind: kind, errorCode: errorCode)
    }

    /// Encodes one packet with an explicit framing.
    ///
    /// Use this for an identifier the evidence does not classify, such as the
    /// body of a deliberately malformed frame. It is internal because it lets a
    /// caller state a layout the evidence does not support; a production caller
    /// goes through the classifying overload above instead.
    ///
    /// - Parameters:
    ///   - command: The command identifier.
    ///   - payload: The payload bytes.
    ///   - kind: The framing to use.
    ///   - errorCode: The error code to report for a response frame.
    /// - Returns: `0xC0`, the escaped body, and `0xC1`.
    static func encode(
        command: UInt8,
        payload: [UInt8],
        kind: PenFrameKind,
        errorCode: UInt8 = 0
    ) -> [UInt8] {
        var body: [UInt8] = [command]
        if kind == .response {
            body.append(errorCode)
        }
        let length = UInt16(payload.count)
        body.append(UInt8(length & 0xFF))
        body.append(UInt8((length >> 8) & 0xFF))
        body.append(contentsOf: payload)

        var frame: [UInt8] = [PenFraming.start]
        for byte in body {
            if byte == PenFraming.start || byte == PenFraming.end || byte == PenFraming.escape {
                frame.append(PenFraming.escape)
                frame.append(byte ^ 0x20)
            } else {
                frame.append(byte)
            }
        }
        frame.append(PenFraming.end)
        return frame
    }
}
