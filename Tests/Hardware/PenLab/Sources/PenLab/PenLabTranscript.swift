import Foundation

/// The transcript a lab run writes.
///
/// The rules are the same ones the acceptance transcripts follow, with one
/// addition: only the two deletion responses record their payload. Everything else
/// inbound is recorded by identifier and size, because the version response carries
/// the pen's Bluetooth address, and this tool exists to prove what a deletion
/// command removes, not to re-collect device identity.
struct PenLabTranscript {
    private(set) var lines: [String] = []

    /// Appends one line.
    mutating func record(_ line: String) {
        lines.append(line)
    }

    /// The whole transcript, newline-terminated.
    var text: String {
        lines.joined(separator: "\n") + "\n"
    }

    /// Prints the transcript and, when a path is given, writes it there too.
    ///
    /// - Throws: The error from writing the file, after the transcript has already
    ///   been printed.
    func publish(to url: URL?) throws {
        FileHandle.standardOutput.write(Data(text.utf8))
        guard let url else { return }
        try Data(text.utf8).write(to: url)
    }
}

/// Why a lab run stopped.
enum PenLabFailure: Error, CustomStringConvertible {
    /// The invocation was refused before the radio was touched.
    case refused(String)

    /// The connection or channel setup failed.
    case connection(String)

    /// The pen did not answer the version handshake.
    case handshake(String)

    /// A step's response never arrived.
    case noResponse(step: String, seconds: Double)

    /// A step's response reported a non-zero error code.
    case rejected(step: String, errorCode: UInt8)

    /// A frame could not be built, because the evidence table does not classify the
    /// command's framing.
    case framing(String)

    /// A requested abort never happened, because the transfer ended first.
    case abortNotReached(requested: Int, packets: Int)

    var description: String {
        switch self {
        case .refused(let reason):
            return "refused: \(reason)"
        case .connection(let reason):
            return "connection failed: \(reason)"
        case .handshake(let reason):
            return "handshake failed: \(reason)"
        case .noResponse(let step, let seconds):
            return "\(step) got no response within \(seconds) seconds"
        case .rejected(let step, let errorCode):
            return "\(step) was refused with error code 0x\(String(format: "%02X", errorCode))"
        case .framing(let reason):
            return "framing failed: \(reason)"
        case .abortNotReached(let requested, let packets):
            return "the abort at packet \(requested) never happened: the transfer completed"
                + " after \(packets) packet(s), so every packet was acknowledged and the"
                + " pen removed everything it sent"
        }
    }

    /// The process status for this failure.
    ///
    /// A refusal is a usage error, so it exits 2, the same status the acceptance
    /// mode uses for a refused environment.
    var exitStatus: Int32 {
        switch self {
        case .refused: return 2
        default: return 1
        }
    }
}
