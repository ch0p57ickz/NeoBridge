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

    /// A frame ended before the command and length header.
    ///
    /// An event header is three bytes; a response header is four, because an
    /// error code sits between the command and the length.
    case packetTooShortForHeader(byteCount: Int)

    /// The command identifier has no known body layout, so the frame could not
    /// be framed.
    ///
    /// This covers an identifier outside the protocol 2.x command table and one
    /// that is in the table but whose framing the evidence does not classify. In
    /// both cases the position of the length field is unknown, so the decoder
    /// discards the frame rather than guessing.
    case unknownCommand(byte: UInt8)

    /// A known command carried a payload the decoder could not interpret.
    case malformedPayload(command: PenCommand, reason: String)

    /// A response reported a non-zero error code, so the pen rejected the
    /// command it answers.
    ///
    /// The frame is still reported by the framing layer with its payload, so the
    /// exchange stays diagnosable; this error is what stops that payload from
    /// being decoded as data.
    case commandFailed(command: PenCommand, code: UInt8)

    /// The pen or fixture reported a protocol version this build does not
    /// support.
    case unsupportedVersion(ProtocolVersion)

    /// The command has no official SDK or physical-device evidence.
    case unsupportedCommand(command: PenCommand)

    /// The command is wire-documented but gated behind an evidence gate that is
    /// not yet open.
    case gatedCommand(command: PenCommand, reason: String)
}

/// A decoded protocol frame.
public struct PenFrame: Hashable, Sendable {
    /// The raw command identifier, retained even when it is unknown.
    public let commandByte: UInt8

    /// The decoded command, or `nil` when the identifier is not in the command
    /// table.
    ///
    /// The frame decoder rejects an unclassified identifier before it produces a
    /// frame, so this is `nil` only on a hand-built frame.
    public let command: PenCommand?

    /// The response error code, or `nil` for a frame whose layout has no
    /// error-code position.
    ///
    /// A response carries a zero code when the pen accepted the command. The
    /// framing layer reports whatever the pen sent, including a non-zero code,
    /// so a failed exchange stays diagnosable; turning a non-zero code into a
    /// protocol error is the token layer's job. The initializer defaults a
    /// response command's code to zero, so a frame built without one is read as
    /// accepted rather than as a frame with no error-code position.
    public let errorCode: UInt8?

    /// The declared payload bytes.
    public let payload: [UInt8]

    public init(
        commandByte: UInt8,
        command: PenCommand?,
        errorCode: UInt8? = nil,
        payload: [UInt8]
    ) {
        self.commandByte = commandByte
        self.command = command
        self.errorCode = errorCode ?? (command?.frameKind == .response ? 0 : nil)
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
