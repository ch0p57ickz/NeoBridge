import Foundation
import NeoBridgeMacCore
import NeoCore
import NeoProtocol
import XCTest

/// Tests for the options a headless acceptance run takes from its environment.
///
/// The checklist drives the app binary with these variables, so a value that is
/// silently ignored would produce a transcript for the wrong experiment. Every
/// refusal is therefore tested.
final class PenAcceptanceOptionsTests: XCTestCase {
    private func options(_ environment: [String: String]) throws -> PenAcceptanceOptions? {
        try PenAcceptanceOptions(environment: environment)
    }

    func testNormalLaunchHasNoOptions() throws {
        XCTAssertNil(try options([:]))
        XCTAssertNil(try options(["PATH": "/usr/bin"]))
    }

    func testARunWithOnlyATraceFileTakesTheDefaults() throws {
        let options = try XCTUnwrap(
            try options([PenAcceptanceOptions.traceEnvironmentKey: "/tmp/a1-run.txt"])
        )

        XCTAssertEqual(options.traceURL.path, "/tmp/a1-run.txt")
        XCTAssertNil(options.exportDirectory)
        XCTAssertEqual(options.transferOption, .nextAndReserve)
        XCTAssertEqual(options.cleanupMode, .deleteAfterAcknowledge)
        XCTAssertNil(options.abortAtPacket)
    }

    func testReadsEveryValue() throws {
        let options = try XCTUnwrap(
            try options([
                PenAcceptanceOptions.traceEnvironmentKey: "/tmp/a1-run.txt",
                PenAcceptanceOptions.exportDirectoryEnvironmentKey: "/tmp/a1-export",
                PenAcceptanceOptions.transferOptionEnvironmentKey: "notNextTransfer",
                PenAcceptanceOptions.cleanupModeEnvironmentKey: "keep",
                PenAcceptanceOptions.abortAtPacketEnvironmentKey: "120",
            ])
        )

        XCTAssertEqual(options.traceURL.path, "/tmp/a1-run.txt")
        XCTAssertEqual(options.exportDirectory, "/tmp/a1-export")
        XCTAssertEqual(options.transferOption, .notNextTransfer)
        XCTAssertEqual(options.cleanupMode, .keepOnPen)
        XCTAssertEqual(options.abortAtPacket, 120)
    }

    /// The option can be named by its byte as well as by its case name, so a
    /// transcript can be requested either way.
    func testAcceptsTheOptionByteAsWellAsTheName() throws {
        for text in ["0x00", "00", "0", "notNextTransfer", "NOTNEXTTRANSFER"] {
            let options = try XCTUnwrap(
                try options([
                    PenAcceptanceOptions.traceEnvironmentKey: "/tmp/a1-run.txt",
                    PenAcceptanceOptions.transferOptionEnvironmentKey: text,
                ])
            )
            XCTAssertEqual(options.transferOption, .notNextTransfer, "\(text) selects the first option")
        }

        for text in ["0x02", "02", "2", "nextAndReserve"] {
            let options = try XCTUnwrap(
                try options([
                    PenAcceptanceOptions.traceEnvironmentKey: "/tmp/a1-run.txt",
                    PenAcceptanceOptions.transferOptionEnvironmentKey: text,
                ])
            )
            XCTAssertEqual(options.transferOption, .nextAndReserve, "\(text) selects the reserve option")
        }
    }

    func testRefusesTheDeletingOption() throws {
        // `0x01` is a real transfer option, and the one the read path must never
        // send. A request for it is refused rather than silently turned into
        // another option.
        for text in ["0x01", "1", "nextAndDelete"] {
            XCTAssertThrowsError(
                try options([
                    PenAcceptanceOptions.traceEnvironmentKey: "/tmp/a1-run.txt",
                    PenAcceptanceOptions.transferOptionEnvironmentKey: text,
                ])
            ) { error in
                XCTAssertEqual(error as? PenAcceptanceOptions.ParseError, .unknownTransferOption(text))
            }
        }
    }

    func testRefusesAnUnknownTransferOption() throws {
        XCTAssertThrowsError(
            try options([
                PenAcceptanceOptions.traceEnvironmentKey: "/tmp/a1-run.txt",
                PenAcceptanceOptions.transferOptionEnvironmentKey: "incremental",
            ])
        ) { error in
            let parseError = error as? PenAcceptanceOptions.ParseError
            XCTAssertEqual(parseError, .unknownTransferOption("incremental"))
            XCTAssertTrue(
                parseError?.message.contains("notNextTransfer") == true,
                "the message names the accepted values"
            )
        }
    }

    func testRefusesAnUnknownCleanupMode() throws {
        XCTAssertThrowsError(
            try options([
                PenAcceptanceOptions.traceEnvironmentKey: "/tmp/a1-run.txt",
                PenAcceptanceOptions.cleanupModeEnvironmentKey: "reclaim",
            ])
        ) { error in
            let parseError = error as? PenAcceptanceOptions.ParseError
            XCTAssertEqual(parseError, .unknownCleanupMode("reclaim"))
            XCTAssertTrue(
                parseError?.message.contains("keepOnPen, keep, deleteAfterAcknowledge, cleanup")
                    == true,
                "the message has to name every accepted spelling, not only the case names"
            )
        }
    }

    /// A spelling the documentation does not name is refused, so a transcript can
    /// always be re-derived from the documented vocabulary.
    func testRefusesUndocumentedCleanupAliases() throws {
        for text in ["retain", "delete"] {
            XCTAssertThrowsError(
                try options([
                    PenAcceptanceOptions.traceEnvironmentKey: "/tmp/a1-run.txt",
                    PenAcceptanceOptions.cleanupModeEnvironmentKey: text,
                ]),
                "\(text) is not a documented cleanup mode"
            ) { error in
                XCTAssertEqual(error as? PenAcceptanceOptions.ParseError, .unknownCleanupMode(text))
            }
        }

        // The documented spellings are accepted whatever their case or padding.
        for (text, mode) in [
            ("keepOnPen", PenCleanupMode.keepOnPen),
            ("KEEPONPEN", .keepOnPen),
            (" keep ", .keepOnPen),
            ("cleanup", .deleteAfterAcknowledge),
            ("DeleteAfterAcknowledge", .deleteAfterAcknowledge),
        ] {
            let options = try XCTUnwrap(
                try options([
                    PenAcceptanceOptions.traceEnvironmentKey: "/tmp/a1-run.txt",
                    PenAcceptanceOptions.cleanupModeEnvironmentKey: text,
                ])
            )
            XCTAssertEqual(options.cleanupMode, mode, "\(text) is a documented spelling")
        }
    }

    /// Padding is the parser's to forgive, and it is forgiven the same way for every
    /// value rather than for some of them.
    func testToleratesPaddingAroundEveryValue() throws {
        let options = try XCTUnwrap(
            try options([
                PenAcceptanceOptions.traceEnvironmentKey: "/tmp/a1-run.txt",
                PenAcceptanceOptions.transferOptionEnvironmentKey: " notNextTransfer ",
                PenAcceptanceOptions.cleanupModeEnvironmentKey: " cleanup ",
                PenAcceptanceOptions.abortAtPacketEnvironmentKey: " 100 ",
            ])
        )

        XCTAssertEqual(options.transferOption, .notNextTransfer)
        XCTAssertEqual(options.cleanupMode, .deleteAfterAcknowledge)
        XCTAssertEqual(options.abortAtPacket, 100)
    }

    func testRefusesAPacketNumberThatIsNotPositive() throws {
        for text in ["0", "-4", "half", "1.5", "0x10"] {
            XCTAssertThrowsError(
                try options([
                    PenAcceptanceOptions.traceEnvironmentKey: "/tmp/a1-run.txt",
                    PenAcceptanceOptions.abortAtPacketEnvironmentKey: text,
                ]),
                "\(text) is not a packet number"
            ) { error in
                XCTAssertEqual(error as? PenAcceptanceOptions.ParseError, .invalidAbortAtPacket(text))
            }
        }
    }

    func testEmptyValuesAreTreatedAsUnset() throws {
        let options = try XCTUnwrap(
            try options([
                PenAcceptanceOptions.traceEnvironmentKey: "/tmp/a1-run.txt",
                PenAcceptanceOptions.exportDirectoryEnvironmentKey: "",
                PenAcceptanceOptions.transferOptionEnvironmentKey: "",
                PenAcceptanceOptions.cleanupModeEnvironmentKey: "",
                PenAcceptanceOptions.abortAtPacketEnvironmentKey: "",
            ])
        )

        XCTAssertNil(options.exportDirectory)
        XCTAssertEqual(options.transferOption, .nextAndReserve)
        XCTAssertEqual(options.cleanupMode, .deleteAfterAcknowledge)
        XCTAssertNil(options.abortAtPacket)
    }
}
