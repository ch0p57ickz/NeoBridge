import Foundation

/// The command line the lab accepts.
///
/// The lab exists to send the two deletion commands the app refuses to frame, so the
/// invocation is where the safety lives: nothing is sent without `--send`, every step
/// names its scope in the transcript, and an incomplete invocation is refused before
/// the radio is touched.
struct PenLabInvocation {
    /// What the invocation asks the pen to do.
    enum Experiment: String, CaseIterable {
        /// Send both commands with identifiers the operator expects the pen not to
        /// hold, to record the response framing without removing anything.
        case probe

        /// Send `0x25`, naming notes. The pen removes every stroke of each note.
        case deleteNote = "delete-note"

        /// Send `0x27`, naming pages of one note. The pen removes those pages.
        case deletePage = "delete-page"
    }

    let experiment: Experiment
    let section: UInt8
    let owner: UInt32
    let notes: [UInt32]
    let pages: [UInt32]
    let timeout: Double
    let shouldSend: Bool
    let traceURL: URL?

    /// The text printed for `--help` and for a refused invocation.
    static let usage = """
    Usage: pen-lab <experiment> [options]

    Experiments:
      probe         Send 0x25 and 0x27 with identifiers the pen is not expected to
                    hold, so the response framing is recorded without removing
                    anything. Needs --note; uses the first note for 0x27.
      delete-note   Send 0x25, which removes every stroke of each named note.
      delete-page   Send 0x27, which removes the named pages of one note.

    Options:
      --section N        Section number from the dot pattern (default 3).
      --owner N          Owner number from the dot pattern (default 27).
      --note N           A note identifier. Repeatable for probe and delete-note.
      --page N           A page identifier. Repeatable, delete-page and probe.
      --timeout SECONDS  How long to wait for each response (default 15).
      --trace PATH       Write the transcript here as well as to standard output.
      --send             Send the frames. Without it the tool prints them and stops.
      --help             Print this text.

    The tool never reads the pen, so it cannot check that a target exists: it removes
    what it is told to remove, or reports the pen's refusal.
    """

    /// Parses one invocation.
    ///
    /// - Throws: ``PenLabFailure/refused(_:)`` for anything the tool will not run.
    static func parse(arguments: [String]) throws -> PenLabInvocation {
        var experiment: Experiment?
        var section: UInt8 = 3
        var owner: UInt32 = 27
        var notes: [UInt32] = []
        var pages: [UInt32] = []
        var timeout: Double = 15
        var shouldSend = false
        var traceURL: URL?

        var remaining = arguments
        while let argument = remaining.first {
            remaining.removeFirst()
            switch argument {
            case "--help", "-h":
                throw PenLabFailure.refused("help requested")
            case "--send":
                shouldSend = true
            case "--section":
                section = try byte(consume(&remaining, after: argument), for: argument)
            case "--owner":
                owner = try number(consume(&remaining, after: argument), for: argument)
            case "--note":
                notes.append(try number(consume(&remaining, after: argument), for: argument))
            case "--page":
                pages.append(try number(consume(&remaining, after: argument), for: argument))
            case "--timeout":
                timeout = try seconds(consume(&remaining, after: argument), for: argument)
            case "--trace":
                guard let path = remaining.first else {
                    throw PenLabFailure.refused("--trace needs a path")
                }
                remaining.removeFirst()
                traceURL = URL(fileURLWithPath: path)
            default:
                guard !argument.hasPrefix("-") else {
                    throw PenLabFailure.refused("unknown option \(argument)")
                }
                guard experiment == nil else {
                    throw PenLabFailure.refused("one experiment at a time: \(argument) is a second one")
                }
                guard let parsed = Experiment(rawValue: argument) else {
                    throw PenLabFailure.refused("unknown experiment \(argument)")
                }
                experiment = parsed
            }
        }

        guard let experiment else {
            throw PenLabFailure.refused("no experiment named")
        }

        let invocation = PenLabInvocation(
            experiment: experiment,
            section: section,
            owner: owner,
            notes: notes,
            pages: pages,
            timeout: timeout,
            shouldSend: shouldSend,
            traceURL: traceURL
        )
        try invocation.validate()
        return invocation
    }

    /// Refuses an invocation that cannot do anything, or that would do the wrong
    /// thing.
    private func validate() throws {
        // The section and owner share four bytes, with the owner in the low three, and
        // a request writes its count in one byte. Refusing here is what keeps the
        // subject the transcript prints the subject the pen is actually sent.
        guard owner <= 0x00FF_FFFF else {
            throw PenLabFailure.refused("--owner must fit in 24 bits, and got \(owner)")
        }
        guard timeout.isFinite, timeout > 0, timeout <= 600 else {
            throw PenLabFailure.refused("--timeout must be between 0 and 600 seconds, and got \(timeout)")
        }
        switch experiment {
        case .probe, .deleteNote:
            guard !notes.isEmpty else {
                throw PenLabFailure.refused("\(experiment.rawValue) needs at least one --note")
            }
            guard notes.count <= 255 else {
                throw PenLabFailure.refused("\(experiment.rawValue) takes at most 255 notes, and got \(notes.count)")
            }
        case .deletePage:
            guard notes.count == 1 else {
                throw PenLabFailure.refused("delete-page needs exactly one --note, and got \(notes.count)")
            }
            guard !pages.isEmpty else {
                throw PenLabFailure.refused("delete-page needs at least one --page")
            }
        }
        // Only `delete-page` requires pages, but `probe` also sends a `0x27` request,
        // and either command writes its count in one byte.
        guard pages.count <= 255 else {
            throw PenLabFailure.refused("at most 255 pages, and got \(pages.count)")
        }
    }

    /// The frames this invocation sends, in order.
    func steps() -> [PenLabStep] {
        switch experiment {
        case .probe:
            [
                PenLabStep(
                    name: "probe-0x25",
                    request: PenLabCommand.deleteNote,
                    response: PenLabCommand.deleteNoteResponse,
                    scope: "notes \(list(notes)), which the pen is not expected to hold",
                    frame: PenLabFrames.deleteNoteRequest(section: section, owner: owner, notes: notes)
                ),
                PenLabStep(
                    name: "probe-0x27",
                    request: PenLabCommand.deletePage,
                    response: PenLabCommand.deletePageResponse,
                    scope: "pages \(list(pages.isEmpty ? [1] : pages)) of note \(notes[0])"
                        + ", which the pen is not expected to hold",
                    frame: PenLabFrames.deletePageRequest(
                        section: section,
                        owner: owner,
                        note: notes[0],
                        pages: pages.isEmpty ? [1] : pages
                    )
                ),
            ]
        case .deleteNote:
            [
                PenLabStep(
                    name: "delete-note-0x25",
                    request: PenLabCommand.deleteNote,
                    response: PenLabCommand.deleteNoteResponse,
                    scope: "every stroke of notes \(list(notes))",
                    frame: PenLabFrames.deleteNoteRequest(section: section, owner: owner, notes: notes)
                )
            ]
        case .deletePage:
            [
                PenLabStep(
                    name: "delete-page-0x27",
                    request: PenLabCommand.deletePage,
                    response: PenLabCommand.deletePageResponse,
                    scope: "pages \(list(pages)) of note \(notes[0])",
                    frame: PenLabFrames.deletePageRequest(
                        section: section,
                        owner: owner,
                        note: notes[0],
                        pages: pages
                    )
                )
            ]
        }
    }

    /// Runs the invocation and returns the process status.
    func run() async -> Int32 {
        var header = [
            "run experiment \(experiment.rawValue)",
            "run section \(section) owner \(owner)",
            "run notes \(list(notes))",
            "run pages \(list(pages))",
            "run timeout \(timeout) seconds",
            "run send \(shouldSend)",
            "run the pen is not read first, so no step checks that its target exists",
        ]
        if !shouldSend {
            header.append("run dry run: nothing will be sent")
        }
        let run = PenLabRun(
            steps: steps(),
            timeout: timeout,
            shouldSend: shouldSend,
            traceURL: traceURL,
            header: header
        )
        return await run.run()
    }

    /// A list of identifiers as one field.
    private func list(_ values: [UInt32]) -> String {
        values.isEmpty ? "none" : values.map(String.init).joined(separator: ",")
    }

    // MARK: - Argument readers

    private static func consume(_ remaining: inout [String], after option: String) throws -> String {
        guard let value = remaining.first else {
            throw PenLabFailure.refused("\(option) needs a value")
        }
        remaining.removeFirst()
        return value
    }

    private static func number(_ text: String, for option: String) throws -> UInt32 {
        guard let value = UInt32(text) else {
            throw PenLabFailure.refused("\(option) needs a whole number, and got \(text)")
        }
        return value
    }

    private static func byte(_ text: String, for option: String) throws -> UInt8 {
        let value = try number(text, for: option)
        guard value <= UInt8.max else {
            throw PenLabFailure.refused("\(option) must fit in one byte, and got \(text)")
        }
        return UInt8(value)
    }

    private static func seconds(_ text: String, for option: String) throws -> Double {
        guard let value = Double(text) else {
            throw PenLabFailure.refused("\(option) needs a number of seconds, and got \(text)")
        }
        return value
    }
}

/// The lab's entry point.
@main
struct PenLabMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") {
            FileHandle.standardOutput.write(Data("\(PenLabInvocation.usage)\n".utf8))
            exit(arguments.isEmpty ? 2 : 0)
        }
        do {
            let invocation = try PenLabInvocation.parse(arguments: arguments)
            let status = await invocation.run()
            exit(status)
        } catch let failure as PenLabFailure {
            FileHandle.standardError.write(Data("pen-lab: \(failure)\n\n\(PenLabInvocation.usage)\n".utf8))
            exit(failure.exitStatus)
        } catch {
            FileHandle.standardError.write(Data("pen-lab: \(error)\n".utf8))
            exit(1)
        }
    }
}
