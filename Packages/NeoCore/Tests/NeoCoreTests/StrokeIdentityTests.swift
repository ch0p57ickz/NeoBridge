import XCTest

@testable import NeoCore

final class StrokeIdentityTests: XCTestCase {
    private let page = PageIdentity(section: 3, owner: 0x000ABC, book: 7, page: 12)
    private let originMilliseconds: Int64 = 1_700_000_000_123

    private var points: [PenPoint] {
        [
            PenPoint(x: 1234, y: -567, penTimeOffsetMilliseconds: 0, pressure: 512),
            PenPoint(x: 1240, y: -560, penTimeOffsetMilliseconds: 12, pressure: 640),
            PenPoint(x: 1300, y: -500, penTimeOffsetMilliseconds: 25, pressure: 800)
        ]
    }

    private func stroke(
        page: PageIdentity? = nil,
        originTime: PenOriginTime? = nil,
        points: [PenPoint]? = nil,
        source: PenSource = .live
    ) -> Stroke {
        Stroke(
            page: page ?? self.page,
            originTime: originTime ?? .reliable(milliseconds: originMilliseconds),
            points: points ?? self.points,
            source: source
        )
    }

    // Golden vectors. The expected digests were computed with an independent
    // implementation of the documented canonical layout, so a change to the
    // encoder that alters the byte stream fails these tests.
    private let goldenLiveDigest = "24e5f10469a60dea25030a462a9482cfde7dc2a17e136630d31dfefbf3690e4f"
    private let goldenChangedPressureDigest = "0f5984afbe262abf4d16e3dfb612cd0502317dba0fa52db51466d714c9010710"
    private let goldenChangedOriginDigest = "b714c725c32af792fa1133a8565c1cd26dfc188bcb0d7b31afaff12d6ea28eac"
    private let goldenChangedPageDigest = "e1b27aec2b6a095c39177ae9cb1ac687a6b9d78405c16296d12c91015a6a59cd"
    private let goldenReorderedDigest = "9eaa8032f327303a755732d8707dbe4c108312d935a7529337ebd603e436feaa"
    private let goldenUnreliableDigest = "7364355e094ee44375574ac5d63d1b67472995c758c3cdf78c29d4da94ef6800"

    func testCanonicalEncodingLayout() {
        let bytes = CanonicalStrokeEncoding.encode(stroke())
        XCTAssertEqual(Array(bytes.prefix(4)), [0x4E, 0x43, 0x53, 0x01])
        XCTAssertEqual(bytes[4], 3)
        XCTAssertEqual(bytes.count, CanonicalStrokeEncoding.headerByteCount + 3 * CanonicalStrokeEncoding.pointByteCount)
        XCTAssertEqual(bytes.count, 84)
        XCTAssertEqual(CanonicalStrokeEncoding.version, 1)
    }

    func testGoldenFingerprintForLiveStroke() {
        let fingerprint = StrokeIdentity.fingerprint(of: stroke(source: .live))
        XCTAssertEqual(fingerprint.hexDigest, goldenLiveDigest)
        XCTAssertEqual(fingerprint.encodingVersion, CanonicalStrokeEncoding.version)
        XCTAssertTrue(fingerprint.allowsCrossSourceDeduplication)
    }

    func testLiveAndOfflineReplayAreEquivalent() {
        let live = StrokeIdentity.fingerprint(of: stroke(source: .live))
        let offline = StrokeIdentity.fingerprint(of: stroke(source: .offline))
        XCTAssertEqual(live.hexDigest, offline.hexDigest)
        XCTAssertEqual(live, offline)
    }

    func testChangedFieldProducesDifferentFingerprint() {
        let base = StrokeIdentity.fingerprint(of: stroke())

        var changedPressure = points
        changedPressure[2] = PenPoint(x: 1300, y: -500, penTimeOffsetMilliseconds: 25, pressure: 801)
        XCTAssertEqual(
            StrokeIdentity.fingerprint(of: stroke(points: changedPressure)).hexDigest,
            goldenChangedPressureDigest
        )
        XCTAssertNotEqual(
            StrokeIdentity.fingerprint(of: stroke(points: changedPressure)),
            base
        )

        let changedOrigin = stroke(originTime: .reliable(milliseconds: originMilliseconds + 1))
        XCTAssertEqual(StrokeIdentity.fingerprint(of: changedOrigin).hexDigest, goldenChangedOriginDigest)
        XCTAssertNotEqual(StrokeIdentity.fingerprint(of: changedOrigin), base)

        let changedPage = stroke(page: PageIdentity(section: 3, owner: 0x000ABC, book: 7, page: 13))
        XCTAssertEqual(StrokeIdentity.fingerprint(of: changedPage).hexDigest, goldenChangedPageDigest)
        XCTAssertNotEqual(StrokeIdentity.fingerprint(of: changedPage), base)
    }

    func testPointOrderIsPreserved() {
        let reordered = [points[1], points[0], points[2]]
        let fingerprint = StrokeIdentity.fingerprint(of: stroke(points: reordered))
        XCTAssertEqual(fingerprint.hexDigest, goldenReorderedDigest)
        XCTAssertNotEqual(fingerprint, StrokeIdentity.fingerprint(of: stroke()))
    }

    func testUnreliableOriginDisablesCrossSourceDeduplication() {
        let unreliable = StrokeIdentity.fingerprint(
            of: stroke(originTime: .unreliable(reportedMilliseconds: originMilliseconds))
        )
        XCTAssertEqual(unreliable.hexDigest, goldenUnreliableDigest)
        XCTAssertNotEqual(unreliable.hexDigest, goldenLiveDigest)
        XCTAssertFalse(unreliable.allowsCrossSourceDeduplication)
    }

    func testAbsentOriginDisablesCrossSourceDeduplication() {
        let absent = StrokeIdentity.fingerprint(of: stroke(originTime: .unreliable(reportedMilliseconds: nil)))
        XCTAssertFalse(absent.allowsCrossSourceDeduplication)

        // Two identical marks with no trustworthy pen time must stay distinct so
        // they are never collapsed across sources.
        let live = StrokeIdentity.fingerprint(of: stroke(originTime: .unreliable(reportedMilliseconds: nil), source: .live))
        let offline = StrokeIdentity.fingerprint(of: stroke(originTime: .unreliable(reportedMilliseconds: nil), source: .offline))
        XCTAssertEqual(live.hexDigest, offline.hexDigest)
        XCTAssertFalse(live.allowsCrossSourceDeduplication)
        XCTAssertFalse(offline.allowsCrossSourceDeduplication)
    }

    func testIncompleteStrokeIsNeverDeduplicable() {
        let incomplete = StrokeIdentity.fingerprint(ofIncomplete: stroke())
        XCTAssertEqual(incomplete.hexDigest, goldenLiveDigest)
        XCTAssertFalse(incomplete.allowsCrossSourceDeduplication)
    }
}
