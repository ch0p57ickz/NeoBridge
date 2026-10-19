import Foundation

/// Lowercase hexadecimal encoding for fixture bytes.
public enum HexCoding {
    /// Encodes bytes as a lowercase hexadecimal string.
    public static func encode(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef")
        var result = ""
        result.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            result.append(digits[Int(byte >> 4)])
            result.append(digits[Int(byte & 0x0F)])
        }
        return result
    }

    /// Decodes a hexadecimal string.
    ///
    /// Whitespace is ignored so a fixture can wrap long frames.
    ///
    /// - Returns: The bytes, or `nil` when the string is not valid hexadecimal.
    public static func decode(_ string: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        var pending: UInt8?

        for character in string {
            guard let value = character.hexDigitValue else {
                if character.isWhitespace {
                    continue
                }
                return nil
            }
            if let high = pending {
                bytes.append(high << 4 | UInt8(value))
                pending = nil
            } else {
                pending = UInt8(value)
            }
        }

        return pending == nil ? bytes : nil
    }
}

private extension Character {
    var hexDigitValue: Int? {
        switch self {
        case "0"..."9": return Int(String(self))
        case "a"..."f", "A"..."F": return Int(String(self), radix: 16)
        default: return nil
        }
    }
}

/// An expected framing outcome.
public struct ExpectedFrameOutcome: Hashable, Sendable, Decodable {
    /// Either `"packet"` or `"error"`.
    public let kind: String

    /// The expected command byte as a hexadecimal string, for packets.
    public let commandByte: String?

    /// The expected payload as a hexadecimal string, for packets.
    public let payloadHex: String?

    /// The expected error kind, for errors.
    public let error: String?

    /// The decoded command byte.
    public var byte: UInt8? {
        guard let commandByte else {
            return nil
        }
        if commandByte.hasPrefix("0x") || commandByte.hasPrefix("0X") {
            return UInt8(commandByte.dropFirst(2), radix: 16)
        }
        return UInt8(commandByte)
    }
}

/// A sanitized protocol fixture.
///
/// A fixture records where its bytes came from, what sanitization was applied,
/// the observed device and protocol version, and the expected parse result, so a
/// reviewer can confirm that no Bluetooth address, serial number, authentication
/// material, or personal handwriting content is present.
public struct ProtocolFixture: Hashable, Sendable, Decodable {
    /// Where the fixture bytes came from.
    public struct Provenance: Hashable, Sendable, Decodable {
        /// The SDK source or capture method.
        public let source: String

        /// The pen model the bytes describe.
        public let deviceModel: String

        /// The pen firmware version, or `unverified` when it was not captured.
        public let firmware: String

        /// The protocol version observed from the pen or fixture.
        public let observedProtocolVersion: String

        /// The capture date in `YYYY-MM-DD` form.
        public let captureDate: String
    }

    /// The sanitization applied to the fixture.
    public struct Sanitization: Hashable, Sendable, Decodable {
        /// The categories of sensitive content removed.
        public let removed: [String]

        /// A description of the substitution performed.
        public let notes: String
    }

    /// Optional framing limits for the fixture.
    public struct Limits: Hashable, Sendable, Decodable {
        /// Maximum decoded payload size.
        public let maxPayloadBytes: Int

        /// Maximum buffered undecoded input.
        public let maxBufferedBytes: Int

        /// The equivalent `FrameLimits` value.
        public var frameLimits: FrameLimits {
            FrameLimits(maxPayloadBytes: maxPayloadBytes, maxBufferedBytes: maxBufferedBytes)
        }
    }

    /// The fixture schema version.
    public let fixtureVersion: Int

    /// A stable fixture identifier.
    public let id: String

    /// The evidence level behind the fixture's bytes.
    public let evidenceLevel: CommandEvidenceLevel

    /// Where the bytes came from.
    public let provenance: Provenance

    /// The sanitization applied.
    public let sanitization: Sanitization

    /// A short description of what the fixture covers.
    public let comment: String

    /// Framing limits, when the fixture exercises a non-default limit.
    public let limits: Limits?

    /// Inbound chunks as hexadecimal strings, in delivery order.
    public let chunks: [String]

    /// The expected framing outcomes, in order.
    public let expected: [ExpectedFrameOutcome]

    /// The expected protocol version, for fixtures that report one.
    public let expectedProtocolVersion: String?

    /// The expected page, for fixtures that report one.
    public let expectedPage: PageExpectation?

    /// The expected number of completed strokes.
    public let expectedStrokeCount: Int?

    /// An expected page identity in a fixture.
    public struct PageExpectation: Hashable, Sendable, Decodable {
        /// Ncode section.
        public let section: UInt8

        /// Ncode owner.
        public let owner: UInt32

        /// Ncode book.
        public let book: UInt32

        /// Ncode page.
        public let page: UInt32
    }

    /// The framing limits to use when replaying this fixture.
    public var frameLimits: FrameLimits {
        limits?.frameLimits ?? .default
    }

    /// The inbound chunks as bytes.
    ///
    /// - Throws: `ProtocolFixtureError.invalidHex` when a chunk is not valid
    ///   hexadecimal.
    public func decodedChunks() throws -> [[UInt8]] {
        try chunks.map { chunk in
            guard let bytes = HexCoding.decode(chunk) else {
                throw ProtocolFixtureError.invalidHex(fixtureID: id, field: chunk)
            }
            return bytes
        }
    }

    /// The expected packets as bytes, ignoring expected errors.
    ///
    /// - Throws: `ProtocolFixtureError.invalidHex` when a field is not valid
    ///   hexadecimal.
    public func decodedExpectedPackets() throws -> [(commandByte: UInt8, payload: [UInt8])] {
        try expected.compactMap { outcome in
            guard outcome.kind == "packet" else {
                return nil
            }
            guard let byte = outcome.byte,
                  let payloadHex = outcome.payloadHex,
                  let payload = HexCoding.decode(payloadHex)
            else {
                throw ProtocolFixtureError.invalidHex(fixtureID: id, field: outcome.payloadHex ?? "")
            }
            return (byte, payload)
        }
    }

    /// The expected error kinds, in order.
    public var expectedErrorKinds: [String] {
        expected.compactMap { outcome in
            outcome.kind == "error" ? outcome.error : nil
        }
    }
}

/// A fixture could not be read.
public enum ProtocolFixtureError: Error, Hashable, Sendable {
    /// A hexadecimal field is not valid hexadecimal.
    case invalidHex(fixtureID: String, field: String)

    /// No fixtures were found in the expected directory.
    case noFixturesFound(directory: String)
}

/// Loads sanitized fixtures from disk.
public enum ProtocolFixtureLoader {
    /// The file extension of a fixture.
    public static let fileExtension = "json"

    /// Loads every fixture in a directory.
    ///
    /// - Parameter directory: The directory that holds the fixture files.
    /// - Returns: Fixtures sorted by file name so runs are reproducible.
    /// - Throws: `ProtocolFixtureError.noFixturesFound` when the directory holds
    ///   no fixtures, or a decoding error when a fixture is malformed.
    public static func loadAll(in directory: URL) throws -> [ProtocolFixture] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let files = contents
            .filter { $0.pathExtension == fileExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !files.isEmpty else {
            throw ProtocolFixtureError.noFixturesFound(directory: directory.path)
        }

        let decoder = JSONDecoder()
        return try files.map { url in
            let data = try Data(contentsOf: url)
            return try decoder.decode(ProtocolFixture.self, from: data)
        }
    }
}

extension PenProtocolError {
    /// A stable kind name used by fixture expectations.
    public var kind: String {
        switch self {
        case .payloadExceedsLimit: return "payloadExceedsLimit"
        case .bufferedInputExceedsLimit: return "bufferedInputExceedsLimit"
        case .truncatedPacket: return "truncatedPacket"
        case .payloadLengthMismatch: return "payloadLengthMismatch"
        case .packetTooShortForHeader: return "packetTooShortForHeader"
        case .unknownCommand: return "unknownCommand"
        case .malformedPayload: return "malformedPayload"
        case .unsupportedVersion: return "unsupportedVersion"
        case .unsupportedCommand: return "unsupportedCommand"
        case .blockedCommand: return "blockedCommand"
        }
    }
}
