import Foundation
import NeoBridgeMacCore

/// One headless read attempt, driven by the app's own controller.
///
/// The physical-A1 acceptance in `Tests/Hardware/README.md` needs the app to read
/// the pen and to record the framed bytes it sent, and a menu-bar app cannot be
/// driven into that from a script without an accessibility grant. The same binary
/// therefore takes this path when `NEOBRIDGE_ACCEPTANCE_TRACE` names a file: it
/// builds the same controller the UI uses, starts one read attempt, waits for it
/// to finish, writes the transcript, and exits non-zero when the read did not
/// complete.
///
/// The run is the real thing: the same adapter, transport, runner, and portable
/// session, over the real radio. Only the presentation is skipped.
enum NeoBridgeAcceptance {
    /// The environment variable that selects this mode and names the transcript.
    static let traceEnvironmentKey = "NEOBRIDGE_ACCEPTANCE_TRACE"

    /// How long the whole attempt may take before the run is abandoned.
    static let timeout: TimeInterval = 180

    /// How long to let CoreBluetooth finish the disconnect before exiting.
    ///
    /// The disconnect request is asynchronous, and a process that exits the
    /// instant the read finishes can leave the pen attached to nothing, which
    /// keeps it from advertising for the next run.
    static let disconnectSettle: TimeInterval = 1.5

    /// The transcript path, or `nil` for a normal UI launch.
    static var traceURL: URL? {
        guard let path = ProcessInfo.processInfo.environment[traceEnvironmentKey],
            !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Runs one attempt and exits. Never returns.
    ///
    /// - Parameter traceURL: Where to write the transcript.
    @MainActor
    static func run(traceURL: URL) -> Never {
        let trace = PenTrafficLog()
        let controller = PenSyncAppComposition.makeController(trace: trace)

        controller.readPenData()

        // The attempt reports through the controller on the main actor, so the
        // main run loop has to keep turning while it waits on the radio. A short
        // step in the default mode returns as soon as a queued job is handled
        // instead of blocking for the whole interval.
        let deadline = Date().addingTimeInterval(timeout)
        while !controller.phase.isTerminal, Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        let finished = controller.phase.isTerminal
        if !finished {
            trace.record("failed the acceptance run did not finish within \(Int(timeout)) seconds")
            controller.cancel()
        }

        // Give CoreBluetooth a moment to complete the disconnect the attempt
        // asked for, so the pen is advertising again for the next run.
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(disconnectSettle))

        do {
            try trace.write(to: traceURL)
        } catch {
            FileHandle.standardError.write(
                Data("acceptance: could not write \(traceURL.path): \(error)\n".utf8)
            )
        }

        report(controller, traceURL: traceURL)
        exit(controller.result == nil ? 1 : 0)
    }

    /// Prints what the run found, for the transcript's header in the checklist.
    @MainActor
    private static func report(_ controller: PenSyncController, traceURL: URL) {
        let standardOutput = FileHandle.standardOutput
        var lines: [String] = [
            "acceptance: transcript \(traceURL.path)",
            "acceptance: phase \(controller.statusLabel)",
        ]
        if let result = controller.result {
            lines.append(
                "acceptance: strokes \(result.strokeCount) dots \(result.dotCount)"
                    + " pages \(result.distinctPageCount) notes \(result.notes.count)"
            )
            for note in result.notes {
                lines.append("acceptance: read \(note.label) strokes \(note.strokeCount) dots \(note.dotCount)")
            }
        }
        if let message = controller.errorMessage {
            lines.append("acceptance: error \(message)")
        }
        if let diagnostic = controller.errorDiagnostic {
            lines.append("acceptance: diagnostic \(diagnostic)")
        }
        standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }
}
