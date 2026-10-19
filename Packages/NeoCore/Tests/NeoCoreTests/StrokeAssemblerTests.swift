import XCTest

@testable import NeoCore

final class StrokeAssemblerTests: XCTestCase {
    private let pageA = PageIdentity(section: 1, owner: 2, book: 3, page: 4)
    private let pageB = PageIdentity(section: 1, owner: 2, book: 3, page: 5)
    private let origin = PenOriginTime.reliable(milliseconds: 1_700_000_000_000)

    private func event(
        _ phase: PenEventPhase,
        _ page: PageIdentity,
        x: Int32? = nil,
        offset: Int64 = 0,
        source: PenSource = .live,
        originTime: PenOriginTime? = nil
    ) -> PenEvent {
        let point = x.map {
            PenPoint(x: $0, y: $0, penTimeOffsetMilliseconds: offset, pressure: 100)
        }
        return PenEvent(
            context: PenEventContext(page: page, originTime: originTime ?? origin, source: source),
            phase: phase,
            point: point
        )
    }

    func testCompleteStrokeRetainsEventOrderAndPage() {
        var assembler = StrokeAssembler()
        XCTAssertEqual(assembler.consume(event(.down, pageA, x: 10)), .opened)
        XCTAssertEqual(assembler.consume(event(.move, pageA, x: 20, offset: 5)), .extended)
        XCTAssertEqual(assembler.consume(event(.move, pageA, x: 30, offset: 10)), .extended)

        guard case .completed(let stroke) = assembler.consume(event(.up, pageA, x: 40, offset: 15)) else {
            return XCTFail("expected a completed stroke")
        }

        XCTAssertEqual(stroke.page, pageA)
        XCTAssertEqual(stroke.originTime, origin)
        XCTAssertEqual(stroke.points.map(\.x), [10, 20, 30, 40])
        XCTAssertEqual(stroke.points.map(\.penTimeOffsetMilliseconds), [0, 5, 10, 15])
        XCTAssertFalse(assembler.hasOpenStroke)
    }

    func testMissingUpEventRetainsIncompleteStroke() {
        var assembler = StrokeAssembler()
        _ = assembler.consume(event(.down, pageA, x: 10))
        _ = assembler.consume(event(.move, pageA, x: 20, offset: 5))

        guard case .incomplete(let stroke) = assembler.finish() else {
            return XCTFail("expected an incomplete stroke")
        }

        XCTAssertEqual(stroke.points.map(\.x), [10, 20])
        XCTAssertFalse(assembler.hasOpenStroke)
        XCTAssertEqual(assembler.finish(), .ignored)
    }

    func testPointBeforeDownIsInvalid() {
        var assembler = StrokeAssembler()
        let outcome = assembler.consume(event(.move, pageA, x: 10))
        XCTAssertEqual(outcome, .invalid(.pointBeforeDown(page: pageA)))
        XCTAssertFalse(assembler.hasOpenStroke)
        XCTAssertEqual(assembler.finish(), .ignored)
    }

    func testUpWithoutDownIsInvalid() {
        var assembler = StrokeAssembler()
        let outcome = assembler.consume(event(.up, pageA, x: 10))
        XCTAssertEqual(outcome, .invalid(.upWithoutDown(page: pageA)))
        XCTAssertFalse(assembler.hasOpenStroke)
    }

    func testPageChangeDuringStrokeIsInvalidAndEmitsNoStroke() {
        var assembler = StrokeAssembler()
        _ = assembler.consume(event(.down, pageA, x: 10))

        let outcome = assembler.consume(event(.move, pageB, x: 20, offset: 5))
        XCTAssertEqual(outcome, .invalid(.pageChangedDuringStroke(openPage: pageA, eventPage: pageB)))
        XCTAssertFalse(assembler.hasOpenStroke)

        // The discarded stroke must not resurface as a completed stroke.
        XCTAssertEqual(assembler.finish(), .ignored)
    }

    func testPageChangeBeforeUpIsInvalid() {
        var assembler = StrokeAssembler()
        _ = assembler.consume(event(.down, pageA, x: 10))
        let outcome = assembler.consume(event(.up, pageB, x: 20))
        XCTAssertEqual(outcome, .invalid(.pageChangedDuringStroke(openPage: pageA, eventPage: pageB)))
    }

    func testRepeatedDownIsInvalidAndOpensNewStroke() {
        var assembler = StrokeAssembler()
        _ = assembler.consume(event(.down, pageA, x: 10))

        let outcome = assembler.consume(event(.down, pageA, x: 20))
        XCTAssertEqual(outcome, .invalid(.downWhileStrokeOpen(openPage: pageA, eventPage: pageA)))
        XCTAssertTrue(assembler.hasOpenStroke)

        guard case .completed(let stroke) = assembler.consume(event(.up, pageA, x: 30)) else {
            return XCTFail("expected a completed stroke")
        }
        XCTAssertEqual(stroke.points.map(\.x), [20, 30])
    }

    func testAssemblerRecoversAfterInvalidSequence() {
        var assembler = StrokeAssembler()
        _ = assembler.consume(event(.move, pageA, x: 10))
        _ = assembler.consume(event(.down, pageA, x: 20))
        _ = assembler.consume(event(.move, pageA, x: 30, offset: 5))

        guard case .completed(let stroke) = assembler.consume(event(.up, pageA, x: 40, offset: 10)) else {
            return XCTFail("expected a completed stroke")
        }
        XCTAssertEqual(stroke.points.map(\.x), [20, 30, 40])
    }

    func testNormalizedSampleProducesCanonicalPoint() {
        let raw = RawPenSample(
            integerX: 1234,
            hundredthsX: 56,
            integerY: 987,
            hundredthsY: 4,
            penTimeOffsetMilliseconds: 42,
            pressure: 512
        )
        guard let point = PenSampleNormalizer.normalize(raw) else {
            return XCTFail("expected a normalized point")
        }
        XCTAssertEqual(point.x, 123_456)
        XCTAssertEqual(point.y, 98_704)
        XCTAssertEqual(point.penTimeOffsetMilliseconds, 42)
        XCTAssertEqual(point.pressure, 512)
    }

    func testNormalizerRejectsOutOfRangeFraction() {
        let raw = RawPenSample(
            integerX: 1,
            hundredthsX: 100,
            integerY: 1,
            hundredthsY: 0,
            penTimeOffsetMilliseconds: 0,
            pressure: 0
        )
        XCTAssertNil(PenSampleNormalizer.normalize(raw))
    }
}
