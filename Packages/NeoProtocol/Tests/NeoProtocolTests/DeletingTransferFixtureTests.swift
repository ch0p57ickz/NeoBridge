import Foundation
import NeoCore
import XCTest

@testable import NeoProtocol

/// Tests over the committed, sanitized deleting-transfer fixture pairs.
///
/// The fixtures are the portable form of the 2026-10-21 physical A1 evidence, so
/// these tests run without the git-ignored raw captures. They compare a deleting
/// transcript with its paired read-after transcript to establish what the pen
/// retained and what it removed.
final class DeletingTransferFixtureTests: XCTestCase {
    /// The fixture directory for the deleting-transfer pairs.
    private var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // NeoProtocolTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // NeoProtocol
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("Tests/Fixtures/deleting-transfer", isDirectory: true)
    }

    private func text(_ relativePath: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - Provenance

    /// The pairing and the identity the pair was recorded against.
    private struct Provenance: Decodable {
        struct Note: Decodable {
            let section: UInt8
            let owner: UInt32
            let note: UInt32
            let listedPages: [UInt32]
        }

        struct Packet: Decodable {
            let packetID: UInt16
            let strokes: Int
            let isEnd: Bool
        }

        struct Pair: Decodable {
            let id: String
            let deleting: String
            let readAfter: String
            let packetsReceived: Int
            let acknowledgedPackets: Int
            let packets: [Packet]
            let expectedRemainingStrokes: Int
            let expectedRemovedStrokes: Int
            let observedRemainingStrokeCount: Int
            let observedRemainingDotCount: Int
        }

        struct Info: Decodable {
            let errorCode: Int
            let claimedStrokes: Int
            let uncompressedBytes: Int
            let compressed: Bool
        }

        let fixtureVersion: Int
        let captureDate: String
        let deviceModel: String
        let firmware: String
        let observedProtocolVersion: String
        let transferOption: String
        let note: Note
        let requestFrame: String
        let info: Info
        let baseline: String
        let baselineStrokeCount: Int
        let baselineDotCount: Int
        let pairs: [Pair]
        let rawSource: String
        let evidence: Evidence

        struct Evidence: Decodable {
            let protocolDocument: String
            let section: String
            let transferEvidence: String
        }
    }

    private func provenance() throws -> Provenance {
        let data = try Data(contentsOf: directory.appendingPathComponent("provenance.json"))
        return try JSONDecoder().decode(Provenance.self, from: data)
    }

    func testProvenanceNamesTheTracedIdentityAndItsPairing() throws {
        let record = try provenance()

        XCTAssertEqual(record.fixtureVersion, 1)
        XCTAssertEqual(record.captureDate, "2026-10-21")
        XCTAssertEqual(record.deviceModel, PenDeletingTransferIdentity.physicalA1_2026_10_21.deviceName)
        XCTAssertEqual(record.firmware, PenDeletingTransferIdentity.physicalA1_2026_10_21.firmwareVersion)
        XCTAssertEqual(
            record.observedProtocolVersion,
            PenDeletingTransferIdentity.physicalA1_2026_10_21.protocolVersion
        )
        XCTAssertFalse(PenDeletingTransferIdentity.physicalA1_2026_10_21.isCompressed)
        XCTAssertEqual(record.transferOption, "0x01")
        XCTAssertEqual(record.evidence.section, "Deleting transfer option, 2026-10-21")
        XCTAssertEqual(record.evidence.transferEvidence, "PenDeletingTransferEvidence.physicalTrace2026_10_21")

        // Two pairs, one per acknowledgement boundary, and every file they name is
        // committed beside the record.
        XCTAssertEqual(record.pairs.map(\.id), ["withheld-packet-1", "withheld-packet-2"])
        for pair in record.pairs {
            XCTAssertNoThrow(try text(pair.deleting))
            XCTAssertNoThrow(try text(pair.readAfter))
        }
        XCTAssertNoThrow(try text(record.baseline))
    }

    func testTheFixturesAreSanitizedAndSelfContained() throws {
        let record = try provenance()
        let files = [record.baseline]
            + record.pairs.flatMap { [$0.deleting, $0.readAfter] }

        // A twelve-hex-digit run is the shape of a Bluetooth address, and a UUID
        // is the shape of a host-side identifier. Neither may appear.
        let addressLike = try NSRegularExpression(pattern: "\\b[0-9A-Fa-f]{12}\\b")
        let uuidLike = try NSRegularExpression(
            pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}"
        )

        for file in files {
            let contents = try text(file)
            XCTAssertFalse(contents.isEmpty, "\(file) is empty")
            let range = NSRange(contents.startIndex..., in: contents)

            XCTAssertEqual(
                addressLike.numberOfMatches(in: contents, range: range),
                0,
                "\(file) carries an address-shaped token"
            )
            XCTAssertEqual(
                uuidLike.numberOfMatches(in: contents, range: range),
                0,
                "\(file) carries a host identifier"
            )
            XCTAssertFalse(contents.lowercased().contains("serial"), "\(file) names a serial")
            XCTAssertFalse(contents.lowercased().contains("password"), "\(file) names credentials")
            XCTAssertTrue(
                contents.unicodeScalars.allSatisfy { $0 == "\n" || $0 == "\t" || $0.value >= 0x20 },
                "\(file) must be plain text so it is readable in review"
            )
            XCTAssertFalse(
                contents.contains("Tests/Fixtures/raw"),
                "\(file) must not point at a git-ignored capture"
            )
        }
    }

    // MARK: - The deleting transcript

    func testEveryDeletingTranscriptRequestsTheTracedOptionAndIsAccepted() throws {
        let record = try provenance()

        for pair in record.pairs {
            let transcript = try DeletingTranscript(text: try text(pair.deleting))

            XCTAssertEqual(
                transcript.requestFrame,
                record.requestFrame,
                "\(pair.id) must send the traced 0x23 frame"
            )
            XCTAssertEqual(transcript.transferOption, "0x01")
            XCTAssertEqual(transcript.infoErrorCode, 0)
            XCTAssertEqual(transcript.claimedStrokes, record.info.claimedStrokes)
            XCTAssertEqual(transcript.uncompressedBytes, record.info.uncompressedBytes)
            XCTAssertFalse(transcript.compressed, "the traced transfer was uncompressed")

            // One 0x24 per 0xA4: the pen sends exactly one packet per
            // acknowledgement, so the assembled packet count equals the received
            // count and never exceeds the acknowledged count plus the withheld one.
            XCTAssertEqual(transcript.receivedPackets, pair.packetsReceived)
            XCTAssertEqual(transcript.acknowledgedPackets, pair.acknowledgedPackets)
            XCTAssertEqual(
                transcript.assembledPackets,
                pair.packetsReceived,
                "\(pair.id) assembled a packet per received packet"
            )
            XCTAssertEqual(
                transcript.strokesSoFar,
                pair.packets.reduce(0) { $0 + $1.strokes },
                "\(pair.id) handed over every stroke of the packets it received"
            )
            XCTAssertTrue(transcript.aborted, "\(pair.id) ended by closing the link")
            XCTAssertFalse(transcript.stopSent, "no Stop is sent when a transfer is abandoned")
        }
    }

    func testEveryDeletingTranscriptWithholdsExactlyOneAcknowledgement() throws {
        let record = try provenance()

        for pair in record.pairs {
            let transcript = try DeletingTranscript(text: try text(pair.deleting))

            XCTAssertEqual(
                transcript.acknowledgedPackets,
                pair.packetsReceived - 1,
                "\(pair.id) acknowledges every packet but the last it received"
            )
            XCTAssertEqual(transcript.withheldPacketID, pair.packets.last?.packetID)
            XCTAssertEqual(
                transcript.withheldStrokes,
                pair.packets.last?.strokes,
                "\(pair.id) withholds the acknowledgement for the packet it names"
            )
        }
    }

    // MARK: - The paired read-after

    func testTheBaselineIsTheWholeNoteBeforeAnyDeletingTransfer() throws {
        let record = try provenance()
        let baseline = try ReadTranscript(text: try text(record.baseline))

        XCTAssertEqual(baseline.strokeCount, record.baselineStrokeCount)
        XCTAssertEqual(baseline.dotCount, record.baselineDotCount)
        XCTAssertEqual(baseline.strokes.count, 18)
        XCTAssertEqual(baseline.pageStrokeCounts, [36: 9, 37: 9])
        XCTAssertEqual(baseline.identity, PenDeletingTransferIdentity.physicalA1_2026_10_21)
        XCTAssertEqual(baseline.noteListedPages, [36, 37])
        XCTAssertEqual(baseline.noteStrokes, 18)
    }

    func testTheReadAfterWithoutAnAcknowledgementRetainsEveryStroke() throws {
        let record = try provenance()
        let pair = try XCTUnwrap(record.pairs.first { $0.id == "withheld-packet-1" })
        let baseline = try ReadTranscript(text: try text(record.baseline))
        let readAfter = try ReadTranscript(text: try text(pair.readAfter))

        // The pen handed over 13 strokes and was never acknowledged for them, and
        // the read afterwards found all 18 starting strokes, including those 13.
        XCTAssertEqual(pair.acknowledgedPackets, 0)
        XCTAssertEqual(readAfter.strokes, baseline.strokes, "nothing may be removed without an acknowledgement")
        XCTAssertEqual(readAfter.strokes.count, pair.expectedRemainingStrokes)
        XCTAssertEqual(readAfter.dotCount, pair.observedRemainingDotCount)

        let handedOver = Set(baseline.strokes.prefix(13).map(\.fingerprint))
        XCTAssertEqual(handedOver.count, 13)
        XCTAssertTrue(
            handedOver.isSubset(of: Set(readAfter.strokes.map(\.fingerprint))),
            "the 13 handed-over strokes must still be on the pen"
        )
    }

    func testTheReadAfterOneAcknowledgementRetainsOnlyTheUnacknowledgedPacket() throws {
        let record = try provenance()
        let pair = try XCTUnwrap(record.pairs.first { $0.id == "withheld-packet-2" })
        let baseline = try ReadTranscript(text: try text(record.baseline))
        let readAfter = try ReadTranscript(text: try text(pair.readAfter))

        // The pen streams a note's strokes in transfer order, so the first packet
        // is the baseline's first 13 strokes and the second is the remaining 5.
        let firstPacket = baseline.strokes.prefix(13)
        let secondPacket = baseline.strokes.suffix(5)
        XCTAssertEqual(pair.packets.map(\.strokes), [13, 5])
        XCTAssertEqual(secondPacket.count, 5)

        XCTAssertEqual(
            readAfter.strokes.map(\.fingerprint),
            secondPacket.map(\.fingerprint),
            "only the unacknowledged packet's strokes may remain"
        )
        XCTAssertEqual(readAfter.strokes.count, pair.expectedRemainingStrokes)
        XCTAssertEqual(readAfter.dotCount, pair.observedRemainingDotCount)
        XCTAssertEqual(readAfter.pageStrokeCounts, [37: 5])

        let removed = Set(firstPacket.map(\.fingerprint))
        XCTAssertEqual(removed.count, pair.expectedRemovedStrokes)
        XCTAssertTrue(
            removed.isDisjoint(with: Set(readAfter.strokes.map(\.fingerprint))),
            "the acknowledged packet's strokes must be gone"
        )
    }

    func testEveryPairedReadAfterReportsTheTracedIdentityAndTheNote() throws {
        let record = try provenance()

        for pair in record.pairs {
            let readAfter = try ReadTranscript(text: try text(pair.readAfter))

            XCTAssertEqual(readAfter.identity, PenDeletingTransferIdentity.physicalA1_2026_10_21)
            XCTAssertEqual(
                readAfter.noteListedPages,
                readAfter.pageStrokeCounts.keys.sorted(),
                "\(pair.id) lists exactly the pages it still found"
            )
            XCTAssertTrue(
                Set(readAfter.noteListedPages).isSubset(of: Set(record.note.listedPages)),
                "\(pair.id) may only list pages of the traced note"
            )
            XCTAssertEqual(
                readAfter.strokes.count,
                pair.observedRemainingStrokeCount,
                "\(pair.id) reports the inventory it measured"
            )
            XCTAssertEqual(readAfter.noteStrokes, readAfter.strokes.count)

            // A read-after is an ordinary non-destructive read: it asks with the
            // established option and sends no deleting request or deletion command.
            XCTAssertFalse(
                readAfter.outboundCommands.contains("0x25"),
                "\(pair.id) must send no 0x25"
            )
            XCTAssertFalse(
                readAfter.outboundCommands.contains("0x27"),
                "\(pair.id) must send no 0x27"
            )
            XCTAssertTrue(readAfter.outboundCommands.contains("0xA4"))
        }
    }

    // MARK: - Transcript parsers

    /// The fields a deleting transcript records.
    private struct DeletingTranscript {
        let requestFrame: String
        let transferOption: String
        let infoErrorCode: Int
        let claimedStrokes: Int
        let uncompressedBytes: Int
        let compressed: Bool
        let receivedPackets: Int
        let acknowledgedPackets: Int
        let assembledPackets: Int
        let strokesSoFar: Int
        let withheldPacketID: UInt16?
        let withheldStrokes: Int
        let aborted: Bool
        let stopSent: Bool

        init(text: String) throws {
            let lines = text.split(separator: "\n").map(String.init)
            let request = try XCTUnwrap(
                lines.first { $0.contains("plan next-delete-0x23 request=") }
            )
            let requestFields = Self.fields(of: request)
            requestFrame = try XCTUnwrap(requestFields["frame"])
            transferOption = try XCTUnwrap(requestFields["transferOption"])

            let info = try XCTUnwrap(lines.first { $0.contains("response next-delete-0x23 info") })
            let infoFields = Self.fields(of: info)
            claimedStrokes = try XCTUnwrap(infoFields["claimedStrokes"].flatMap(Int.init))
            uncompressedBytes = try XCTUnwrap(infoFields["uncompressedBytes"].flatMap(Int.init))
            compressed = infoFields["compressed"] == "true"

            let response = try XCTUnwrap(lines.first { $0.contains("response next-delete-0x23 error=") })
            infoErrorCode = Int(
                try XCTUnwrap(Self.fields(of: response)["error"]).replacingOccurrences(of: "0x", with: ""),
                radix: 16
            ) ?? -1

            let withholding = try XCTUnwrap(lines.first { $0.contains("transfer withholding") })
            let withholdingFields = Self.fields(of: withholding)
            withheldPacketID = withholdingFields["packetID"].flatMap(UInt16.init)
            withheldStrokes = try XCTUnwrap(withholdingFields["strokesInPacket"].flatMap(Int.init))
            strokesSoFar = try XCTUnwrap(withholdingFields["strokesSoFar"].flatMap(Int.init))

            let result = try XCTUnwrap(lines.first { $0.contains("transfer result") })
            let resultFields = Self.fields(of: result)
            receivedPackets = try XCTUnwrap(resultFields["packets"].flatMap(Int.init))
            acknowledgedPackets = try XCTUnwrap(resultFields["acknowledged"].flatMap(Int.init))
            assembledPackets = try XCTUnwrap(resultFields["assembledPackets"].flatMap(Int.init))
            aborted = resultFields["aborted"] == "true"
            stopSent = resultFields["stopSent"] == "true"
        }

        /// The `key=value` tokens of one transcript line.
        private static func fields(of line: String) -> [String: String] {
            var fields: [String: String] = [:]
            for token in line.split(separator: " ") {
                guard let separator = token.firstIndex(of: "=") else { continue }
                fields[String(token[token.startIndex..<separator])] = String(
                    token[token.index(after: separator)...]
                )
            }
            return fields
        }
    }

    /// The fields a read-after transcript records.
    private struct ReadTranscript {
        struct StrokeEntry: Equatable {
            let page: UInt32
            let index: Int
            let dots: Int
            let fingerprint: String
        }

        let identity: PenDeletingTransferIdentity
        let strokeCount: Int
        let dotCount: Int
        let noteStrokes: Int
        let noteListedPages: [UInt32]
        let pageStrokeCounts: [UInt32: Int]
        let strokes: [StrokeEntry]
        let outboundCommands: [String]

        init(text: String) throws {
            let lines = text.split(separator: "\n").map(String.init)

            let version = try XCTUnwrap(lines.first { $0.hasPrefix("version ") })
            let versionFields = Self.fields(of: version)
            identity = PenDeletingTransferIdentity(
                deviceName: try XCTUnwrap(versionFields["name"]),
                firmwareVersion: try XCTUnwrap(versionFields["firmware"]),
                protocolVersion: try XCTUnwrap(versionFields["text"]),
                isCompressed: false
            )

            let result = try XCTUnwrap(lines.first { $0.hasPrefix("result ") })
            let resultFields = Self.fields(of: result)
            strokeCount = try XCTUnwrap(resultFields["strokes"].flatMap(Int.init))
            dotCount = try XCTUnwrap(resultFields["dots"].flatMap(Int.init))

            let note = try XCTUnwrap(lines.first { $0.hasPrefix("note ") })
            let noteFields = Self.fields(of: note)
            noteStrokes = try XCTUnwrap(noteFields["strokes"].flatMap(Int.init))
            noteListedPages = try XCTUnwrap(noteFields["listedPages"])
                .split(separator: ",")
                .compactMap { UInt32($0) }

            var pageCounts: [UInt32: Int] = [:]
            for line in lines where line.hasPrefix("page ") {
                let fields = Self.fields(of: line)
                pageCounts[try XCTUnwrap(fields["page"].flatMap(UInt32.init))] =
                    try XCTUnwrap(fields["strokes"].flatMap(Int.init))
            }
            pageStrokeCounts = pageCounts

            strokes = try lines.filter { $0.hasPrefix("stroke ") }.map { line in
                let fields = Self.fields(of: line)
                return StrokeEntry(
                    page: try XCTUnwrap(fields["page"].flatMap(UInt32.init)),
                    index: try XCTUnwrap(fields["index"].flatMap(Int.init)),
                    dots: try XCTUnwrap(fields["dots"].flatMap(Int.init)),
                    fingerprint: try XCTUnwrap(fields["fp"])
                )
            }

            let commands = try XCTUnwrap(lines.first { $0.hasPrefix("outboundCommands ") })
            outboundCommands = commands
                .replacingOccurrences(of: "outboundCommands ", with: "")
                .split(separator: ",")
                .map(String.init)
        }

        /// The `key=value` tokens of one transcript line.
        private static func fields(of line: String) -> [String: String] {
            var fields: [String: String] = [:]
            for token in line.split(separator: " ") {
                guard let separator = token.firstIndex(of: "=") else { continue }
                fields[String(token[token.startIndex..<separator])] = String(
                    token[token.index(after: separator)...]
                )
            }
            return fields
        }
    }
}
