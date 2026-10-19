import Foundation
import NeoBridgeMacCore
import NeoProtocol

/// The frames a fake pen sends.
///
/// The payloads are built here from the layouts `docs/protocol-a1.md` records,
/// and framed with the portable encoder, so a test never pastes a frame that the
/// production codec would reject.
enum FakePenFrames {
    /// The Ncode section and owner the physics A1 capture used, packed as the
    /// requests carry them: section 3 in the high byte, owner 27 below it.
    static let sectionOwnerId: UInt32 = 0x0300_001B

    /// The note identifier the physical A1 capture read.
    static let note: UInt32 = 700

    /// A `0x81` version response from a pen that reports protocol 2.23.
    static func versionInfo(protocolVersion: String = "2.23") -> [UInt8] {
        var payload = [UInt8](repeating: 0, count: 70)
        write("NWP-F151", into: &payload, at: 0, length: 16)
        write("3.00", into: &payload, at: 16, length: 16)
        write(protocolVersion, into: &payload, at: 32, length: 8)
        write("Neosmartpen_A1", into: &payload, at: 40, length: 16)
        payload[56] = 0x01  // Device type.
        payload[64] = 0x04  // Pressure sensor type.
        payload[69] = 0x00  // Compression capability clear.
        return frame(.responseVersionInfo, payload)
    }

    /// An `0xA1` note list.
    ///
    /// - Parameter notes: One `(sectionOwnerId, note)` pair per entry.
    static func noteList(notes: [(sectionOwnerId: UInt32, note: UInt32)]) -> [UInt8] {
        var payload = littleEndian16(UInt16(notes.count))
        for entry in notes {
            payload += littleEndian32(entry.sectionOwnerId)
            payload += littleEndian32(entry.note)
        }
        return frame(.responseOfflineNoteList, payload)
    }

    /// An `0xA2` page list.
    static func pageList(sectionOwnerId: UInt32, note: UInt32, pages: [UInt32]) -> [UInt8] {
        var payload = littleEndian32(sectionOwnerId)
        payload += littleEndian32(note)
        payload += littleEndian16(UInt16(pages.count))
        for page in pages {
            payload += littleEndian32(page)
        }
        return frame(.responseOfflinePageList, payload)
    }

    /// An `0xA3` offline data info summary.
    static func offlineInfo(
        strokeCount: UInt32,
        uncompressedSize: UInt32,
        isCompressed: Bool = false
    ) -> [UInt8] {
        let payload =
            littleEndian32(strokeCount) + littleEndian32(uncompressedSize)
            + [isCompressed ? 0x01 : 0x00]
        return frame(.responseOfflineDataInfo, payload)
    }

    /// The frames one complete read of a pen with a single note needs, up to but
    /// not including the `0x24` packets.
    static func discoveryOnly(
        sectionOwnerId: UInt32 = sectionOwnerId,
        note: UInt32 = note
    ) -> [[UInt8]] {
        [
            versionInfo(),
            noteList(notes: [(sectionOwnerId, note)]),
            pageList(sectionOwnerId: sectionOwnerId, note: note, pages: [1, 16]),
            offlineInfo(strokeCount: 0, uncompressedSize: 0),
        ]
    }

    /// Frames one packet with the portable encoder.
    private static func frame(_ command: PenCommand, _ payload: [UInt8]) -> [UInt8] {
        guard let encoded = PenFrameEncoder.encode(command: command, payload: payload) else {
            preconditionFailure("the portable encoder has no framing for \(command)")
        }
        return encoded
    }

    private static func write(
        _ text: String,
        into payload: inout [UInt8],
        at offset: Int,
        length: Int
    ) {
        for (index, byte) in Array(text.utf8).enumerated()
        where index < length && offset + index < payload.count {
            payload[offset + index] = byte
        }
    }

    private static func littleEndian16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private static func littleEndian32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ]
    }
}
