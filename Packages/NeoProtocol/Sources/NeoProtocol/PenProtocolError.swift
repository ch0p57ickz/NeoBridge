/// An explicit protocol parse, size-limit, or support failure.
///
/// The decoder never invents pen events when it reports one of these.
public enum PenProtocolError: Error, Hashable, Sendable {
    /// A frame declared a payload larger than the configured limit.
    case payloadExceedsLimit(declared: Int, limit: Int)

    /// Buffered undecoded input exceeded the configured limit before the frame
    /// ended. The frame is discarded and parsing resumes at the next frame.
    case bufferedInputExceedsLimit(limit: Int)

    /// A frame ended before the declared payload was complete.
    case truncatedPacket(declared: Int, available: Int)

    /// A frame carried more payload bytes than it declared.
    case payloadLengthMismatch(declared: Int, available: Int)

    /// A frame ended before the three-byte command and length header.
    case packetTooShortForHeader(byteCount: Int)

    /// The command identifier is not in the protocol 2.x command table.
    case unknownCommand(byte: UInt8)

    /// A known command carried a payload the decoder could not interpret.
    case malformedPayload(command: PenCommand, reason: String)

    /// The pen or fixture reported a protocol version this build does not
    /// support.
    case unsupportedVersion(ProtocolVersion)

    /// The command has no official SDK or physical-device evidence.
    case unsupportedCommand(command: PenCommand)

    /// The command is wire-documented but must not be sent until a later gate
    /// passes.
    case blockedCommand(command: PenCommand, reason: String)
}

/// A decoded protocol frame.
public struct PenFrame: Hashable, Sendable {
    /// The raw command identifier, retained even when it is unknown.
    public let commandByte: UInt8

    /// The decoded command, or `nil` when the identifier is unknown.
    public let command: PenCommand?

    /// The declared payload bytes.
    public let payload: [UInt8]

    public init(commandByte: UInt8, command: PenCommand?, payload: [UInt8]) {
        self.commandByte = commandByte
        self.command = command
        self.payload = payload
    }
}

/// The result of ingesting one transport chunk.
public enum PenFrameDecodeOutcome: Hashable, Sendable {
    /// A complete frame was decoded.
    case frame(PenFrame)

    /// The input could not be decoded.
    case error(PenProtocolError)
}
