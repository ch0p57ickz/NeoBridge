import NeoCore
import XCTest

@testable import NeoProtocol

final class ProtocolVersionTests: XCTestCase {
    func testParsesVersionText() {
        XCTAssertEqual(ProtocolVersion("2.18"), ProtocolVersion(major: 2, minor: 18))
        XCTAssertEqual(ProtocolVersion("2.18\0\0\0\0"), ProtocolVersion(major: 2, minor: 18))
        XCTAssertEqual(ProtocolVersion("  2.18  "), ProtocolVersion(major: 2, minor: 18))
        XCTAssertEqual(ProtocolVersion("10.0"), ProtocolVersion(major: 10, minor: 0))
    }

    func testRejectsInvalidVersionText() {
        XCTAssertNil(ProtocolVersion(""))
        XCTAssertNil(ProtocolVersion("\0\0\0"))
        XCTAssertNil(ProtocolVersion("2"))
        XCTAssertNil(ProtocolVersion("2."))
        XCTAssertNil(ProtocolVersion("2.18.1"))
        XCTAssertNil(ProtocolVersion("a.b"))
        XCTAssertNil(ProtocolVersion("-2.18"))
    }

    func testOrdering() {
        XCTAssertLessThan(ProtocolVersion(major: 2, minor: 9), ProtocolVersion(major: 2, minor: 18))
        XCTAssertLessThan(ProtocolVersion(major: 2, minor: 18), ProtocolVersion(major: 3, minor: 0))
    }

    func testDefaultPolicySupportsEveryValidatedMinor() {
        let policy = ProtocolVersionPolicy.neoSDK3
        XCTAssertEqual(policy.validatedMinors, [18, 23])

        // 2.18 is the version the SDK declares; 2.23 is what the physical A1
        // reported.
        for minor in [18, 23] {
            let version = ProtocolVersion(major: 2, minor: minor)
            let support = policy.support(for: version)
            XCTAssertTrue(support.isSupported, "2.\(minor) has wire evidence")
            XCTAssertEqual(support, .supported(version))
            XCTAssertEqual(support.version, version)
        }
    }

    func testUnvalidatedMinorIsUnsupported() {
        let policy = ProtocolVersionPolicy.neoSDK3
        // 2.25 is above the highest validated minor, but being newer is not
        // evidence, so it stays unsupported.
        for minor in [19, 25] {
            XCTAssertFalse(
                policy.support(for: ProtocolVersion(major: 2, minor: minor)).isSupported,
                "2.\(minor) has no evidence"
            )
        }
        XCTAssertEqual(
            policy.support(for: ProtocolVersion(major: 2, minor: 19)),
            .unsupported(ProtocolVersion(major: 2, minor: 19))
        )
    }

    func testOtherFamiliesAreUnsupported() {
        let policy = ProtocolVersionPolicy.neoSDK3
        XCTAssertEqual(policy.support(for: ProtocolVersion(major: 3, minor: 0)), .unsupported(ProtocolVersion(major: 3, minor: 0)))
        XCTAssertEqual(policy.support(for: nil), .unknown)
    }

    func testPolicyCanBeExtendedWithDeviceEvidence() {
        let policy = ProtocolVersionPolicy(validatedMinors: [18, 22])
        XCTAssertTrue(policy.support(for: ProtocolVersion(major: 2, minor: 22)).isSupported)
        XCTAssertFalse(policy.support(for: ProtocolVersion(major: 2, minor: 23)).isSupported)
    }
}

final class CommandEvidenceTests: XCTestCase {
    private let registry = CommandEvidenceRegistry.neoSDK3

    func testSDKDocumentedCommandsAreAuthorizedForProduction() {
        for command in [
            PenCommand.versionInfo,
            .responseVersionInfo,
            .eventPenUpDown,
            .eventNewPenDown,
            .eventNewPenUp,
            .eventPenNewId,
            .eventNewPenNewId,
            .eventPenDotCode,
            .eventNewPenDot,
            .responseOfflineData,
            .offlineDataRequest1
        ] {
            XCTAssertEqual(registry.authorization(for: command), .production, "\(command)")
            XCTAssertTrue(registry.maySendProductionRequest(command), "\(command)")
            XCTAssertTrue(registry.mayEmitCompletedStroke(command), "\(command)")
        }
    }

    func testProvisionalCommandsStayInspectionOnly() {
        let command = PenCommand.soundResponsePds
        guard case .inspectionOnly = registry.authorization(for: command) else {
            return XCTFail("expected inspectionOnly for \(command)")
        }
        XCTAssertFalse(registry.maySendProductionRequest(command))
        XCTAssertFalse(registry.mayEmitCompletedStroke(command))
        XCTAssertEqual(registry.evidence(for: command).level, .provisional)
    }

    func testDeletionCommandsAreBlocked() {
        for command in [PenCommand.deleteOfflineNoteRequest, .deleteOfflinePageRequest] {
            guard case .blocked = registry.authorization(for: command) else {
                return XCTFail("expected blocked for \(command)")
            }
            XCTAssertFalse(registry.maySendProductionRequest(command))
            XCTAssertFalse(registry.mayEmitCompletedStroke(command))
        }
    }

    func testAuthenticationWithoutFixtureEvidenceIsUnsupported() {
        let command = PenCommand.comparePassword
        guard case .unsupported = registry.authorization(for: command) else {
            return XCTFail("expected unsupported for \(command)")
        }
        XCTAssertEqual(registry.evidence(for: command).level, .none)
        XCTAssertFalse(registry.maySendProductionRequest(command))
    }

    func testUnregisteredCommandsAreUnsupported() {
        XCTAssertEqual(registry.evidence(for: .responseFirmwareFile1).level, .none)
        XCTAssertFalse(registry.maySendProductionRequest(.responseFirmwareFile1))
    }

    func testEvidenceSourcesAreRecorded() {
        let evidence = registry.evidence(for: .eventNewPenDot)
        XCTAssertEqual(evidence.level, .officialSDK)
        XCTAssertTrue(evidence.source.contains("iOS SDK 3.0"))
    }
}

final class PenEventDecoderTests: XCTestCase {
    private let page = PageIdentity(section: 3, owner: 0x000ABC, book: 7, page: 12)

    private func pageFrame(_ page: PageIdentity) -> PenFrame {
        var payload: [UInt8] = [0]
        payload.append(UInt8(page.owner & 0xFF))
        payload.append(UInt8((page.owner >> 8) & 0xFF))
        payload.append(UInt8((page.owner >> 16) & 0xFF))
        payload.append(page.section)
        payload.append(contentsOf: withUnsafeBytes(of: page.book.littleEndian) { Array($0) })
        payload.append(contentsOf: withUnsafeBytes(of: page.page.littleEndian) { Array($0) })
        return PenFrame(commandByte: PenCommand.eventNewPenNewId.rawValue, command: .eventNewPenNewId, payload: payload)
    }

    private func versionFrame(_ version: String) -> PenFrame {
        var payload = [UInt8](repeating: 0, count: 65)
        for (index, byte) in Array("Neo smartpen A1".utf8).enumerated() {
            payload[index] = byte
        }
        for (index, byte) in Array(version.utf8).enumerated() {
            payload[32 + index] = byte
        }
        return PenFrame(commandByte: PenCommand.responseVersionInfo.rawValue, command: .responseVersionInfo, payload: payload)
    }

    private func upDownFrame(direction: UInt8, time: Int64) -> PenFrame {
        var payload: [UInt8] = [direction]
        payload.append(contentsOf: withUnsafeBytes(of: UInt64(bitPattern: time).littleEndian) { Array($0) })
        payload.append(contentsOf: [UInt8](repeating: 0, count: 5))
        return PenFrame(commandByte: PenCommand.eventPenUpDown.rawValue, command: .eventPenUpDown, payload: payload)
    }

    private func dotFrame(delta: UInt8, x: UInt16, y: UInt16, pressure: UInt16) -> PenFrame {
        var payload: [UInt8] = [0, delta]
        payload.append(contentsOf: withUnsafeBytes(of: pressure.littleEndian) { Array($0) })
        payload.append(contentsOf: withUnsafeBytes(of: x.littleEndian) { Array($0) })
        payload.append(contentsOf: withUnsafeBytes(of: y.littleEndian) { Array($0) })
        payload.append(contentsOf: [25, 50, 90, 90])
        payload.append(contentsOf: [0, 0])
        return PenFrame(commandByte: PenCommand.eventNewPenDot.rawValue, command: .eventNewPenDot, payload: payload)
    }

    func testSupportedVersionIsObserved() {
        var decoder = PenEventDecoder()
        XCTAssertEqual(decoder.decode(versionFrame("2.18")), .versionObserved(ProtocolVersion(major: 2, minor: 18)))
        XCTAssertEqual(decoder.observedVersion, ProtocolVersion(major: 2, minor: 18))
        XCTAssertTrue(decoder.versionSupport.isSupported)
    }

    func testUnsupportedVersionIsReportedAndBlocksLaterFrames() {
        var decoder = PenEventDecoder()
        XCTAssertEqual(decoder.decode(versionFrame("3.0")), .error(.unsupportedVersion(ProtocolVersion(major: 3, minor: 0))))
        XCTAssertFalse(decoder.versionSupport.isSupported)

        // An unvalidated version must not be interpreted as a supported packet.
        XCTAssertEqual(decoder.decode(dotFrame(delta: 1, x: 10, y: 10, pressure: 10)), .error(.unsupportedVersion(ProtocolVersion(major: 3, minor: 0))))
    }

    func testUnvalidatedMinorVersionIsUnsupported() {
        var decoder = PenEventDecoder()
        XCTAssertEqual(decoder.decode(versionFrame("2.19")), .error(.unsupportedVersion(ProtocolVersion(major: 2, minor: 19))))
    }

    func testPageIsObserved() {
        var decoder = PenEventDecoder()
        XCTAssertEqual(decoder.decode(pageFrame(page)), .pageObserved(page))
        XCTAssertEqual(decoder.currentPage, page)
    }

    func testDotBeforePageIsIgnoredRatherThanFabricated() {
        var decoder = PenEventDecoder()
        let outcome = decoder.decode(dotFrame(delta: 1, x: 10, y: 10, pressure: 10))
        guard case .ignored = outcome else {
            return XCTFail("expected the dot to be ignored, got \(outcome)")
        }
        XCTAssertNil(decoder.currentPage)
    }

    func testUnknownCommandByteReturnsUnsupported() {
        var decoder = PenEventDecoder()
        let frame = PenFrame(commandByte: 0x99, command: nil, payload: [])
        XCTAssertEqual(decoder.decode(frame), .error(.unknownCommand(byte: 0x99)))
    }

    func testUnregisteredKnownCommandReturnsUnsupported() {
        var decoder = PenEventDecoder()
        let frame = PenFrame(commandByte: PenCommand.responseFirmwareFile1.rawValue, command: .responseFirmwareFile1, payload: [0])
        XCTAssertEqual(decoder.decode(frame), .error(.unsupportedCommand(command: .responseFirmwareFile1)))
    }

    func testBlockedCommandReturnsBlockedError() {
        var decoder = PenEventDecoder()
        let frame = PenFrame(commandByte: PenCommand.deleteOfflinePageRequest.rawValue, command: .deleteOfflinePageRequest, payload: [])
        guard case .error(.blockedCommand(let command, _)) = decoder.decode(frame) else {
            return XCTFail("expected a blocked command error")
        }
        XCTAssertEqual(command, .deleteOfflinePageRequest)
    }

    func testProvisionalCommandIsIgnoredAndCannotCompleteAStroke() {
        var decoder = PenEventDecoder()
        _ = decoder.decode(pageFrame(page))
        _ = decoder.decode(upDownFrame(direction: 0, time: 1_700_000_000_000))

        let provisional = PenFrame(
            commandByte: PenCommand.soundResponsePds.rawValue,
            command: .soundResponsePds,
            payload: [0x01, 0x02]
        )
        guard case .ignored = decoder.decode(provisional) else {
            return XCTFail("expected the provisional command to be ignored")
        }
        XCTAssertEqual(decoder.decode(upDownFrame(direction: 1, time: 1_700_000_000_050)), .events([
            PenEvent(
                context: PenEventContext(
                    page: page,
                    originTime: .reliable(milliseconds: 1_700_000_000_000),
                    source: .live
                ),
                phase: .up,
                point: nil
            )
        ]))
    }

    func testRealtimeSequenceAssemblesAStroke() {
        var decoder = PenEventDecoder()
        var assembler = StrokeAssembler()

        var outcomes: [PenDecodeOutcome] = [
            decoder.decode(pageFrame(page)),
            decoder.decode(upDownFrame(direction: 0, time: 1_700_000_000_000)),
            decoder.decode(dotFrame(delta: 10, x: 1_000, y: 500, pressure: 512)),
            decoder.decode(dotFrame(delta: 10, x: 1_001, y: 501, pressure: 600)),
            decoder.decode(upDownFrame(direction: 1, time: 1_700_000_000_050))
        ]
        XCTAssertEqual(outcomes.removeFirst(), .pageObserved(page))

        var completed: Stroke?
        for outcome in outcomes {
            guard case .events(let events) = outcome else {
                return XCTFail("expected events, got \(outcome)")
            }
            for event in events {
                if case .completed(let stroke) = assembler.consume(event) {
                    completed = stroke
                }
            }
        }

        guard let stroke = completed else {
            return XCTFail("expected a completed stroke")
        }
        XCTAssertEqual(stroke.page, page)
        XCTAssertEqual(stroke.originTime, .reliable(milliseconds: 1_700_000_000_000))
        XCTAssertEqual(stroke.points.count, 2)
        XCTAssertEqual(stroke.points.first?.x, 100_025)
        XCTAssertEqual(stroke.points.first?.y, 50_050)
        XCTAssertEqual(stroke.points.map(\.penTimeOffsetMilliseconds), [10, 20])
    }

    func testUntrustedPenClockProducesUnreliableOrigin() {
        var decoder = PenEventDecoder(penClockIsTrusted: false, source: .offline)
        _ = decoder.decode(pageFrame(page))
        guard case .events(let events) = decoder.decode(upDownFrame(direction: 0, time: 1_700_000_000_000)) else {
            return XCTFail("expected a down event")
        }
        XCTAssertEqual(events.first?.context.originTime, .unreliable(reportedMilliseconds: 1_700_000_000_000))
        XCTAssertEqual(events.first?.context.source, .offline)
        XCTAssertFalse(events.first?.context.originTime.isReliable ?? true)
    }

    func testProvisionalStrokeCommandsCannotCompleteAStroke() throws {
        // Every command in the realtime stroke sequence is marked provisional,
        // which is the situation the spec calls out: a mapping with no official
        // SDK evidence and no physical A1 validation.
        let provisionalCommands: [PenCommand] = [
            .responseVersionInfo,
            .eventNewPenNewId,
            .eventPenUpDown,
            .eventNewPenDot
        ]
        let registry = CommandEvidenceRegistry(
            entries: Dictionary(
                uniqueKeysWithValues: provisionalCommands.map {
                    ($0, CommandEvidence(command: $0, level: .provisional, source: "unvalidated mapping"))
                }
            )
        )

        for command in provisionalCommands {
            XCTAssertFalse(registry.maySendProductionRequest(command), "\(command)")
            XCTAssertFalse(registry.mayEmitCompletedStroke(command), "\(command)")
        }

        let fixture = try FixtureSupport.fixture("a1-realtime-stroke", in: FixtureSupport.all())

        // Positive control: the same bytes produce events and one completed
        // stroke when the commands carry official SDK evidence, so the zero
        // results below are attributable to the evidence level.
        XCTAssertGreaterThan(try FixtureSupport.events(fixture, registry: .neoSDK3).count, 0)
        XCTAssertEqual(try FixtureSupport.strokes(fixture, registry: .neoSDK3).count, 1)

        let provisionalEvents = try FixtureSupport.events(fixture, registry: registry)
        XCTAssertEqual(provisionalEvents.count, 0, "a provisional mapping must not emit pen events")
        XCTAssertEqual(
            try FixtureSupport.strokes(fixture, registry: registry).count,
            0,
            "a provisional mapping must not emit a completed stroke"
        )

        var provisionalDecoder = PenEventDecoder(registry: registry)
        for frame in try FixtureSupport.frames(fixture) {
            _ = provisionalDecoder.decode(frame)
        }
        XCTAssertNil(provisionalDecoder.observedVersion, "a provisional mapping must not report a version")
    }

    func testMalformedDotPayloadIsReported() {
        var decoder = PenEventDecoder()
        _ = decoder.decode(pageFrame(page))
        let frame = PenFrame(commandByte: PenCommand.eventNewPenDot.rawValue, command: .eventNewPenDot, payload: [0, 1])
        guard case .error(.malformedPayload(let command, _)) = decoder.decode(frame) else {
            return XCTFail("expected a malformed payload error")
        }
        XCTAssertEqual(command, .eventNewPenDot)
    }

    func testOutOfRangeHundredthsAreRejected() {
        var decoder = PenEventDecoder()
        _ = decoder.decode(pageFrame(page))
        var payload: [UInt8] = [0, 1, 0, 0, 10, 0, 10, 0]
        payload.append(contentsOf: [120, 50, 90, 90, 0, 0])
        let frame = PenFrame(commandByte: PenCommand.eventNewPenDot.rawValue, command: .eventNewPenDot, payload: payload)
        guard case .error(.malformedPayload) = decoder.decode(frame) else {
            return XCTFail("expected a malformed payload error")
        }
    }
}

/// Pins the framing each command identifier uses.
///
/// Source: Neo iOS SDK 3.0 `NISDK3/Classes/PenController/PenCommParser.swift`.
/// `parsePenDataPacket` reads the length from `data[1..2]` for every identifier
/// it parses as an event, and from `data[2..3]` for every identifier it parses
/// as a response, which is how a response's error code is skipped.
final class CommandFrameKindTests: XCTestCase {
    /// Identifiers the SDK parses with an error code between the command and the
    /// length, plus the host acknowledgement the capture settled.
    private let responses: [PenCommand] = [
        .responseVersionInfo,
        .responseComparePassword,
        .responseChangePassword,
        .responsePenState,
        .responseSetPenState,
        .responseSystemChange,
        .responseSystemInfo,
        .responseSetNoteList,
        .responseOfflineNoteList,
        .responseOfflinePageList,
        .responseOfflineDataInfo,
        .responseOfflineData,
        .responseDeleteOfflineNote,
        .responseDeleteOfflinePage,
        .responseFirmwareFile1,
        .responseFirmwareFile2,
        .responseProfile,
        .soundResponseLogInfo,
        .soundResponseLogData,
    ]

    /// Identifiers the SDK parses with the length immediately after the command,
    /// plus the requests the capture exercised the same way.
    private let events: [PenCommand] = [
        .eventBatteryAlarm,
        .eventPowerOff,
        .eventPenUpDown,
        .eventPenNewId,
        .eventPenDotCode,
        .eventPenDotCode2,
        .eventPenDotCode3,
        .eventDotError,
        .eventNewPenDown,
        .eventNewPenUp,
        .eventNewPenNewId,
        .eventNewPenDot,
        .eventNewDotError,
        .eventHoverDot,
        .offlineDataRequest2,
        .firmwareFileRequest2,
        .soundResponsePds,
        .soundResponseOid,
        .soundResponseStatus,
        .versionInfo,
        .offlineNoteListRequest,
        .offlinePageListRequest,
        .offlineDataRequest1,
    ]

    func testFramingMatchesTheSDKCaseList() {
        for command in responses {
            XCTAssertEqual(command.frameKind, .response, "\(command) carries an error code")
        }
        for command in events {
            XCTAssertEqual(command.frameKind, .event, "\(command) has no error code")
        }
    }

    func testTheSoundFamilyIsNotASinglePattern() {
        // A rule based on the identifier ranges or the SDK's naming would classify
        // these five together. The parser splits them, so a table is required.
        XCTAssertEqual(PenCommand.soundResponsePds.frameKind, .event)
        XCTAssertEqual(PenCommand.soundResponseOid.frameKind, .event)
        XCTAssertEqual(PenCommand.soundResponseStatus.frameKind, .event)
        XCTAssertEqual(PenCommand.soundResponseLogInfo.frameKind, .response)
        XCTAssertEqual(PenCommand.soundResponseLogData.frameKind, .response)
    }

    func testOfflineDataFramingIsTheHardwareObservedSplit() {
        // The pen sends the stroke data without an error code; the host's
        // acknowledgement of that same data carries one.
        XCTAssertEqual(PenCommand.offlineDataRequest2.rawValue, 0x24)
        XCTAssertEqual(PenCommand.offlineDataRequest2.frameKind, .event)
        XCTAssertEqual(PenCommand.responseOfflineData.rawValue, 0xA4)
        XCTAssertEqual(PenCommand.responseOfflineData.frameKind, .response)
    }

    func testUnvalidatedIdentifiersStayUnclassified() {
        // No framing evidence means no layout, so the decoder must reject the
        // frame rather than guess where its length field starts.
        let unclassified: [PenCommand] = [
            .comparePassword,
            .changePassword,
            .penState,
            .setPenState,
            .systemChange,
            .systemInfo,
            .setNoteList,
            .deleteOfflineNoteRequest,
            .deleteOfflinePageRequest,
            .firmwareFileRequest1,
            .profileRequest,
            .soundRequestLogInfo,
            .soundRequestLogData,
        ]
        for command in unclassified {
            XCTAssertNil(command.frameKind, "\(command) has no framing evidence")
        }
    }

    func testTheListsCoverEveryClassifiedIdentifier() {
        let listed = responses + events
        XCTAssertEqual(Set(listed).count, listed.count, "no identifier may be listed twice")
        XCTAssertEqual(
            listed.count,
            PenCommand.allCases.filter { $0.frameKind != nil }.count,
            "the lists must account for every classified identifier, so a new "
                + "classification cannot land without its source being recorded"
        )
    }
}

/// A response that reports a non-zero error code must fail rather than have its
/// payload decoded as data.
final class FailedResponseTests: XCTestCase {
    func testNonZeroErrorCodeProducesTheFailureAndNoEvents() {
        var decoder = PenEventDecoder()
        let frame = PenFrame(
            commandByte: PenCommand.responseVersionInfo.rawValue,
            command: .responseVersionInfo,
            errorCode: 0x05,
            payload: [0x00]
        )

        XCTAssertEqual(
            decoder.decode(frame),
            .error(.commandFailed(command: .responseVersionInfo, code: 0x05))
        )
        XCTAssertNil(decoder.observedVersion, "a failed response must not be decoded as data")
    }

    func testAZeroErrorCodeIsNotAFailure() {
        var decoder = PenEventDecoder()
        // A zero code means the pen accepted the command, so the payload is
        // decoded normally. An empty version payload is malformed, which proves
        // the frame reached the payload decoder.
        let frame = PenFrame(
            commandByte: PenCommand.responseVersionInfo.rawValue,
            command: .responseVersionInfo,
            errorCode: 0x00,
            payload: []
        )

        guard case .error(.malformedPayload) = decoder.decode(frame) else {
            return XCTFail("an empty version payload is malformed, not a command failure")
        }
    }

    func testAFailedResponseReachesTheTokenLayerFromRawBytes() throws {
        // `81 05 01 00 00`: a version response carrying error code 5 and a
        // one-byte payload, so the failure is proved from the wire bytes rather
        // than from a hand-built frame.
        let bytes: [UInt8] = [PenFraming.start, 0x81, 0x05, 0x01, 0x00, 0x00, PenFraming.end]

        var frameDecoder = PenFrameDecoder()
        let frames = frameDecoder.ingest(bytes).compactMap { outcome -> PenFrame? in
            if case .frame(let frame) = outcome {
                return frame
            }
            return nil
        }
        let frame = try XCTUnwrap(frames.first)
        XCTAssertEqual(frame.errorCode, 0x05)
        XCTAssertEqual(frame.payload, [0x00], "the payload starts after the error byte and the length")

        var tokenDecoder = PenEventDecoder()
        XCTAssertEqual(
            tokenDecoder.decode(frame),
            .error(.commandFailed(command: .responseVersionInfo, code: 0x05))
        )
        XCTAssertNil(tokenDecoder.observedVersion)
    }

    func testAFailedResponseOutranksAnUnsupportedVersion() {
        var decoder = PenEventDecoder()

        // Make the session unsupported: the pen reports protocol 9.99.
        let unsupported = PenFrame(
            commandByte: PenCommand.responseVersionInfo.rawValue,
            command: .responseVersionInfo,
            errorCode: 0,
            payload: versionPayload("9.99")
        )
        XCTAssertEqual(
            decoder.decode(unsupported),
            .error(.unsupportedVersion(ProtocolVersion(major: 9, minor: 99)))
        )

        // The next frame carries its own failure, so it is diagnosed as such
        // rather than as a version problem.
        let failed = PenFrame(
            commandByte: PenCommand.responseVersionInfo.rawValue,
            command: .responseVersionInfo,
            errorCode: 0x03,
            payload: versionPayload("9.99")
        )
        XCTAssertEqual(
            decoder.decode(failed),
            .error(.commandFailed(command: .responseVersionInfo, code: 0x03))
        )
    }

    /// A 65-byte version payload reporting `version`.
    private func versionPayload(_ version: String) -> [UInt8] {
        var payload = [UInt8](repeating: 0, count: 65)
        let text = Array(version.utf8)
        payload.replaceSubrange(32..<(32 + text.count), with: text)
        return payload
    }
}

/// The version payload layout.
///
/// Offsets come from the SDK's own `PenVersionInfo`: device name `0..<16`,
/// firmware `16..<32`, protocol version text `32..<40`, sub-name `40..<56`,
/// device type `56..<58`, Bluetooth address `58..<64`, pressure sensor type `64`,
/// and the compression capability byte at `69`. The SDK reads the capability byte
/// only when the payload is at least 70 bytes and the reported version is at least
/// 2.22.
final class PenVersionInfoTests: XCTestCase {
    private func payload(
        protocolVersion: String,
        compressionCapability: UInt8? = nil,
        length: Int
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: length)
        let text = Array(protocolVersion.utf8)
        if 32 + text.count <= length {
            bytes.replaceSubrange(32..<(32 + text.count), with: text)
        }
        if let compressionCapability, length > 69 {
            bytes[69] = compressionCapability
        }
        return bytes
    }

    func testCompressionCapabilityReportedAsClear() throws {
        let info = try XCTUnwrap(
            PenVersionInfo(payload: payload(protocolVersion: "2.23", compressionCapability: 0, length: 70))
        )
        XCTAssertFalse(info.supportsCompressedTransfer)
    }

    func testCompressionCapabilityReportedAsSet() throws {
        let info = try XCTUnwrap(
            PenVersionInfo(payload: payload(protocolVersion: "2.23", compressionCapability: 1, length: 70))
        )
        XCTAssertTrue(info.supportsCompressedTransfer)
    }

    func testCompressionCapabilityBelowTheSupportingMinorIsIgnored() throws {
        // The SDK reports the capability only from protocol 2.22, so a set byte
        // on an older version is not evidence of support.
        let info = try XCTUnwrap(
            PenVersionInfo(payload: payload(protocolVersion: "2.18", compressionCapability: 1, length: 70))
        )
        XCTAssertFalse(info.supportsCompressedTransfer)
    }

    func testCompressionCapabilityBoundaryIsExact() throws {
        // 2.22 is the minor the SDK starts reporting the capability from, so the
        // boundary itself is honoured and one minor below it is not.
        let atBoundary = try XCTUnwrap(
            PenVersionInfo(payload: payload(protocolVersion: "2.22", compressionCapability: 1, length: 70))
        )
        XCTAssertTrue(atBoundary.supportsCompressedTransfer)

        let belowBoundary = try XCTUnwrap(
            PenVersionInfo(payload: payload(protocolVersion: "2.21", compressionCapability: 1, length: 70))
        )
        XCTAssertFalse(belowBoundary.supportsCompressedTransfer)
    }

    func testAbsentCompressionCapabilityIsUnsupportedWithoutFailingThePayload() throws {
        // A payload that stops before the capability byte still parses, so a
        // shorter layout never fails the whole version response.
        for length in [64, 65, 69] {
            let info = try XCTUnwrap(
                PenVersionInfo(payload: payload(protocolVersion: "2.23", length: length)),
                "a \(length)-byte payload must still parse"
            )
            XCTAssertFalse(
                info.supportsCompressedTransfer,
                "a \(length)-byte payload has no capability byte"
            )
        }
    }

    func testPayloadShorterThanTheBaseLayoutIsRejected() {
        XCTAssertNil(PenVersionInfo(payload: [UInt8](repeating: 0, count: 63)))
    }
}
