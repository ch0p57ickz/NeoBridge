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
        XCTAssertEqual(Set(fixtures.map(\.evidenceLevel)), [.officialSDK])
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
                if try FixtureSupport.frames(fixture).contains(where: { $0.command == .responseOfflineData }) {
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
}
