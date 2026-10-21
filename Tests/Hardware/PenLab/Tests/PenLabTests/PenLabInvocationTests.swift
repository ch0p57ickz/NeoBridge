import NeoProtocol
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
        let steps = try invocation.steps()

        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0].name, "delete-note-0x25")
        XCTAssertEqual(steps[0].request, 0x25)
        XCTAssertEqual(steps[0].response, 0xA5)
        XCTAssertEqual(PenLabFrames.hex(steps[0].frame), "C02509001B00000301BC020000C1")
        XCTAssertTrue(steps[0].scope.contains("700"), steps[0].scope)
    }

    func testProbeSendsBothCommandsAndTakesTheFirstNoteForThePageCommand() throws {
        let invocation = try parse(["probe", "--note", "700", "--note", "701"])
        let steps = try invocation.steps()

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

    // MARK: - The deleting transfer option

    func testNextDeleteNeedsExactlyOneNote() {
        XCTAssertNotNil(refusal(["next-delete"]))
        XCTAssertNotNil(refusal(["next-delete", "--note", "700", "--note", "701"]))
        XCTAssertNil(refusal(["next-delete", "--note", "700"]))
    }

    func testNextDeleteRefusesAPageList() {
        // The transfer asks the pen for the whole note, so a page list would print a
        // subject the request does not carry.
        XCTAssertNotNil(refusal(["next-delete", "--note", "700", "--page", "1"]))
    }

    func testAbortAtPacketIsRefusedForACommandExperiment() {
        XCTAssertNotNil(refusal(["delete-note", "--note", "700", "--abort-at-packet", "5"]))
        XCTAssertNotNil(refusal(["probe", "--note", "700", "--abort-at-packet", "5"]))
        XCTAssertNil(refusal(["next-delete", "--note", "700", "--abort-at-packet", "5"]))
    }

    func testAnAbortPacketNumberThatIsNotACountIsRefused() {
        for text in ["0", "-1", "nan", "1.5", "1000001"] {
            XCTAssertNotNil(
                refusal(["next-delete", "--note", "700", "--abort-at-packet", text]),
                "--abort-at-packet \(text) must be refused"
            )
        }
        XCTAssertNil(refusal(["next-delete", "--note", "700", "--abort-at-packet", "40"]))
    }

    func testNextDeleteSendsDiscoveryStepsInTheAppOrderAndDeletesWithItsTransfer() throws {
        let invocation = try parse(["next-delete", "--note", "700", "--abort-at-packet", "40"])
        let steps = try invocation.steps()
        let transfer = try XCTUnwrap(invocation.transfer())

        // The steps are the app's offline read order — the wildcard note list, then the
        // page list — so an outcome cannot come from a different sequence of requests
        // around the transfer.
        XCTAssertEqual(steps.map(\.request), [0x21, 0x22])
        XCTAssertEqual(steps.map(\.response), [0xA1, 0xA2])
        XCTAssertEqual(PenLabFrames.hex(steps[0].frame), "C0210400FFFFFFFFC1")
        XCTAssertEqual(PenLabFrames.hex(steps[1].frame), "C02208001B000003BC020000C1")

        // The transfer is the app's own `0x23` request with the option byte changed
        // from 0x02 to 0x01: same everything else.
        XCTAssertEqual(PenLabFrames.hex(transfer.request), "C0230E0001001B000003BC02000000000000C1")
        XCTAssertEqual(transfer.abortAtPacket, 40)
        XCTAssertTrue(transfer.scope.contains("700"), transfer.scope)

        let reading = try XCTUnwrap(
            PenRequest.offlineData(
                sectionOwnerId: PenLabFrames.sectionOwnerId(section: 3, owner: 27),
                noteId: 700,
                transferOption: .nextAndReserve,
                compressionOption: .none
            )
        )
        XCTAssertEqual(
            reading.count,
            transfer.request.count,
            "the deleting transfer differs from the reading one only in its option byte"
        )
        XCTAssertEqual(
            Array(reading[5...]),
            Array(transfer.request[5...]),
            "the bytes after the option byte must be the same request"
        )
        XCTAssertEqual(transfer.request[4], 0x01, "the option byte is NextAndDelete")
        XCTAssertEqual(reading[4], 0x02)
    }

    func testACommandExperimentHasNoTransfer() throws {
        XCTAssertNil(try parse(["delete-note", "--note", "700"]).transfer())
        XCTAssertNil(try parse(["probe", "--note", "700"]).transfer())
        XCTAssertNil(try parse(["delete-page", "--note", "700", "--page", "1"]).transfer())
    }

    /// A hand-built invocation with no note is refused rather than trapping.
    ///
    /// `parse` is the only supported constructor and it requires a note, so this cannot
    /// happen in a run. It is asserted because the alternative is a crash in the one tool
    /// allowed to delete pen data, on the day it is pointed at hardware.
    func testAnInvocationWithNoNoteIsRefusedRatherThanTrapping() {
        let invocation = PenLabInvocation(
            experiment: .transferDelete,
            section: 3,
            owner: 27,
            notes: [],
            pages: [],
            timeout: 15,
            shouldSend: false,
            traceURL: nil,
            abortAtPacket: nil
        )

        XCTAssertThrowsError(try invocation.steps()) { error in
            XCTAssertEqual(
                (error as? PenLabFailure)?.description,
                "refused: this experiment needs at least one --note"
            )
        }
        XCTAssertThrowsError(try invocation.transfer()) { error in
            XCTAssertEqual(
                (error as? PenLabFailure)?.description,
                "refused: this experiment needs at least one --note"
            )
        }
    }
}
