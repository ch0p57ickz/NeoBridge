import NeoCore

/// Little-endian readers for the A1 wire format.
///
/// The Neo iOS SDK 3.0 `FunctionUtil.swift` helpers (`toUInt16`, `toUInt32`,
/// `toInt64`) read little-endian integers. These readers implement the same
/// layout without the SDK's operator-precedence quirks.
enum PenWire {
    static func uint16(_ bytes: [UInt8], at index: Int) -> UInt16 {
        UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
    }

    static func uint32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index])
            | UInt32(bytes[index + 1]) << 8
            | UInt32(bytes[index + 2]) << 16
            | UInt32(bytes[index + 3]) << 24
    }

    static func int64(_ bytes: [UInt8], at index: Int) -> Int64 {
        var value: UInt64 = 0
        for offset in 0..<8 {
            value |= UInt64(bytes[index + offset]) << UInt64(8 * offset)
        }
        return Int64(bitPattern: value)
    }

    /// Decodes a NUL-padded UTF-8 field the way the SDK's `toString` does.
    static func text(_ bytes: ArraySlice<UInt8>) -> String {
        let trimmed = bytes.filter { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    /// Sum of all bytes, truncated to one byte. The offline dot checksum.
    static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        var sum: UInt32 = 0
        for byte in bytes {
            sum &+= UInt32(byte)
        }
        return UInt8(sum & 0xFF)
    }

    /// Little-endian bytes of an unsigned 16-bit value.
    static func bytes(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    /// Little-endian bytes of an unsigned 32-bit value.
    static func bytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ]
    }

    /// A fixed-width NUL-padded UTF-8 field, as `toUInt8Array8`/`16` produce.
    ///
    /// A value longer than `width` is truncated to `width` bytes so the fixed
    /// request layout always holds.
    static func paddedText(_ value: String, width: Int) -> [UInt8] {
        var bytes = Array(value.utf8.prefix(width))
        bytes.append(contentsOf: repeatElement(0, count: width - bytes.count))
        return bytes
    }

    /// Packs a Ncode section and owner into the identifier the requests carry.
    ///
    /// Source: Neo iOS SDK 3.0 `FunctionUtil.toSectionOwner`. The section is the
    /// high byte and the owner the low 24 bits.
    static func sectionOwnerId(section: UInt8, owner: UInt32) -> UInt32 {
        (UInt32(section) << 24) | (owner & 0x00FF_FFFF)
    }

    /// Unpacks a section-owner identifier into its two components.
    ///
    /// Source: Neo iOS SDK 3.0 `FunctionUtil.toSetionOwner`.
    static func sectionAndOwner(_ sectionOwnerId: UInt32) -> (section: UInt8, owner: UInt32) {
        (UInt8(sectionOwnerId >> 24), sectionOwnerId & 0x00FF_FFFF)
    }
}

/// Version information reported by the pen (`RES_VERSION_INFO`, `0x81`).
///
/// The Bluetooth address in the wire payload is deliberately not decoded. It is
/// a device identifier that fixtures must not contain, and no portable behavior
/// needs it.
public struct PenVersionInfo: Hashable, Sendable {
    /// The pen's advertised device name.
    public let deviceName: String

    /// The pen's firmware version string.
    public let firmwareVersion: String

    /// The raw protocol version text, such as `"2.18"`.
    public let protocolVersionText: String

    /// The pen's sub-name field.
    public let subName: String

    /// The device type code.
    public let deviceType: UInt16

    /// The pressure sensor type code.
    public let pressureSensorType: UInt8

    /// Whether the pen can send compressed offline data.
    ///
    /// The SDK reports this only for protocol 2.22 and later.
    public let supportsCompressedTransfer: Bool

    /// The observed protocol version, parsed from `protocolVersionText`.
    public var protocolVersion: ProtocolVersion? {
        ProtocolVersion(protocolVersionText)
    }

    /// The wire size of a version payload without the optional pressure field.
    public static let minimumPayloadBytes = 64

    init?(payload: [UInt8]) {
        guard payload.count >= Self.minimumPayloadBytes else {
            return nil
        }
        deviceName = PenWire.text(payload[0..<16])
        firmwareVersion = PenWire.text(payload[16..<32])
        protocolVersionText = PenWire.text(payload[32..<40])
        subName = PenWire.text(payload[40..<56])
        deviceType = PenWire.uint16(payload, at: 56)
        pressureSensorType = payload.count >= 65 ? payload[64] : 0

        let version = ProtocolVersion(protocolVersionText)
        supportsCompressedTransfer = payload.count >= 70
            && (version.map { $0 >= ProtocolVersion(major: 2, minor: 22) } ?? false)
            && payload[69] != 0
    }
}

/// Page information reported by the pen (`0x64` and `0x6B`).
public struct PenPageInfo: Hashable, Sendable {
    /// The page the pen reports.
    public let page: PageIdentity

    /// The pen's event count, present on `0x6B` payloads.
    public let eventCount: UInt8?

    init?(payload: [UInt8]) {
        var body = payload
        var eventCount: UInt8?
        if body.count == 13 {
            eventCount = body.removeFirst()
        }
        guard body.count >= 12 else {
            return nil
        }

        // Owner is 24 bits; the pen packs section into the byte after it.
        let owner = PenWire.uint32(body, at: 0) & 0x00FF_FFFF
        let section = body[3]
        let book = PenWire.uint32(body, at: 4)
        let page = PenWire.uint32(body, at: 8)

        self.page = PageIdentity(section: section, owner: owner, book: book, page: page)
        self.eventCount = eventCount
    }
}
