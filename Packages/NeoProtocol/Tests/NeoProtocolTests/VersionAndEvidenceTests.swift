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

    func testDefaultPolicySupportsTheSDKProtocolVersionOnly() {
        let policy = ProtocolVersionPolicy.neoSDK3
        XCTAssertEqual(policy.validatedMinors, [18])
        let support = policy.support(for: ProtocolVersion(major: 2, minor: 18))
        XCTAssertTrue(support.isSupported)
        XCTAssertEqual(support, .supported(ProtocolVersion(major: 2, minor: 18)))
        XCTAssertEqual(support.version, ProtocolVersion(major: 2, minor: 18))
    }

    func testUnvalidatedMinorIsUnsupported() {
        let policy = ProtocolVersionPolicy.neoSDK3
        let support = policy.support(for: ProtocolVersion(major: 2, minor: 19))
        XCTAssertFalse(support.isSupported)
        XCTAssertEqual(support, .unsupported(ProtocolVersion(major: 2, minor: 19)))
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
