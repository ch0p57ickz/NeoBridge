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

/// The header of an offline data packet.
///
/// The pen sends offline data as `REQ2_OFFLINE_DATA` (`0x24`) and the host
/// acknowledges each packet with `RES2_OFFLINE_DATA` (`0xA4`). A physical A1
/// capture on 2026-10-18 confirmed both directions.
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

/// Parses one offline data packet into domain strokes.
///
/// A packet is one slice of a transfer, so decoding one says nothing about
/// whether the whole transfer arrived. Callers that import offline data should
/// feed every packet to `OfflineTransferAssembler`, which tracks the sequence
/// and reports completion.
///
/// Uncompressed payloads are supported. Compressed payloads are reported as
/// unsupported because no physical A1 has been observed sending them: the
/// traced pen reports its compression capability byte clear and streams
/// uncompressed data.
public enum OfflineDataParser {
    /// Wire size of one stroke record header.
    static let strokeRecordBytes = 27

    /// Parses one `REQ2_OFFLINE_DATA` (`0x24`) packet payload.
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
                .malformedPayload(command: .offlineDataRequest2, reason: "offline header is too short")
            )
        }

        guard let transferPosition = OfflineTransferPosition(rawValue: payload[7]) else {
            return .error(
                .malformedPayload(
                    command: .offlineDataRequest2,
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

        var records: [OfflineStrokeRecord] = []
        records.reserveCapacity(Int(header.strokeCount))
        var cursor = OfflineDataHeader.payloadBytes

        for _ in 0..<Int(header.strokeCount) {
            guard payload.count >= cursor + strokeRecordBytes else {
                return .error(
                    .malformedPayload(
                        command: .offlineDataRequest2,
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
                        command: .offlineDataRequest2,
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
                            command: .offlineDataRequest2,
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
                            command: .offlineDataRequest2,
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

/// What one accepted packet contributes to an offline transfer.
public struct OfflineTransferProgress: Hashable, Sendable {
    /// The packet's header.
    public let header: OfflineDataHeader

    /// The strokes carried by this packet.
    public let records: [OfflineStrokeRecord]

    /// Whether this packet declared itself the last of the transfer.
    ///
    /// The host acknowledges this packet with `Stop` and every earlier packet
    /// with `Continue`.
    public let isTransferComplete: Bool

    /// How many packets were assembled, including this one.
    public let assembledPacketCount: Int

    /// How many strokes were assembled, including this packet's.
    public let assembledStrokeCount: Int

    /// How many dots were assembled, including this packet's.
    public let assembledDotCount: Int
}

/// The result of feeding one offline data packet to an assembler.
public enum OfflineTransferOutcome: Hashable, Sendable {
    /// The packet belongs to the transfer being assembled.
    case packet(OfflineTransferProgress)

    /// The packet uses a transfer shape this build has no evidence for.
    case unsupported(reason: String)

    /// The packet is malformed, or it does not fit the transfer in progress.
    case error(PenProtocolError)
}

/// Assembles the packets of one offline transfer into a stroke stream.
///
/// The pen sends one packet per host acknowledgement. Each packet carries an
/// identifier and a transfer position: `start` for the first, `middle` for the
/// rest, and `end` for the last. A 604-packet capture from a physical A1 on
/// 2026-10-18 ran its identifiers contiguously from 1 to 604 and ended with a
/// single `end` packet, so the assembler uses the identifier sequence to detect a
/// dropped packet instead of silently importing a hole.
///
/// A `start` packet is not required. A transfer that resumes after a reconnect
/// attaches mid-stream, which is also how the SDK parser treats the stream.
public struct OfflineTransferAssembler: Sendable {
    /// The number of packets assembled so far.
    public private(set) var assembledPacketCount = 0

    /// The number of strokes assembled so far.
    public private(set) var assembledStrokeCount = 0

    /// The number of dots assembled so far.
    public private(set) var assembledDotCount = 0

    /// Whether a packet declaring the transfer position `end` has arrived.
    public private(set) var isComplete = false

    private var lastPacketID: UInt16?

    /// Creates an assembler for one transfer.
    public init() {}

    /// Adds one offline data packet to the transfer.
    ///
    /// - Parameters:
    ///   - payload: The frame payload, without command, error, and length bytes.
    ///   - penClockIsTrusted: Whether the pen's clock may be trusted for
    ///     cross-source deduplication.
    /// - Returns: The packet's contribution, or an explicit unsupported or error
    ///   result.
    public mutating func ingest(
        payload: [UInt8],
        penClockIsTrusted: Bool = true
    ) -> OfflineTransferOutcome {
        guard !isComplete else {
            return .error(
                .malformedPayload(
                    command: .offlineDataRequest2,
                    reason: "an offline packet arrived after the transfer ended"
                )
            )
        }

        switch OfflineDataParser.parse(payload: payload, penClockIsTrusted: penClockIsTrusted) {
        case .unsupported(let reason):
            return .unsupported(reason: reason)

        case .error(let error):
            return .error(error)

        case .strokes(let header, let records):
            if let lastPacketID, lastPacketID &+ 1 != header.packetID {
                return .error(
                    .malformedPayload(
                        command: .offlineDataRequest2,
                        reason: "offline packet \(header.packetID) does not follow \(lastPacketID)"
                    )
                )
            }

            lastPacketID = header.packetID
            assembledPacketCount += 1
            assembledStrokeCount += records.count
            assembledDotCount += records.reduce(0) { total, record in
                total + record.stroke.points.count
            }
            let isTransferComplete = header.transferPosition == .end
            isComplete = isTransferComplete

            return .packet(
                OfflineTransferProgress(
                    header: header,
                    records: records,
                    isTransferComplete: isTransferComplete,
                    assembledPacketCount: assembledPacketCount,
                    assembledStrokeCount: assembledStrokeCount,
                    assembledDotCount: assembledDotCount
                )
            )
        }
    }
}
