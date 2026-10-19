import NeoCore

/// An offline note the pen reported as available for retrieval.
///
/// The pen identifies an offline note by Ncode section, owner, and note (book).
/// A request carries the section and owner packed into one 32-bit
/// `sectionOwnerId`, exactly as the SDK's `toSectionOwner` does.
public struct PenOfflineNote: Hashable, Sendable {
    /// Ncode section index.
    public let section: UInt8

    /// Ncode owner identifier. The pen transmits 24 bits.
    public let owner: UInt32

    /// Ncode note (book) identifier.
    public let note: UInt32

    public init(section: UInt8, owner: UInt32, note: UInt32) {
        self.section = section
        self.owner = owner
        self.note = note
    }

    /// The packed section-and-owner identifier the requests carry.
    public var sectionOwnerId: UInt32 {
        PenWire.sectionOwnerId(section: section, owner: owner)
    }
}

/// The decoded `0xA2` page list for one note.
public struct PenOfflinePageList: Hashable, Sendable {
    /// The note the pages belong to.
    public let note: PenOfflineNote

    /// The page identifiers the pen reported, in the order it reported them.
    public let pages: [UInt32]
}

/// The decoded `0xA3` offline data info summary.
///
/// The summary is a lagging index: a physical A1 capture on 2026-10-18 reported
/// 6,918 strokes while the packet stream carried 6,920, so the transfer is what
/// counts. The value is kept for diagnostics only.
public struct PenOfflineDataInfo: Hashable, Sendable {
    /// Strokes the pen's index claims the note holds.
    public let strokeCount: UInt32

    /// Uncompressed size of the stroke and dot data the pen will send.
    public let uncompressedSize: UInt32

    /// Whether the pen intends to compress the transfer.
    public let isCompressed: Bool

    /// The wire size of the info payload.
    public static let payloadBytes = 9
}

/// The result of decoding an `0xA1` note list payload.
public enum PenOfflineNoteListOutcome: Hashable, Sendable {
    /// The requestable notes, in the order the pen reported them.
    case notes([PenOfflineNote])

    /// The payload is malformed, so no retrieval may follow.
    case error(PenProtocolError)
}

/// The result of decoding an `0xA2` page list payload.
public enum PenOfflinePageListOutcome: Hashable, Sendable {
    /// The decoded page list.
    case pages(PenOfflinePageList)

    /// The payload is malformed.
    case error(PenProtocolError)
}

/// Decodes the pen's offline note and page lists.
///
/// Wire layouts, from Neo iOS SDK 3.0 `ResponseStruct.swift`:
///
/// - `OfflineNoteList` (`0xA1`): a little-endian count (2 bytes), then one
///   `sectionOwnerId` (4 bytes) and one note identifier (4 bytes) per entry.
/// - `OfflinePageList` (`0xA2`): `sectionOwnerId` (4 bytes), note identifier
///   (4 bytes), a little-endian page count (2 bytes), then one page identifier
///   (4 bytes) per entry.
/// - `OfflineInfo` (`0xA3`): stroke count (4 bytes), uncompressed size
///   (4 bytes), and a compression flag (1 byte).
///
/// The SDK reads these without bounds checks. A decoder that trusts the count
/// would read past the payload, so every length is validated first and a short
/// payload is reported as malformed. Retrieval must not begin from a malformed
/// list, because a partially decoded list would silently hide notes.
public enum PenOfflineListDecoder {
    /// Wire size of one note-list entry.
    static let noteEntryBytes = 8

    /// Wire size of the page-list header before the page entries.
    static let pageListHeaderBytes = 10

    /// Wire size of one page entry.
    static let pageEntryBytes = 4

    /// Decodes an `0xA1` note list payload.
    ///
    /// - Parameter payload: The frame payload, without command, error, and
    ///   length bytes.
    public static func decodeNoteList(payload: [UInt8]) -> PenOfflineNoteListOutcome {
        guard payload.count >= 2 else {
            return .error(malformed(.responseOfflineNoteList, "note list is shorter than its count"))
        }

        let declaredCount = Int(PenWire.uint16(payload, at: 0))
        let expectedBytes = 2 + declaredCount * noteEntryBytes
        guard payload.count >= expectedBytes else {
            return .error(
                malformed(
                    .responseOfflineNoteList,
                    "note list declares \(declaredCount) notes but carries \(payload.count) bytes"
                )
            )
        }

        var notes: [PenOfflineNote] = []
        notes.reserveCapacity(declaredCount)
        var cursor = 2
        for _ in 0..<declaredCount {
            let sectionOwnerId = PenWire.uint32(payload, at: cursor)
            let noteId = PenWire.uint32(payload, at: cursor + 4)
            cursor += noteEntryBytes

            let (section, owner) = PenWire.sectionAndOwner(sectionOwnerId)
            notes.append(PenOfflineNote(section: section, owner: owner, note: noteId))
        }

        return .notes(notes)
    }

    /// Decodes an `0xA2` page list payload.
    ///
    /// - Parameter payload: The frame payload, without command, error, and
    ///   length bytes.
    public static func decodePageList(payload: [UInt8]) -> PenOfflinePageListOutcome {
        guard payload.count >= pageListHeaderBytes else {
            return .error(malformed(.responseOfflinePageList, "page list is shorter than its header"))
        }

        let sectionOwnerId = PenWire.uint32(payload, at: 0)
        let noteId = PenWire.uint32(payload, at: 4)
        let declaredCount = Int(PenWire.uint16(payload, at: 8))
        let expectedBytes = pageListHeaderBytes + declaredCount * pageEntryBytes
        guard payload.count >= expectedBytes else {
            return .error(
                malformed(
                    .responseOfflinePageList,
                    "page list declares \(declaredCount) pages but carries \(payload.count) bytes"
                )
            )
        }

        var pages: [UInt32] = []
        pages.reserveCapacity(declaredCount)
        var cursor = pageListHeaderBytes
        for _ in 0..<declaredCount {
            pages.append(PenWire.uint32(payload, at: cursor))
            cursor += pageEntryBytes
        }

        let (section, owner) = PenWire.sectionAndOwner(sectionOwnerId)
        return .pages(
            PenOfflinePageList(
                note: PenOfflineNote(section: section, owner: owner, note: noteId),
                pages: pages
            )
        )
    }

    /// Decodes an `0xA3` offline data info payload.
    ///
    /// - Returns: The summary, or `nil` when the payload is too short.
    public static func decodeInfo(payload: [UInt8]) -> PenOfflineDataInfo? {
        guard payload.count >= PenOfflineDataInfo.payloadBytes else {
            return nil
        }
        return PenOfflineDataInfo(
            strokeCount: PenWire.uint32(payload, at: 0),
            uncompressedSize: PenWire.uint32(payload, at: 4),
            isCompressed: payload[8] != 0
        )
    }

    private static func malformed(_ command: PenCommand, _ reason: String) -> PenProtocolError {
        .malformedPayload(command: command, reason: reason)
    }
}
