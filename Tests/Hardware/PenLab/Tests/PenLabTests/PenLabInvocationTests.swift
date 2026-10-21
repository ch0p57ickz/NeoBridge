import XCTest

@testable import PenLab

/// Pins the invocation rules that stand between an operator and the pen.
///
/// The tool's safety lives here rather than in the frames: nothing is sent without
/// `--send`, a step's subject is the one the transcript prints, and an invocation that
/// cannot be sent as printed is refused before the radio is touched. Each test names the
/// mistake it prevents.
final class PenLabInvocationTests: XCTestCase {
    private func parse(_ arguments: [String]) throws -> PenLabInvocation {
        try PenLabInvocation.parse(arguments: arguments)
    }

    private func refusal(_ arguments: [String]) -> PenLabFailure? {
        do {
            _ = try parse(arguments)
            return nil
        } catch let failure as PenLabFailure {
            return failure
        } catch {
            return nil
        }
    }

    // MARK: - Nothing is sent without --send

    func testAnInvocationWithoutSendIsADryRun() throws {
        let invocation = try parse(["delete-note", "--note", "700"])

        XCTAssertFalse(invocation.shouldSend, "the pen must not be touched without --send")
        XCTAssertEqual(invocation.notes, [700])
    }

    func testSendIsRecordedWhenItIsGiven() throws {
        let invocation = try parse(["delete-page", "--note", "700", "--page", "1", "--send"])

        XCTAssertTrue(invocation.shouldSend)
        XCTAssertEqual(invocation.pages, [1])
    }

    // MARK: - One experiment at a time

    func testTwoExperimentsAreRefused() {
        XCTAssertNotNil(refusal(["probe", "delete-note", "--note", "700"]))
    }

    func testAnUnknownExperimentIsRefused() {
        XCTAssertNotNil(refusal(["delete-everything", "--note", "700"]))
    }

    func testAnUnknownOptionIsRefused() {
        XCTAssertNotNil(refusal(["probe", "--note", "700", "--really"]))
    }

    func testAnInvocationWithNoExperimentIsRefused() {
        XCTAssertNotNil(refusal(["--note", "700"]))
    }

    // MARK: - A step's subject must be complete

    func testDeletePageNeedsExactlyOneNote() {
        XCTAssertNotNil(refusal(["delete-page", "--page", "1"]))
        XCTAssertNotNil(refusal(["delete-page", "--note", "700", "--note", "701", "--page", "1"]))
    }

    func testDeletePageNeedsAPage() {
        XCTAssertNotNil(refusal(["delete-page", "--note", "700"]))
    }

    func testDeleteNoteNeedsANote() {
        XCTAssertNotNil(refusal(["delete-note"]))
    }

    // MARK: - What the transcript prints is what is sent

    func testAnOwnerThatDoesNotFitInTwentyFourBitsIsRefused() {
        // `sectionOwnerId` keeps the owner in three bytes, so a larger value would be
        // silently truncated under an `owner` line that printed the original.
        XCTAssertNotNil(refusal(["probe", "--note", "700", "--owner", "16777216"]))
        XCTAssertNil(refusal(["probe", "--note", "700", "--owner", "16777215"]))
    }

    func testASectionThatDoesNotFitInOneByteIsRefused() {
        XCTAssertNotNil(refusal(["probe", "--note", "700", "--section", "256"]))
    }

    func testMoreIdentifiersThanTheCountByteHoldsAreRefused() {
        let notes = (0 ..< 256).flatMap { ["--note", String($0)] }
        XCTAssertNotNil(refusal(["delete-note"] + notes))
        XCTAssertNil(refusal(["delete-note"] + Array(notes.dropLast(2))))
    }

    func testMoreProbePagesThanTheCountByteHoldsAreRefused() {
        // `probe` sends a `0x27` request too, so its page list needs the same bound as
        // `delete-page`'s: the frame writes the count in one byte.
        let pages = (0 ..< 256).flatMap { ["--page", String($0)] }
        XCTAssertNotNil(refusal(["probe", "--note", "700"] + pages))
        XCTAssertNil(refusal(["probe", "--note", "700"] + Array(pages.dropLast(2))))
    }

    func testATimeoutThatWouldNeverExpireIsRefused() {
        XCTAssertNotNil(refusal(["probe", "--note", "700", "--timeout", "inf"]))
        XCTAssertNotNil(refusal(["probe", "--note", "700", "--timeout", "nan"]))
        XCTAssertNotNil(refusal(["probe", "--note", "700", "--timeout", "0"]))
        XCTAssertNotNil(refusal(["probe", "--note", "700", "--timeout", "-1"]))
        XCTAssertNotNil(refusal(["probe", "--note", "700", "--timeout", "601"]))
        XCTAssertNil(refusal(["probe", "--note", "700", "--timeout", "15"]))
    }

    // MARK: - Defaults and the frames a step carries

    func testTheSectionAndOwnerDefaultToTheNotebookTheExperimentsUsed() throws {
        let invocation = try parse(["probe", "--note", "700"])

        XCTAssertEqual(invocation.section, 3)
        XCTAssertEqual(invocation.owner, 27)
        XCTAssertEqual(invocation.timeout, 15)
    }

    func testDeleteNoteSendsTheNoteFrameAndNamesItsSubject() throws {
        let invocation = try parse(["delete-note", "--note", "700"])
        let steps = invocation.steps()

        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0].name, "delete-note-0x25")
        XCTAssertEqual(steps[0].request, 0x25)
        XCTAssertEqual(steps[0].response, 0xA5)
        XCTAssertEqual(PenLabFrames.hex(steps[0].frame), "C02509001B00000301BC020000C1")
        XCTAssertTrue(steps[0].scope.contains("700"), steps[0].scope)
    }

    func testProbeSendsBothCommandsAndTakesTheFirstNoteForThePageCommand() throws {
        let invocation = try parse(["probe", "--note", "700", "--note", "701"])
        let steps = invocation.steps()

        XCTAssertEqual(steps.map(\.request), [0x25, 0x27])
        XCTAssertEqual(steps.map(\.response), [0xA5, 0xA7])
        XCTAssertEqual(
            PenLabFrames.hex(steps[0].frame),
            "C0250D001B00000302BC020000BD020000C1",
            "the probe sends every note it was given"
        )
        XCTAssertTrue(
            steps[1].scope.contains("700") && !steps[1].scope.contains("701"),
            "0x27 names one note, so the probe uses the first: \(steps[1].scope)"
        )
    }
}
