import Foundation
import NeoCore
import XCTest

@testable import NeoProtocol

final class FixtureReplayTests: XCTestCase {
    private let requiredSanitizationCategories: Set<String> = [
        "bluetoothAddress",
        "serialNumber",
        "authenticationMaterial",
        "handwritingContent"
    ]

    func testFixturesArePresent() throws {
        let fixtures = try FixtureSupport.all()
        XCTAssertGreaterThanOrEqual(fixtures.count, 6)
        XCTAssertEqual(Set(fixtures.map(\.id)).count, fixtures.count, "fixture identifiers must be unique")
        XCTAssertEqual(
            Set(fixtures.map(\.evidenceLevel)),
            [.officialSDK, .physicalDevice],
            "the set holds SDK-derived fixtures and the capture-derived handshake"
        )
    }

    func testFixtureReplayMatchesExpectedOutcomes() throws {
        for fixture in try FixtureSupport.all() {
            let outcomes = try FixtureSupport.replay(fixture)
            XCTAssertEqual(outcomes.count, fixture.expected.count, "\(fixture.id): outcome count")

            for (index, expected) in fixture.expected.enumerated() {
                let outcome = outcomes[index]
                switch (outcome, expected.kind) {
                case (.frame(let frame), "packet"):
                    let expectedByte = try XCTUnwrap(expected.byte, "\(fixture.id): command byte")
                    XCTAssertEqual(frame.commandByte, expectedByte, "\(fixture.id): command byte")
                    XCTAssertEqual(
                        frame.errorCode.map(Int.init),
                        expected.errorCode,
                        "\(fixture.id): error code"
                    )
                    XCTAssertEqual(
                        HexCoding.encode(frame.payload),
                        expected.payloadHex,
                        "\(fixture.id): payload"
                    )
                case (.error(let error), "error"):
                    XCTAssertEqual(error.kind, expected.error, "\(fixture.id): error kind")
                default:
                    XCTFail("\(fixture.id): unexpected outcome \(outcome) for \(expected.kind)")
                }
            }
        }
    }

    func testFixtureReplayIsRepeatable() throws {
        for fixture in try FixtureSupport.all() {
            let first = try FixtureSupport.replay(fixture)
            let second = try FixtureSupport.replay(fixture)
            XCTAssertEqual(first, second, "\(fixture.id): repeated runs must match")
        }
    }

    func testFixtureFramesDecodeToExpectedDomainState() throws {
        for fixture in try FixtureSupport.all() {
            var decoder = PenEventDecoder()
            for frame in try FixtureSupport.frames(fixture) {
                _ = decoder.decode(frame)
            }

            if let expectedVersion = fixture.expectedProtocolVersion {
                let version = try XCTUnwrap(ProtocolVersion(expectedVersion))
                XCTAssertEqual(decoder.observedVersion, version, "\(fixture.id): observed version")
                XCTAssertTrue(decoder.versionSupport.isSupported, "\(fixture.id): version support")
            }

            if let expectedPage = fixture.expectedPage {
                let expected = PageIdentity(
                    section: expectedPage.section,
                    owner: expectedPage.owner,
                    book: expectedPage.book,
                    page: expectedPage.page
                )
                // An offline packet carries the page in its own header rather
                // than in a page event, so read it from the assembled stroke.
                let reportedPage: PageIdentity?
                if try !FixtureSupport.offlineDataFrames(fixture).isEmpty {
                    reportedPage = try FixtureSupport.strokes(fixture).first?.page
                } else {
                    reportedPage = decoder.currentPage
                }
                XCTAssertEqual(reportedPage, expected, "\(fixture.id): page")
            }

            if let expectedStrokeCount = fixture.expectedStrokeCount {
                let strokes = try FixtureSupport.strokes(fixture)
                XCTAssertEqual(strokes.count, expectedStrokeCount, "\(fixture.id): stroke count")
            }
        }
    }

    func testFixtureSanitizationMetadataIsComplete() throws {
        for fixture in try FixtureSupport.all() {
            XCTAssertTrue(
                requiredSanitizationCategories.isSubset(of: Set(fixture.sanitization.removed)),
                "\(fixture.id): sanitization categories"
            )
            XCTAssertFalse(fixture.sanitization.notes.isEmpty, "\(fixture.id): sanitization notes")
            XCTAssertFalse(fixture.provenance.source.isEmpty, "\(fixture.id): provenance source")
            XCTAssertFalse(fixture.provenance.deviceModel.isEmpty, "\(fixture.id): device model")
            XCTAssertFalse(fixture.provenance.firmware.isEmpty, "\(fixture.id): firmware")
            XCTAssertFalse(fixture.provenance.observedProtocolVersion.isEmpty, "\(fixture.id): protocol version")
            XCTAssertFalse(fixture.provenance.captureDate.isEmpty, "\(fixture.id): capture date")
            XCTAssertEqual(fixture.fixtureVersion, 1, "\(fixture.id): fixture version")
        }
    }

    func testVersionFixtureHasNoBluetoothAddressBytes() throws {
        let fixture = try FixtureSupport.fixture("a1-version-info-2.18", in: FixtureSupport.all())
        let packets = try fixture.decodedExpectedPackets()
        let payload = try XCTUnwrap(packets.first?.payload)

        XCTAssertEqual(payload.count, 65)
        // Bytes 58..<64 carry the pen's Bluetooth address on the wire. The
        // fixture must keep them zeroed.
        XCTAssertEqual(Array(payload[58..<64]), [0, 0, 0, 0, 0, 0])
        XCTAssertEqual(PenWire.text(payload[32..<40]), "2.18")
    }

    func testHandshakeFixtureMatchesTheCapturedDeviceFacts() throws {
        let fixture = try FixtureSupport.fixture("a1-handshake-version-2.23", in: FixtureSupport.all())
        XCTAssertEqual(fixture.evidenceLevel, .physicalDevice)

        // The exchange decodes to the device facts `docs/protocol-a1.md` records,
        // so the fixture is anchored to the real pen rather than to a
        // reconstruction of what the pen should send.
        let frames = try FixtureSupport.frames(fixture)
        XCTAssertEqual(frames.map(\.command), [.versionInfo, .responseVersionInfo])
        XCTAssertEqual(frames.map(\.errorCode), [nil, 0])

        let responsePayload = try XCTUnwrap(frames.last?.payload)
        let info = try XCTUnwrap(PenVersionInfo(payload: responsePayload))
        XCTAssertEqual(info.deviceName, "NWP-F151")
        XCTAssertEqual(info.firmwareVersion, "3.00")
        XCTAssertEqual(info.protocolVersionText, "2.23")
        XCTAssertEqual(info.protocolVersion, ProtocolVersion(major: 2, minor: 23))
        XCTAssertEqual(info.subName, "Neosmartpen_A1")
        XCTAssertEqual(info.deviceType, 0x0001)
        XCTAssertEqual(info.pressureSensorType, 0x04)
        XCTAssertFalse(info.supportsCompressedTransfer)

        // The request matches the SDK's version request layout: the connection
        // code is sixteen zero bytes and the declared protocol is 2.18. The
        // capture was driven by a BLE spike harness rather than by the SDK, so
        // this pins the layout, not the sender.
        let requestPayload = try XCTUnwrap(frames.first?.payload)
        XCTAssertEqual(requestPayload.count, 42)
        XCTAssertEqual(Array(requestPayload[0..<16]), [UInt8](repeating: 0, count: 16))
        XCTAssertEqual(PenWire.text(requestPayload[32..<40]), "2.18")
    }

    func testNoFixtureCarriesADeviceAddressInAVersionPayload() throws {
        // A content check rather than a metadata check. Every version response is
        // checked twice: once as the fixture declares it, and once as the wire
        // bytes decode, so a version frame present in `chunks` but not declared
        // as a packet expectation cannot slip past.
        var declared = 0
        var decoded = 0

        for fixture in try FixtureSupport.all() {
            for packet in try fixture.decodedExpectedPackets()
            where PenCommand(rawValue: packet.commandByte) == .responseVersionInfo {
                assertAddressFieldIsZeroed(packet.payload, in: fixture, what: "declared packet")
                declared += 1
            }

            for frame in try FixtureSupport.frames(fixture)
            where frame.command == .responseVersionInfo {
                assertAddressFieldIsZeroed(frame.payload, in: fixture, what: "decoded frame")
                decoded += 1
            }
        }

        XCTAssertGreaterThan(declared, 0, "expected at least one declared version payload")
        XCTAssertGreaterThan(decoded, 0, "expected at least one decoded version payload")
    }

    /// Asserts that a version payload's Bluetooth address field is zeroed.
    private func assertAddressFieldIsZeroed(
        _ payload: [UInt8],
        in fixture: ProtocolFixture,
        what: String
    ) {
        guard payload.count >= 64 else {
            XCTFail("\(fixture.id): the \(what) is too short to reach the address field")
            return
        }
        XCTAssertEqual(
            Array(payload[58..<64]),
            [0, 0, 0, 0, 0, 0],
            "\(fixture.id): the \(what)'s Bluetooth address field must be zeroed"
        )
    }

    func testFixtureFilesContainNoSerialLikeFields() throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: FixtureSupport.directory,
            includingPropertiesForKeys: nil
        )
        let files = contents.filter { $0.pathExtension == ProtocolFixtureLoader.fileExtension }
        XCTAssertFalse(files.isEmpty)

        for file in files {
            // Field names that would carry a device identifier, credential, or
            // address must not appear as keys. The sanitization metadata may
            // name the categories it removed.
            let text = try String(contentsOf: file, encoding: .utf8).lowercased()
            for forbiddenKey in ["\"serial\":", "\"mac\":", "\"password\":", "\"address\":", "\"authkey\":"] {
                XCTAssertFalse(
                    text.contains(forbiddenKey),
                    "\(file.lastPathComponent): contains field \(forbiddenKey)"
                )
            }
        }
    }

    func testMalformedFixturesDoNotInventPenEvents() throws {
        let malformed = try FixtureSupport.all().filter { !$0.expectedErrorKinds.isEmpty }
        XCTAssertFalse(malformed.isEmpty, "expected at least one malformed fixture")

        for fixture in malformed {
            let frames = try FixtureSupport.frames(fixture)

            // The frames that are recovered must match the packets the fixture
            // declares. Without this precondition the negative assertions below
            // could pass if framing regressed to emitting nothing at all.
            let declaredCommands = try fixture.decodedExpectedPackets()
                .map { PenCommand(rawValue: $0.commandByte) }
            XCTAssertEqual(
                frames.map(\.command),
                declaredCommands,
                "\(fixture.id): recovered frames must match the declared packets"
            )

            // Those recovered frames carry no pen events, so malformed input
            // never invents pen data.
            let eventCount = try FixtureSupport.events(fixture).count
            XCTAssertEqual(eventCount, 0, "\(fixture.id): malformed input must not invent pen events")
            XCTAssertEqual(try FixtureSupport.strokes(fixture).count, 0, "\(fixture.id): no strokes")
        }
    }

    func testFixturesCoverBothFrameKinds() throws {
        var responsePackets = 0
        var eventPackets = 0

        for fixture in try FixtureSupport.all() {
            for expected in fixture.expected where expected.kind == "packet" {
                let byte = try XCTUnwrap(expected.byte, "\(fixture.id): command byte")
                let command = try XCTUnwrap(PenCommand(rawValue: byte), "\(fixture.id): known command")
                let kind = try XCTUnwrap(command.frameKind, "\(fixture.id): classified command")

                // The fixture's own declaration must agree with the
                // classification the decoder uses. Comparing the declared error
                // code against the Swift table, rather than against a decoded
                // frame, is what makes this a cross-check: it would catch the
                // generator's framing table disagreeing with the decoder's.
                XCTAssertEqual(
                    expected.errorCode != nil,
                    kind == .response,
                    "\(fixture.id): \(command) declares the wrong body layout"
                )

                if kind == .response {
                    responsePackets += 1
                } else {
                    eventPackets += 1
                }
            }
        }

        XCTAssertGreaterThan(responsePackets, 0, "at least one fixture must declare a response frame")
        XCTAssertGreaterThan(eventPackets, 0, "at least one fixture must declare an event frame")
    }

    func testRealtimeFixtureAssemblesOneStrokeWithStableFingerprint() throws {
        let fixtures = try FixtureSupport.all()
        let fixture = try FixtureSupport.fixture("a1-realtime-stroke", in: fixtures)

        let first = try FixtureSupport.strokes(fixture)
        let second = try FixtureSupport.strokes(fixture)
        XCTAssertEqual(first.count, 1)

        let stroke = try XCTUnwrap(first.first)
        XCTAssertEqual(stroke.points.count, 4)
        XCTAssertEqual(stroke.points.map(\.penTimeOffsetMilliseconds), [10, 20, 30, 40])
        XCTAssertEqual(stroke.points.first?.x, 100_025)
        XCTAssertEqual(stroke.points.first?.y, 50_050)

        let fingerprint = StrokeIdentity.fingerprint(of: stroke)
        XCTAssertTrue(fingerprint.allowsCrossSourceDeduplication)
        let repeated = try XCTUnwrap(second.first)
        XCTAssertEqual(fingerprint, StrokeIdentity.fingerprint(of: repeated))
    }

    func testTruncatedFixtureRecoversForTheFollowingFrame() throws {
        let fixtures = try FixtureSupport.all()
        let fixture = try FixtureSupport.fixture("a1-truncated-frame", in: fixtures)

        let errors = try FixtureSupport.errors(fixture)
        XCTAssertEqual(errors.map(\.kind), ["truncatedPacket"])
        XCTAssertEqual(try FixtureSupport.frames(fixture).count, 1)
    }

    func testSizeLimitFixtureDiscardsAndRecovers() throws {
        let fixtures = try FixtureSupport.all()
        let fixture = try FixtureSupport.fixture("a1-size-limit-recovery", in: fixtures)

        let errors = try FixtureSupport.errors(fixture)
        XCTAssertEqual(errors.map(\.kind), ["payloadExceedsLimit", "bufferedInputExceedsLimit"])
        let frames = try FixtureSupport.frames(fixture)
        XCTAssertEqual(frames.map(\.command), [.responseVersionInfo])
    }

    func testEscapedPageIdentitySurvivesFraming() throws {
        let fixtures = try FixtureSupport.all()
        let fixture = try FixtureSupport.fixture("a1-escaped-page-identity", in: fixtures)

        // The wire bytes must contain escape sequences for the marker bytes.
        let raw = try XCTUnwrap(fixture.decodedChunks().first)
        XCTAssertGreaterThan(raw.filter { $0 == PenFraming.escape }.count, 0)

        var decoder = PenEventDecoder()
        let frames = try FixtureSupport.frames(fixture)
        XCTAssertEqual(frames.count, 1)
        let outcome = decoder.decode(try XCTUnwrap(frames.first))
        XCTAssertEqual(
            outcome,
            .pageObserved(PageIdentity(section: 3, owner: 0x7DC1C0, book: 7, page: 12))
        )
    }

    func testOfflineFixtureParsesToAStroke() throws {
        let fixtures = try FixtureSupport.all()
        let fixture = try FixtureSupport.fixture("a1-offline-stroke", in: fixtures)

        let strokes = try FixtureSupport.strokes(fixture)
        XCTAssertEqual(strokes.count, 1)

        let stroke = try XCTUnwrap(strokes.first)
        XCTAssertEqual(stroke.source, .offline)
        XCTAssertEqual(stroke.page, PageIdentity(section: 3, owner: 0x000ABC, book: 7, page: 12))
        XCTAssertEqual(stroke.originTime, .reliable(milliseconds: 1_700_000_000_000))
        XCTAssertEqual(stroke.points.count, 3)
        XCTAssertEqual(stroke.points.map(\.penTimeOffsetMilliseconds), [0, 15, 30])
        XCTAssertEqual(stroke.points.first?.x, 100_025)
    }

    func testOfflineMultipacketFixtureAssemblesEveryPacket() throws {
        let fixtures = try FixtureSupport.all()
        let fixture = try FixtureSupport.fixture("a1-offline-multipacket", in: fixtures)

        // A physical A1 sends offline data as REQ2_OFFLINE_DATA, one packet per
        // acknowledgement, in positions start, middle, end.
        let frames = try FixtureSupport.offlineDataFrames(fixture)
        XCTAssertEqual(
            frames.compactMap(\.command),
            [.offlineDataRequest2, .offlineDataRequest2, .offlineDataRequest2]
        )

        var assembler = OfflineTransferAssembler()
        var strokes: [Stroke] = []
        var completeness: [Bool] = []

        for frame in frames {
            guard case .packet(let progress) = assembler.ingest(payload: frame.payload) else {
                return XCTFail("expected every packet of the transfer to be accepted")
            }
            completeness.append(progress.isTransferComplete)
            strokes.append(contentsOf: progress.records.map(\.stroke))
        }

        XCTAssertEqual(completeness, [false, false, true], "only the last packet ends the transfer")
        XCTAssertTrue(assembler.isComplete)
        XCTAssertEqual(assembler.assembledPacketCount, 3)
        XCTAssertEqual(assembler.assembledStrokeCount, 3)
        XCTAssertEqual(strokes.count, 3)
        XCTAssertEqual(strokes.map(\.page.page), [12, 13, 14])
        XCTAssertEqual(Set(strokes.map(\.page.section)), [3])
        XCTAssertEqual(Set(strokes.map(\.page.owner)), [0x000ABC])
        XCTAssertEqual(Set(strokes.map(\.page.book)), [7])
        XCTAssertTrue(strokes.allSatisfy { $0.source == .offline })
    }
}
