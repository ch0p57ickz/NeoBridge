import Foundation
import NeoCore
import XCTest

@testable import NeoProtocol

/// Locates and replays the sanitized fixtures in `Tests/Fixtures`.
enum FixtureSupport {
    /// The repository fixture directory.
    ///
    /// The path is derived from this file's location so the tests do not depend
    /// on the process working directory.
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // NeoProtocolTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // NeoProtocol
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("Tests/Fixtures", isDirectory: true)
    }

    /// Every fixture, sorted by file name.
    static func all() throws -> [ProtocolFixture] {
        try ProtocolFixtureLoader.loadAll(in: directory)
    }

    /// Replays a fixture through the framing decoder.
    static func replay(_ fixture: ProtocolFixture) throws -> [PenFrameDecodeOutcome] {
        var decoder = PenFrameDecoder(limits: fixture.frameLimits)
        var outcomes: [PenFrameDecodeOutcome] = []
        for chunk in try fixture.decodedChunks() {
            outcomes.append(contentsOf: decoder.ingest(chunk))
        }
        return outcomes
    }

    /// The decoded frames of a fixture, ignoring errors.
    static func frames(_ fixture: ProtocolFixture) throws -> [PenFrame] {
        try replay(fixture).compactMap { outcome in
            if case .frame(let frame) = outcome {
                return frame
            }
            return nil
        }
    }

    /// The errors a fixture produces.
    static func errors(_ fixture: ProtocolFixture) throws -> [PenProtocolError] {
        try replay(fixture).compactMap { outcome in
            if case .error(let error) = outcome {
                return error
            }
            return nil
        }
    }

    /// The normalized pen events a fixture yields.
    static func events(
        _ fixture: ProtocolFixture,
        registry: CommandEvidenceRegistry = .neoSDK3
    ) throws -> [PenEvent] {
        var decoder = PenEventDecoder(registry: registry)
        var events: [PenEvent] = []

        for frame in try frames(fixture) {
            guard case .events(let decoded) = decoder.decode(frame) else {
                continue
            }
            events.append(contentsOf: decoded)
        }
        return events
    }

    /// Whether a frame carries offline stroke data.
    ///
    /// A physical A1 sends offline data as `REQ2_OFFLINE_DATA` (`0x24`).
    /// `RES2_OFFLINE_DATA` (`0xA4`) is the host's acknowledgement of that data, so
    /// an inbound `0xA4` is never data.
    static func isOfflineData(_ frame: PenFrame) -> Bool {
        frame.command == .offlineDataRequest2
    }

    /// The offline data packets of a fixture, in order.
    static func offlineDataFrames(_ fixture: ProtocolFixture) throws -> [PenFrame] {
        try frames(fixture).filter(isOfflineData)
    }

    /// The offline transfers a fixture carries, one packet group per transfer.
    ///
    /// A fixture can hold more than one transfer, because the pen restarts its
    /// packet identifiers for each note and each transfer is assembled on its
    /// own. A transfer opens at a `start` packet, at any packet when none is
    /// open, and closes at an `end` packet.
    static func offlineTransfers(_ fixture: ProtocolFixture) throws -> [[PenFrame]] {
        var transfers: [[PenFrame]] = []
        var current: [PenFrame] = []

        for frame in try offlineDataFrames(fixture) {
            guard case .strokes(let header, _) = OfflineDataParser.parse(payload: frame.payload) else {
                continue
            }

            if header.transferPosition == .start, !current.isEmpty {
                transfers.append(current)
                current = []
            }
            current.append(frame)
            if header.transferPosition == .end {
                transfers.append(current)
                current = []
            }
        }

        if !current.isEmpty {
            transfers.append(current)
        }
        return transfers
    }

    /// The completed strokes a fixture yields.
    ///
    /// Offline data packets are assembled by `OfflineTransferAssembler`; every
    /// other fixture is assembled from normalized events.
    static func strokes(
        _ fixture: ProtocolFixture,
        registry: CommandEvidenceRegistry = .neoSDK3
    ) throws -> [Stroke] {
        let frames = try frames(fixture)

        if !frames.filter(isOfflineData).isEmpty {
            var offlineStrokes: [Stroke] = []

            // Each transfer is assembled on its own, because the pen restarts
            // its packet identifiers per note.
            for transfer in try offlineTransfers(fixture) {
                var assembler = OfflineTransferAssembler()
                for frame in transfer {
                    switch assembler.ingest(payload: frame.payload) {
                    case .packet(let progress):
                        offlineStrokes.append(contentsOf: progress.records.map(\.stroke))
                    case .unsupported(let reason):
                        throw XCTSkip("offline transfer shape is unsupported: \(reason)")
                    case .error(let error):
                        throw error
                    }
                }

                // A partial transfer must not be mistaken for a complete import.
                if !assembler.isComplete {
                    throw XCTSkip("offline transfer never reached its end packet")
                }
            }
            return offlineStrokes
        }

        var assembler = StrokeAssembler()
        var strokes: [Stroke] = []

        for event in try events(fixture, registry: registry) {
            if case .completed(let stroke) = assembler.consume(event) {
                strokes.append(stroke)
            }
        }
        return strokes
    }

    /// A fixture by identifier.
    static func fixture(_ id: String, in fixtures: [ProtocolFixture]) throws -> ProtocolFixture {
        try XCTUnwrap(fixtures.first { $0.id == id }, "missing fixture \(id)")
    }

    /// The frames a transport sent, decoded rather than indexed.
    ///
    /// An outbound frame starts with the `0xC0` marker, so the first byte is
    /// never the command. Decoding also undoes byte stuffing, which indexing
    /// would not.
    static func outboundFrames(_ chunks: [[UInt8]]) -> [PenFrame] {
        chunks.compactMap { chunk in
            var decoder = PenFrameDecoder()
            guard case .frame(let frame)? = decoder.ingest(chunk).first else { return nil }
            return frame
        }
    }

    /// The command identifiers of the frames a transport sent, in order.
    static func outboundCommands(_ chunks: [[UInt8]]) -> [PenCommand?] {
        outboundFrames(chunks).map(\.command)
    }

    /// The `0x23` transfer option byte of every offline data request, in order.
    ///
    /// The option is the request payload's first byte, so a test can assert which
    /// transfer a read asked for without indexing into raw frames.
    static func outboundOptions(_ chunks: [[UInt8]]) -> [UInt8] {
        outboundFrames(chunks)
            .filter { $0.command == .offlineDataRequest1 }
            .compactMap { $0.payload.first }
    }

    /// Replaces every occurrence of one byte sequence with another of equal length.
    ///
    /// - Precondition: The replacement has the same length as the needle, so a
    ///   rewritten frame keeps its offsets.
    static func replacing(
        _ needle: [UInt8],
        with replacement: [UInt8],
        in bytes: [UInt8]
    ) -> [UInt8] {
        precondition(needle.count == replacement.count, "the replacement must not change the length")
        guard !needle.isEmpty, bytes.count >= needle.count else { return bytes }

        var result = bytes
        var index = 0
        while index <= result.count - needle.count {
            if Array(result[index..<(index + needle.count)]) == needle {
                result.replaceSubrange(index..<(index + needle.count), with: replacement)
                index += needle.count
            } else {
                index += 1
            }
        }
        return result
    }

    /// The acknowledgement bodies of the frames a transport sent, in order.
    static func outboundAcknowledgements(_ chunks: [[UInt8]]) -> [SentAcknowledgement] {
        outboundFrames(chunks)
            .filter { $0.command == .responseOfflineData }
            .map { frame in
                SentAcknowledgement(
                    packetID: PenWire.uint16(frame.payload, at: 0),
                    operation: PenTransferAcknowledgement(rawValue: frame.payload[2])
                )
            }
    }
}

/// One acknowledgement a session sent, as a test sees it.
struct SentAcknowledgement: Hashable, Sendable {
    /// The packet identifier the acknowledgement answers.
    let packetID: UInt16

    /// The acknowledgement operation, or `nil` when the byte is not a known one.
    let operation: PenTransferAcknowledgement?
}

/// An in-memory store used to prove offline import and replay behavior.
actor RecordingStrokeStore {
    private var fingerprints: [String] = []
    private var stored: [Stroke] = []

    /// Inserts strokes, skipping any whose fingerprint was already stored.
    ///
    /// A stroke whose origin time is not reliable is never deduplicated across
    /// sources, so it is always appended.
    func insert(_ strokes: [Stroke]) {
        for stroke in strokes {
            let fingerprint = StrokeIdentity.fingerprint(of: stroke)
            if fingerprint.allowsCrossSourceDeduplication, fingerprints.contains(fingerprint.hexDigest) {
                continue
            }
            fingerprints.append(fingerprint.hexDigest)
            stored.append(stroke)
        }
    }

    var count: Int { stored.count }
    var allStrokes: [Stroke] { stored }
    var allFingerprints: [String] { fingerprints }
}

/// A failure used to model a dropped connection.
enum TestTransportError: Error, Hashable {
    case connectionDropped
}
