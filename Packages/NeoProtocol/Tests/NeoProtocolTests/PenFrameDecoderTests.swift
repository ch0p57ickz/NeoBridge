import XCTest

@testable import NeoProtocol

final class PenFrameDecoderTests: XCTestCase {
    private func decode(_ bytes: [UInt8], limits: FrameLimits = .default) -> [PenFrameDecodeOutcome] {
        var decoder = PenFrameDecoder(limits: limits)
        return decoder.ingest(bytes)
    }

    private func frames(_ outcomes: [PenFrameDecodeOutcome]) -> [PenFrame] {
        outcomes.compactMap { outcome in
            if case .frame(let frame) = outcome {
                return frame
            }
            return nil
        }
    }

    private func errors(_ outcomes: [PenFrameDecodeOutcome]) -> [PenProtocolError] {
        outcomes.compactMap { outcome in
            if case .error(let error) = outcome {
                return error
            }
            return nil
        }
    }

    func testEncodedFrameRoundTrips() throws {
        let payload: [UInt8] = [0x01, 0x02, 0x03, 0x04]
        let bytes = PenFrameEncoder.encode(command: .eventPenDotCode, payload: payload)

        XCTAssertEqual(bytes.first, PenFraming.start)
        XCTAssertEqual(bytes.last, PenFraming.end)

        let frame = try XCTUnwrap(frames(decode(bytes)).first)
        XCTAssertEqual(frame.command, .eventPenDotCode)
        XCTAssertEqual(frame.commandByte, PenCommand.eventPenDotCode.rawValue)
        XCTAssertEqual(frame.payload, payload)
    }

    func testFramingMarkersInsidePayloadAreEscapedAndRestored() throws {
        let payload: [UInt8] = [0xC0, 0xC1, 0x7D, 0x00, 0xFF]
        let bytes = PenFrameEncoder.encode(command: .eventPenNewId, payload: payload)

        // Every marker byte inside the body must be escaped.
        XCTAssertTrue(bytes.contains(0x7D))
        XCTAssertEqual(bytes.filter { $0 == 0xC0 }.count, 1, "only the start marker is unescaped")

        let frame = try XCTUnwrap(frames(decode(bytes)).first)
        XCTAssertEqual(frame.payload, payload)
    }

    func testChunkBoundariesDoNotAffectFraming() throws {
        let payload: [UInt8] = [0x11, 0x22, 0x33]
        let bytes = PenFrameEncoder.encode(command: .eventPenDotCode, payload: payload)

        var decoder = PenFrameDecoder()
        var outcomes: [PenFrameDecodeOutcome] = []
        for byte in bytes {
            outcomes.append(contentsOf: decoder.ingest([byte]))
        }

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(try XCTUnwrap(frames(outcomes).first).payload, payload)
    }

    func testEscapeStateSurvivesChunkBoundary() throws {
        let payload: [UInt8] = [0xC0, 0xC1]
        let bytes = PenFrameEncoder.encode(command: .eventPenNewId, payload: payload)

        // Split immediately after the escape byte so the escaped byte lands in
        // the next chunk.
        let escapeIndex = try XCTUnwrap(bytes.firstIndex(of: 0x7D))
        let split = escapeIndex + 1

        var decoder = PenFrameDecoder()
        var outcomes = decoder.ingest(Array(bytes[..<split]))
        outcomes.append(contentsOf: decoder.ingest(Array(bytes[split...])))

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(try XCTUnwrap(frames(outcomes).first).payload, payload)
    }

    func testTruncatedFrameReportsErrorAndRecovers() throws {
        let truncated = PenFrameEncoder.encode(command: .eventNewPenDot, payload: [0x01, 0x02, 0x03, 0x04])
        // Rewrite the declared length so it exceeds the payload that follows.
        var malformed = truncated
        malformed[2] = 0x40
        malformed[3] = 0x00

        let valid = PenFrameEncoder.encode(command: .responseVersionInfo, payload: [0xAA])
        let outcomes = decode(malformed + valid)

        XCTAssertEqual(outcomes.count, 2)
        XCTAssertEqual(errors(outcomes), [.truncatedPacket(declared: 64, available: 4)])
        XCTAssertEqual(frames(outcomes).first?.command, .responseVersionInfo)
    }

    func testTrailingPayloadBytesAreRejected() {
        let extra = PenFrameEncoder.encode(command: .eventNewPenDot, payload: [0x01, 0x02, 0x03, 0x04])
        var malformed = extra
        malformed[2] = 0x02
        malformed[3] = 0x00

        XCTAssertEqual(decode(malformed), [.error(.payloadLengthMismatch(declared: 2, available: 4))])
    }

    func testFrameShorterThanHeaderIsRejected() {
        let bytes: [UInt8] = [PenFraming.start, 0x01, PenFraming.end]
        XCTAssertEqual(decode(bytes), [.error(.packetTooShortForHeader(byteCount: 1))])
    }

    func testEmptyFrameIsRejected() {
        let bytes: [UInt8] = [PenFraming.start, PenFraming.end]
        XCTAssertEqual(decode(bytes), [.error(.packetTooShortForHeader(byteCount: 0))])
    }

    func testUnknownCommandStillProducesAFrame() throws {
        let bytes = PenFrameEncoder.encode(command: 0x99, payload: [0x01])
        let frame = try XCTUnwrap(frames(decode(bytes)).first)
        XCTAssertNil(frame.command)
        XCTAssertEqual(frame.commandByte, 0x99)
    }

    func testBytesOutsideAFrameAreIgnored() throws {
        let bytes: [UInt8] = [0x00, 0x11, PenFraming.start, 0x81, 0x01, 0x00, 0x42, PenFraming.end, 0x55]
        let frame = try XCTUnwrap(frames(decode(bytes)).first)
        XCTAssertEqual(frame.command, .responseVersionInfo)
        XCTAssertEqual(frame.payload, [0x42])
    }

    func testStrayEndMarkerProducesNoOutcome() {
        XCTAssertTrue(decode([PenFraming.end]).isEmpty)
        XCTAssertTrue(decode([PenFraming.end, PenFraming.end]).isEmpty)
    }

    func testStrayEscapeOutsideAFrameCannotSwallowTheNextFrame() throws {
        // An escape byte between frames must not consume the start marker that
        // follows it.
        let bytes: [UInt8] = [PenFraming.escape, PenFraming.start, 0x81, 0x01, 0x00, 0x42, PenFraming.end]
        let outcomes = decode(bytes)
        XCTAssertEqual(outcomes.count, 1)
        let frame = try XCTUnwrap(frames(outcomes).first)
        XCTAssertEqual(frame.command, .responseVersionInfo)
        XCTAssertEqual(frame.payload, [0x42])
    }

    func testPayloadOverLimitIsRejectedAndRecovers() throws {
        let limits = FrameLimits(maxPayloadBytes: 8, maxBufferedBytes: 1_024)
        let oversized = PenFrameEncoder.encode(command: .responseVersionInfo, payload: [UInt8](repeating: 0, count: 9))
        let valid = PenFrameEncoder.encode(command: .eventPenNewId, payload: [0x01])

        let outcomes = decode(oversized + valid, limits: limits)
        XCTAssertEqual(errors(outcomes), [.payloadExceedsLimit(declared: 9, limit: 8)])
        XCTAssertEqual(frames(outcomes).first?.command, .eventPenNewId)
    }

    func testBufferedInputOverLimitIsRejectedAndRecovers() throws {
        let limits = FrameLimits(maxPayloadBytes: 1_024, maxBufferedBytes: 16)
        let overflowing = PenFrameEncoder.encode(command: .responseVersionInfo, payload: [UInt8](repeating: 0, count: 32))
        let valid = PenFrameEncoder.encode(command: .eventPenNewId, payload: [0x01])

        let outcomes = decode(overflowing + valid, limits: limits)
        XCTAssertEqual(errors(outcomes), [.bufferedInputExceedsLimit(limit: 16)])
        XCTAssertEqual(frames(outcomes).first?.command, .eventPenNewId)
    }

    func testDefaultLimitAcceptsTheProtocolMaximumPayload() throws {
        // The declared length field is 16 bits, so the default limit is the
        // protocol's own maximum.
        XCTAssertEqual(FrameLimits.default.maxPayloadBytes, 65_535)
        XCTAssertEqual(FrameLimits.default.maxBufferedBytes, 131_072)

        let payload = [UInt8](repeating: 0x5A, count: 4_096)
        let frame = try XCTUnwrap(frames(decode(PenFrameEncoder.encode(command: .responseOfflineData, payload: payload))).first)
        XCTAssertEqual(frame.payload.count, 4_096)
    }

    func testResetDiscardsPartialFrame() throws {
        var decoder = PenFrameDecoder()
        _ = decoder.ingest([PenFraming.start, 0x81, 0x02, 0x00, 0x01])
        decoder.reset()

        let valid = PenFrameEncoder.encode(command: .eventPenNewId, payload: [0x09])
        let outcomes = decoder.ingest(valid)
        XCTAssertEqual(frames(outcomes).first?.payload, [0x09])
    }
}
