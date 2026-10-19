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

    /// The completed strokes a fixture yields.
    ///
    /// Offline data packets are parsed by `OfflineDataParser`; every other
    /// fixture is assembled from normalized events.
    static func strokes(
        _ fixture: ProtocolFixture,
        registry: CommandEvidenceRegistry = .neoSDK3
    ) throws -> [Stroke] {
        let frames = try frames(fixture)

        if let offlineFrame = frames.first(where: { $0.command == .responseOfflineData }) {
            switch OfflineDataParser.parse(payload: offlineFrame.payload) {
            case .strokes(_, let records):
                return records.map(\.stroke)
            case .unsupported(let reason):
                throw XCTSkip("offline transfer shape is unsupported: \(reason)")
            case .error(let error):
                throw error
            }
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
