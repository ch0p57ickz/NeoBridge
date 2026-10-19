import NeoCore
import XCTest

@testable import NeoProtocol

final class OfflineIntegrationTests: XCTestCase {
    private func offlineFixture() throws -> ProtocolFixture {
        try FixtureSupport.fixture("a1-offline-stroke", in: FixtureSupport.all())
    }

    /// Runs an offline sync over a transport, returning the strokes the pen sent.
    private func syncOffline(transport: FakePenTransport) async throws -> [Stroke] {
        var frameDecoder = PenFrameDecoder()
        var strokes: [Stroke] = []

        for try await chunk in transport.receive() {
            for outcome in frameDecoder.ingest(chunk) {
                switch outcome {
                case .frame(let frame):
                    guard frame.command == .responseOfflineData else {
                        continue
                    }
                    switch OfflineDataParser.parse(payload: frame.payload) {
                    case .strokes(_, let records):
                        strokes.append(contentsOf: records.map(\.stroke))
                    case .unsupported(let reason):
                        throw OfflineSyncError.unsupportedTransfer(reason: reason)
                    case .error(let error):
                        throw error
                    }
                case .error(let error):
                    throw error
                }
            }
        }

        return strokes
    }

    func testOfflineImportFromFakeTransport() async throws {
        let fixture = try offlineFixture()
        let transport = FakePenTransport(chunks: try fixture.decodedChunks())
        let store = RecordingStrokeStore()

        let strokes = try await syncOffline(transport: transport)
        await store.insert(strokes)

        XCTAssertEqual(strokes.count, 1)
        let storedCount = await store.count
        XCTAssertEqual(storedCount, 1)
        XCTAssertEqual(transport.sentChunks.count, 0, "an import must not send requests")

        let stroke = try XCTUnwrap(strokes.first)
        XCTAssertEqual(stroke.source, .offline)
        XCTAssertEqual(stroke.points.count, 3)
    }

    func testDuplicateReplayProducesTheSameFingerprintAndIsDeduplicated() async throws {
        let fixture = try offlineFixture()
        let store = RecordingStrokeStore()

        let first = try await syncOffline(transport: FakePenTransport(chunks: try fixture.decodedChunks()))
        let second = try await syncOffline(transport: FakePenTransport(chunks: try fixture.decodedChunks()))

        await store.insert(first)
        await store.insert(second)

        let firstStroke = try XCTUnwrap(first.first)
        let secondStroke = try XCTUnwrap(second.first)
        XCTAssertEqual(
            StrokeIdentity.fingerprint(of: firstStroke),
            StrokeIdentity.fingerprint(of: secondStroke)
        )
        let storedCount = await store.count
        XCTAssertEqual(storedCount, 1, "a replayed offline stroke must deduplicate")
    }

    func testInterruptedSyncDoesNotCommitABatch() async throws {
        let fixture = try offlineFixture()
        let chunks = try fixture.decodedChunks()
        let whole = try XCTUnwrap(chunks.first)
        let split = whole.count / 2

        let transport = FakePenTransport(
            chunks: [Array(whole[..<split]), Array(whole[split...])],
            failure: TestTransportError.connectionDropped
        )
        let store = RecordingStrokeStore()
        var batch = ImportBatch()

        do {
            let strokes = try await syncOffline(transport: transport)
            try batch.transition(to: .validated)
            await store.insert(strokes)
            try batch.transition(to: .committed)
            XCTFail("expected the sync to fail before committing")
        } catch {
            // The batch stays uncommitted so the pen keeps its data.
        }

        XCTAssertEqual(batch.state, .collecting)
        let storedCount = await store.count
        XCTAssertEqual(storedCount, 0)
    }

    func testSyncRecoversAfterInterruption() async throws {
        let fixture = try offlineFixture()
        let chunks = try fixture.decodedChunks()
        let whole = try XCTUnwrap(chunks.first)
        let split = whole.count / 2

        let interrupted = FakePenTransport(
            chunks: [Array(whole[..<split])],
            failure: TestTransportError.connectionDropped
        )
        let store = RecordingStrokeStore()
        var batch = ImportBatch()

        do {
            _ = try await syncOffline(transport: interrupted)
            XCTFail("expected the interrupted sync to fail")
        } catch {
            // Expected: the connection dropped mid-frame.
        }
        let interruptedCount = await store.count
        XCTAssertEqual(interruptedCount, 0)

        // A fresh sync over the same fixture completes and commits.
        let recovered = try await syncOffline(transport: FakePenTransport(chunks: chunks))
        try batch.transition(to: .validated)
        await store.insert(recovered)
        try batch.transition(to: .committed)

        XCTAssertEqual(batch.state, .committed)
        let recoveredCount = await store.count
        XCTAssertEqual(recoveredCount, 1)
    }

    func testUnsupportedOfflineTransferShapeIsReported() throws {
        let fixture = try offlineFixture()
        let frame = try XCTUnwrap(FixtureSupport.frames(fixture).first { $0.command == .responseOfflineData })

        var payload = frame.payload
        payload[2] = 1 // compression flag
        guard case .unsupported(let reason) = OfflineDataParser.parse(payload: payload) else {
            return XCTFail("expected compressed payloads to be unsupported")
        }
        XCTAssertTrue(reason.contains("compressed"))

        payload[2] = 0
        payload[7] = OfflineTransferPosition.start.rawValue
        guard case .unsupported = OfflineDataParser.parse(payload: payload) else {
            return XCTFail("expected multi-packet transfers to be unsupported")
        }
    }

    func testUnknownOfflineTransferPositionIsRejected() throws {
        let fixture = try offlineFixture()
        let frame = try XCTUnwrap(FixtureSupport.frames(fixture).first { $0.command == .responseOfflineData })

        var payload = frame.payload
        payload[7] = 9
        guard case .error(let error) = OfflineDataParser.parse(payload: payload) else {
            return XCTFail("expected an unknown transfer position to be rejected")
        }
        XCTAssertEqual(
            error,
            .malformedPayload(
                command: .responseOfflineData,
                reason: "offline transfer position 9 is not a known value"
            )
        )
    }

    func testOfflineDotsRejectABadChecksum() throws {
        let fixture = try offlineFixture()
        let frame = try XCTUnwrap(FixtureSupport.frames(fixture).first { $0.command == .responseOfflineData })

        var payload = frame.payload
        payload[payload.count - 1] ^= 0xFF
        guard case .error(.malformedPayload) = OfflineDataParser.parse(payload: payload) else {
            return XCTFail("expected a malformed payload error for a bad dot checksum")
        }
    }

    func testUntrustedPenClockKeepsOfflineStrokesOutOfDeduplication() throws {
        let fixture = try offlineFixture()
        let frame = try XCTUnwrap(FixtureSupport.frames(fixture).first { $0.command == .responseOfflineData })

        guard case .strokes(_, let records) = OfflineDataParser.parse(
            payload: frame.payload,
            penClockIsTrusted: false
        ) else {
            return XCTFail("expected the offline payload to parse")
        }

        let stroke = try XCTUnwrap(records.first?.stroke)
        XCTAssertFalse(stroke.originTime.isReliable)
        XCTAssertFalse(StrokeIdentity.fingerprint(of: stroke).allowsCrossSourceDeduplication)
    }
}

/// A sync failure raised by the test harness.
enum OfflineSyncError: Error, Hashable {
    case unsupportedTransfer(reason: String)
}
