import NeoCore

/// Where a packet sits in a multi-packet offline transfer.
///
/// Values come from `OfflineTransPosition` in Neo iOS SDK 3.0
/// (`NISDK3/Classes/Model/ResponseStruct.swift`): 0 start, 1 middle, 2 end.
public enum OfflineTransferPosition: UInt8, Hashable, Sendable {
    case start = 0
    case middle = 1
    case end = 2
}

/// The header of an offline data packet (`0xA4`).
///
/// Wire layout from Neo iOS SDK 3.0 `ResponseStruct.swift` (`OffLineData`):
/// packet id (2), compression flag (1), uncompressed size (2), compressed size
/// (2), transfer position (1), owner (3), section (1), book (4), stroke count (2).
public struct OfflineDataHeader: Hashable, Sendable {
    /// The pen's packet identifier for the transfer.
    public let packetID: UInt16

    /// Whether the payload is compressed.
    public let isCompressed: Bool

    /// Size before compression.
    public let sizeBeforeCompression: UInt16

    /// Size after compression.
    public let sizeAfterCompression: UInt16

    /// Where this packet sits in the transfer.
    public let transferPosition: OfflineTransferPosition

    /// Ncode section.
    public let section: UInt8

    /// Ncode owner. The pen transmits 24 bits.
    public let owner: UInt32

    /// Ncode book (note).
    public let book: UInt32

    /// Number of stroke records that follow the header.
    public let strokeCount: UInt16

    /// The wire size of the header.
    public static let payloadBytes = 18
}

/// One stroke recovered from offline storage.
public struct OfflineStrokeRecord: Hashable, Sendable {
    /// The assembled stroke.
    public let stroke: Stroke

    /// The pen's reported up time in milliseconds.
    public let upTimeMilliseconds: Int64

    /// Pen tip type code.
    public let tipType: UInt8
}

/// The result of parsing an offline data payload.
public enum OfflineDataParseOutcome: Hashable, Sendable {
    /// Strokes recovered from the packet.
    case strokes(header: OfflineDataHeader, records: [OfflineStrokeRecord])

    /// The packet uses a transfer shape this build has no evidence for.
    case unsupported(reason: String)

    /// The payload is malformed.
    case error(PenProtocolError)
}

/// Parses offline data packets into domain strokes.
///
/// Only the single-packet, uncompressed transfer shape that the official SDK
/// documents is supported. Compressed payloads and multi-packet transfers are
/// reported as unsupported until a physical A1 capture provides evidence for
/// them.
public enum OfflineDataParser {
    /// Wire size of one stroke record header.
    static let strokeRecordBytes = 27

    /// Parses a `RES2_OFFLINE_DATA` payload.
    ///
    /// - Parameters:
    ///   - payload: The frame payload, without the command and length bytes.
    ///   - penClockIsTrusted: Whether the pen's clock may be trusted for
    ///     cross-source deduplication.
    /// - Returns: The parsed strokes, or an explicit unsupported or error result.
    public static func parse(
        payload: [UInt8],
        penClockIsTrusted: Bool = true
    ) -> OfflineDataParseOutcome {
        guard payload.count >= OfflineDataHeader.payloadBytes else {
            return .error(
                .malformedPayload(command: .responseOfflineData, reason: "offline header is too short")
            )
        }

        guard let transferPosition = OfflineTransferPosition(rawValue: payload[7]) else {
            return .error(
                .malformedPayload(
                    command: .responseOfflineData,
                    reason: "offline transfer position \(payload[7]) is not a known value"
                )
            )
        }

        let header = OfflineDataHeader(
            packetID: PenWire.uint16(payload, at: 0),
            isCompressed: payload[2] != 0,
            sizeBeforeCompression: PenWire.uint16(payload, at: 3),
            sizeAfterCompression: PenWire.uint16(payload, at: 5),
            transferPosition: transferPosition,
            section: payload[11],
            owner: PenWire.uint32(payload, at: 8) & 0x00FF_FFFF,
            book: PenWire.uint32(payload, at: 12),
            strokeCount: PenWire.uint16(payload, at: 16)
        )

        guard !header.isCompressed else {
            return .unsupported(reason: "compressed offline payloads are not validated on the A1")
        }
        guard header.transferPosition == .end else {
            return .unsupported(
                reason: "multi-packet offline transfers are not validated on the A1"
            )
        }

        var records: [OfflineStrokeRecord] = []
        records.reserveCapacity(Int(header.strokeCount))
        var cursor = OfflineDataHeader.payloadBytes

        for _ in 0..<Int(header.strokeCount) {
            guard payload.count >= cursor + strokeRecordBytes else {
                return .error(
                    .malformedPayload(
                        command: .responseOfflineData,
                        reason: "offline stroke record is truncated"
                    )
                )
            }

            let pageID = PenWire.uint32(payload, at: cursor)
            let downTime = PenWire.int64(payload, at: cursor + 4)
            let upTime = PenWire.int64(payload, at: cursor + 12)
            let tipType = payload[cursor + 20]
            let dotCount = Int(PenWire.uint16(payload, at: cursor + 25))
            cursor += strokeRecordBytes

            guard payload.count >= cursor + dotCount * PenDot.offlinePayloadBytes else {
                return .error(
                    .malformedPayload(
                        command: .responseOfflineData,
                        reason: "offline dot data is truncated"
                    )
                )
            }

            var points: [PenPoint] = []
            points.reserveCapacity(dotCount)
            var penTime: Int64 = 0

            for _ in 0..<dotCount {
                let dotPayload = Array(payload[cursor..<(cursor + PenDot.offlinePayloadBytes)])
                cursor += PenDot.offlinePayloadBytes

                guard let dot = PenDot(payload: dotPayload) else {
                    return .error(
                        .malformedPayload(
                            command: .responseOfflineData,
                            reason: "offline dot payload is invalid"
                        )
                    )
                }
                penTime &+= Int64(dot.timeDeltaMilliseconds)

                let sample = RawPenSample(
                    integerX: dot.sample.integerX,
                    hundredthsX: dot.sample.hundredthsX,
                    integerY: dot.sample.integerY,
                    hundredthsY: dot.sample.hundredthsY,
                    penTimeOffsetMilliseconds: penTime,
                    pressure: dot.sample.pressure
                )
                guard let point = PenSampleNormalizer.normalize(sample) else {
                    return .error(
                        .malformedPayload(
                            command: .responseOfflineData,
                            reason: "offline coordinate hundredths are out of range"
                        )
                    )
                }
                points.append(point)
            }

            let page = PageIdentity(
                section: header.section,
                owner: header.owner,
                book: header.book,
                page: pageID
            )
            let origin: PenOriginTime = penClockIsTrusted
                ? .reliable(milliseconds: downTime)
                : .unreliable(reportedMilliseconds: downTime)

            records.append(
                OfflineStrokeRecord(
                    stroke: Stroke(page: page, originTime: origin, points: points, source: .offline),
                    upTimeMilliseconds: upTime,
                    tipType: tipType
                )
            )
        }

        return .strokes(header: header, records: records)
    }
}
