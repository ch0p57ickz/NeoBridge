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

    /// Encodes a frame for a command whose framing the evidence classifies.
    private func encoded(
        _ command: PenCommand,
        _ payload: [UInt8],
        errorCode: UInt8 = 0
    ) throws -> [UInt8] {
        try XCTUnwrap(
            PenFrameEncoder.encode(command: command, payload: payload, errorCode: errorCode),
            "\(command) has no framing evidence"
        )
    }

    func testEncodedFrameRoundTrips() throws {
        let payload: [UInt8] = [0x01, 0x02, 0x03, 0x04]
        let bytes = try encoded(.eventPenDotCode, payload)

        XCTAssertEqual(bytes.first, PenFraming.start)
        XCTAssertEqual(bytes.last, PenFraming.end)

        let frame = try XCTUnwrap(frames(decode(bytes)).first)
        XCTAssertEqual(frame.command, .eventPenDotCode)
        XCTAssertEqual(frame.commandByte, PenCommand.eventPenDotCode.rawValue)
        XCTAssertNil(frame.errorCode)
        XCTAssertEqual(frame.payload, payload)
    }

    func testResponseFrameRoundTripsWithItsErrorCode() throws {
        let payload: [UInt8] = [0x01, 0x02, 0x03, 0x04]
        let bytes = try encoded(.responseVersionInfo, payload, errorCode: 0x07)

        let frame = try XCTUnwrap(frames(decode(bytes)).first)
        XCTAssertEqual(frame.command, .responseVersionInfo)
        XCTAssertEqual(frame.errorCode, 0x07)
        XCTAssertEqual(frame.payload, payload)
    }

    func testAResponseBodyIsOneByteLongerThanAnEventBody() throws {
        // The response body carries an error code between the command and the
        // length, so the same payload occupies one more byte on the wire.
        let payload: [UInt8] = [0x01]
        let event = try encoded(.eventPenDotCode, payload)
        let response = try encoded(.responseVersionInfo, payload)

        XCTAssertEqual(response.count, event.count + 1)
    }

    func testUnclassifiedCommandCannotBeEncoded() {
        // The framing is unknown, so the encoder refuses instead of inventing one.
        XCTAssertNil(PenFrameEncoder.encode(command: .comparePassword, payload: [0x01]))
        XCTAssertNil(PenFrameEncoder.encode(command: .deleteOfflineNoteRequest, payload: [0x01]))
    }

    func testResponseHeaderMatchesTheCapturedResponseBytes() throws {
        // The physical A1 answers a version request with `81 00 46 00`: command
        // 0x81, error code 0, declared length 70.
        var bytes: [UInt8] = [PenFraming.start, 0x81, 0x00, 0x46, 0x00]
        bytes.append(contentsOf: [UInt8](repeating: 0xAB, count: 70))
        bytes.append(PenFraming.end)

        let frame = try XCTUnwrap(frames(decode(bytes)).first)
        XCTAssertEqual(frame.command, .responseVersionInfo)
        XCTAssertEqual(frame.errorCode, 0)
        XCTAssertEqual(frame.payload.count, 70)
        XCTAssertEqual(frame.payload.first, 0xAB)
        XCTAssertEqual(frame.payload.last, 0xAB)
    }

    func testEventFrameReadsTheLengthImmediatelyAfterTheCommand() throws {
        let bytes = try encoded(.eventNewPenDot, [0x01, 0x02, 0x03, 0x04])
        let frame = try XCTUnwrap(frames(decode(bytes)).first)
        XCTAssertNil(frame.errorCode)
        XCTAssertEqual(frame.payload, [0x01, 0x02, 0x03, 0x04])
    }

    func testOfflineDataFrameRecoversItsDeclaredPayload() throws {
        // The pen sends offline data on 0x24 with no error code, so the length
        // follows the command directly.
        var bytes: [UInt8] = [PenFraming.start, 0x24, 0x03, 0x00]
        bytes.append(contentsOf: [0xAA, 0xBB, 0xCC])
        bytes.append(PenFraming.end)

        let frame = try XCTUnwrap(frames(decode(bytes)).first)
        XCTAssertEqual(frame.command, .offlineDataRequest2)
        XCTAssertNil(frame.errorCode)
        XCTAssertEqual(frame.payload, [0xAA, 0xBB, 0xCC])
    }

    func testFramingMarkersInsidePayloadAreEscapedAndRestored() throws {
        let payload: [UInt8] = [0xC0, 0xC1, 0x7D, 0x00, 0xFF]
        let bytes = try encoded(.eventPenNewId, payload)

        // Every marker byte inside the body must be escaped.
        XCTAssertTrue(bytes.contains(0x7D))
        XCTAssertEqual(bytes.filter { $0 == 0xC0 }.count, 1, "only the start marker is unescaped")

        let frame = try XCTUnwrap(frames(decode(bytes)).first)
        XCTAssertEqual(frame.payload, payload)
    }

    func testChunkBoundariesDoNotAffectFraming() throws {
        let payload: [UInt8] = [0x11, 0x22, 0x33]
        let bytes = try encoded(.eventPenDotCode, payload)

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
        let bytes = try encoded(.eventPenNewId, payload)

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
        let truncated = try encoded(.eventNewPenDot, [0x01, 0x02, 0x03, 0x04])
        // Rewrite the declared length so it exceeds the payload that follows.
        var malformed = truncated
        malformed[2] = 0x40
        malformed[3] = 0x00

        let valid = try encoded(.responseVersionInfo, [0xAA])
        let outcomes = decode(malformed + valid)

        XCTAssertEqual(outcomes.count, 2)
        XCTAssertEqual(errors(outcomes), [.truncatedPacket(declared: 64, available: 4)])
        XCTAssertEqual(frames(outcomes).first?.command, .responseVersionInfo)
        XCTAssertEqual(frames(outcomes).first?.errorCode, 0)
    }

    func testTrailingPayloadBytesAreRejected() throws {
        let extra = try encoded(.eventNewPenDot, [0x01, 0x02, 0x03, 0x04])
        var malformed = extra
        malformed[2] = 0x02
        malformed[3] = 0x00

        XCTAssertEqual(decode(malformed), [.error(.payloadLengthMismatch(declared: 2, available: 4))])
    }

    func testFrameShorterThanHeaderIsRejected() {
        let bytes: [UInt8] = [PenFraming.start, 0x01, PenFraming.end]
        XCTAssertEqual(decode(bytes), [.error(.packetTooShortForHeader(byteCount: 1))])
    }

    func testResponseHeaderShorterThanFourBytesIsRejected() {
        // 0x81 is a response, so three body bytes cannot hold the error code and
        // the two-byte length.
        let bytes: [UInt8] = [PenFraming.start, 0x81, 0x00, 0x02, PenFraming.end]
        XCTAssertEqual(decode(bytes), [.error(.packetTooShortForHeader(byteCount: 3))])
    }

    func testEmptyFrameIsRejected() {
        let bytes: [UInt8] = [PenFraming.start, PenFraming.end]
        XCTAssertEqual(decode(bytes), [.error(.packetTooShortForHeader(byteCount: 0))])
    }

    func testUnknownCommandIsRejected() {
        // An identifier outside the command table has no known body layout, so
        // the position of its length field is unknown. The explicit-kind encoder
        // is what lets a test build such a frame at all.
        let bytes = PenFrameEncoder.encode(command: 0x99, payload: [0x42], kind: .event)
        XCTAssertEqual(decode(bytes), [.error(.unknownCommand(byte: 0x99))])
    }

    func testUnclassifiedCommandIsRejected() {
        // 0x02 (REQ_COMPARE_PWD) is in the command table, but the evidence does
        // not classify its framing, so the frame cannot be parsed either.
        let bytes: [UInt8] = [PenFraming.start, 0x02, 0x01, 0x00, 0x42, PenFraming.end]
        XCTAssertEqual(decode(bytes), [.error(.unknownCommand(byte: 0x02))])
    }

    func testARejectedFrameDoesNotStopTheNextFrame() throws {
        let rejected: [UInt8] = [PenFraming.start, 0x02, 0x01, 0x00, 0x42, PenFraming.end]
        let valid = try encoded(.eventPenNewId, [0x07])

        let outcomes = decode(rejected + valid)
        XCTAssertEqual(errors(outcomes), [.unknownCommand(byte: 0x02)])
        XCTAssertEqual(frames(outcomes).first?.payload, [0x07])
    }

    func testBytesOutsideAFrameAreIgnored() throws {
        let bytes: [UInt8] = [0x00, 0x11, PenFraming.start, 0x6B, 0x01, 0x00, 0x42, PenFraming.end, 0x55]
        let frame = try XCTUnwrap(frames(decode(bytes)).first)
        XCTAssertEqual(frame.command, .eventNewPenNewId)
        XCTAssertEqual(frame.payload, [0x42])
    }

    func testStrayEndMarkerProducesNoOutcome() {
        XCTAssertTrue(decode([PenFraming.end]).isEmpty)
        XCTAssertTrue(decode([PenFraming.end, PenFraming.end]).isEmpty)
    }

    func testStrayEscapeOutsideAFrameCannotSwallowTheNextFrame() throws {
        // An escape byte between frames must not consume the start marker that
        // follows it.
        let bytes: [UInt8] = [PenFraming.escape, PenFraming.start, 0x6B, 0x01, 0x00, 0x42, PenFraming.end]
        let outcomes = decode(bytes)
        XCTAssertEqual(outcomes.count, 1)
        let frame = try XCTUnwrap(frames(outcomes).first)
        XCTAssertEqual(frame.command, .eventNewPenNewId)
        XCTAssertEqual(frame.payload, [0x42])
    }

    func testPayloadOverLimitIsRejectedAndRecovers() throws {
        let limits = FrameLimits(maxPayloadBytes: 8, maxBufferedBytes: 1_024)
        let oversized = try encoded(.responseVersionInfo, [UInt8](repeating: 0, count: 9))
        let valid = try encoded(.eventPenNewId, [0x01])

        let outcomes = decode(oversized + valid, limits: limits)
        XCTAssertEqual(errors(outcomes), [.payloadExceedsLimit(declared: 9, limit: 8)])
        XCTAssertEqual(frames(outcomes).first?.command, .eventPenNewId)
    }

    func testBufferedInputOverLimitIsRejectedAndRecovers() throws {
        let limits = FrameLimits(maxPayloadBytes: 1_024, maxBufferedBytes: 16)
        let overflowing = try encoded(.responseVersionInfo, [UInt8](repeating: 0, count: 32))
        let valid = try encoded(.eventPenNewId, [0x01])

        let outcomes = decode(overflowing + valid, limits: limits)
        XCTAssertEqual(errors(outcomes), [.bufferedInputExceedsLimit(limit: 16)])
        XCTAssertEqual(frames(outcomes).first?.command, .eventPenNewId)
    }

    func testDefaultLimitsAcceptTheProtocolMaximumPayload() throws {
        // The declared length field is 16 bits, so the default payload limit is
        // the protocol's own maximum.
        XCTAssertEqual(FrameLimits.default.maxPayloadBytes, 65_535)
        XCTAssertEqual(FrameLimits.default.maxBufferedBytes, 131_072)

        let payload = [UInt8](repeating: 0x5A, count: 65_535)
        let outcomes = decode(try encoded(.responseOfflineData, payload))

        XCTAssertEqual(errors(outcomes), [])
        XCTAssertEqual(frames(outcomes).first?.payload.count, 65_535)
    }

    func testMaximumPayloadWithEveryByteEscapedIsStillDecoded() throws {
        // Byte stuffing doubles the frame's size on the wire, but the decoder
        // buffers decoded body bytes, so escaping does not consume the buffer
        // limit. A maximum payload needs only 4 + 65,535 buffered bytes, well
        // under the default 131,072.
        let payload = [UInt8](repeating: PenFraming.start, count: 65_535)
        let bytes = try encoded(.responseOfflineData, payload)

        // Start and end markers, a four-byte response header, and two wire bytes
        // per escaped payload byte.
        XCTAssertEqual(bytes.count, 131_076)

        let outcomes = decode(bytes)
        XCTAssertEqual(errors(outcomes), [])
        let frame = frames(outcomes).first
        XCTAssertEqual(frame?.payload.count, 65_535)
        XCTAssertEqual(frame?.payload.first, PenFraming.start)
        XCTAssertEqual(frame?.payload.last, PenFraming.start)
    }

    func testDefaultBufferedInputLimitIsEnforcedAndRecovers() throws {
        // A frame that never ends is discarded once the default 131,072-byte
        // buffer limit is crossed, and the next frame still parses.
        let runaway: [UInt8] = [PenFraming.start]
            + [UInt8](repeating: 0x00, count: FrameLimits.default.maxBufferedBytes + 1)
        let valid = try encoded(.eventPenNewId, [0x07])

        let outcomes = decode(runaway + valid)
        XCTAssertEqual(errors(outcomes), [.bufferedInputExceedsLimit(limit: 131_072)])
        XCTAssertEqual(frames(outcomes).first?.payload, [0x07])
    }

    func testBufferedLimitBoundaryIsExact() throws {
        let limits = FrameLimits(maxPayloadBytes: 64, maxBufferedBytes: 32)

        // A body of exactly 32 bytes fits; one byte more does not.
        let accepted = decode(
            try encoded(.eventPenNewId, [UInt8](repeating: 0x5A, count: 29)),
            limits: limits
        )
        XCTAssertEqual(errors(accepted), [])
        XCTAssertEqual(frames(accepted).count, 1)

        let rejected = decode(
            try encoded(.eventPenNewId, [UInt8](repeating: 0x5A, count: 30)),
            limits: limits
        )
        XCTAssertEqual(errors(rejected), [.bufferedInputExceedsLimit(limit: 32)])
        XCTAssertEqual(frames(rejected).count, 0)
    }

    func testResetDiscardsPartialFrame() throws {
        var decoder = PenFrameDecoder()
        _ = decoder.ingest([PenFraming.start, 0x81, 0x00, 0x02, 0x00, 0x01])
        decoder.reset()

        let valid = try encoded(.eventPenNewId, [0x09])
        let outcomes = decoder.ingest(valid)
        XCTAssertEqual(frames(outcomes).first?.payload, [0x09])
    }
}
