import Foundation
import NeoCore
import NeoProtocol
import Synchronization

/// A transcript of one read attempt's Bluetooth traffic.
///
/// `Tests/Hardware/README.md` requires the framed bytes the host sent, decoded to
/// command identifiers, because the check for "no deletion command was sent"
/// cannot be read from the user interface. This type is that transcript. It
/// records only what leaves the host, in hex, plus the size of what arrives:
/// inbound frames carry the pen's Bluetooth address in the version response, and
/// no capture may contain a device address.
///
/// The transcript is held in memory and written once, so a normal run does no
/// file I/O and an acceptance run ends with the whole log in one file.
public final class PenTrafficLog: Sendable {
    private struct State: Sendable {
        var lines: [String] = []
        var outboundCommands: [PenCommand?] = []
        var outboundFrameCount = 0
        var outboundByteCount = 0
        var inboundChunkCount = 0
        var inboundByteCount = 0
    }

    private let state = Mutex(State())

    /// Creates an empty transcript.
    public init() {}

    /// Records one outbound frame, decoded to its command identifier.
    ///
    /// A frame is logged as hex as well as by command, so the sequence can be
    /// re-decoded later without the pen. Outbound frames carry no device
    /// identifier: the `0x01` connection code is the SDK's sixteen zero bytes.
    public func recordOutbound(_ frame: [UInt8]) {
        var decoder = PenFrameDecoder()
        var command: PenCommand?
        if case .frame(let decoded)? = decoder.ingest(frame).first {
            command = decoded.command
        }

        let hex = frame.map { String(format: "%02X", $0) }.joined()
        state.withLock { state in
            state.lines.append("outbound \(hex) command=\(Self.label(command))")
            state.outboundCommands.append(command)
            state.outboundFrameCount += 1
            state.outboundByteCount += frame.count
        }
    }

    /// Records one inbound chunk by size, never by content.
    public func recordInbound(_ chunk: [UInt8]) {
        state.withLock { state in
            state.lines.append("inbound \(chunk.count) bytes")
            state.inboundChunkCount += 1
            state.inboundByteCount += chunk.count
        }
    }

    /// Records the session's lifecycle state.
    ///
    /// The states arrive in order, so the transcript also shows that scanning,
    /// connecting, verifying, and syncing happened before any result.
    public func recordState(_ label: String) {
        record("state \(label)")
    }

    /// Records the pen facts and the assembled counts of a completed read.
    ///
    /// The counts come from the accepted `0x24` packets, and the `0xA3` summary
    /// is recorded beside them, because a difference between the two is expected
    /// and must land on the transfer's side.
    public func recordCompletion(_ result: PenSessionResult) {
        let version = result.versionInfo
        record("version text=\(version.protocolVersionText) name=\(version.deviceName) firmware=\(version.firmwareVersion)")
        for transfer in result.notes {
            record(
                "note \(transfer.note.displayLabel) strokes=\(transfer.strokeCount)"
                    + " dots=\(transfer.dotCount) packets=\(transfer.packetCount)"
                    + " listedPages=\(transfer.listedPages.map(String.init).joined(separator: ","))"
                    + " infoStrokeCount=\(transfer.info.strokeCount)"
            )
            // The known test mark is checked per page, so every page the transfer
            // reached is recorded with its own stroke and dot counts and the bounds
            // of its point sequence.
            for page in transfer.pageIdentities {
                let strokes = transfer.strokes.filter { $0.page == page }
                let dots = strokes.flatMap(\.points)
                record(
                    "page page=\(page.page) section=\(page.section) owner=\(page.owner)"
                        + " book=\(page.book) strokes=\(strokes.count) dots=\(dots.count)"
                        + " x=\(dots.map(\.x).min() ?? 0)..\(dots.map(\.x).max() ?? 0)"
                        + " y=\(dots.map(\.y).min() ?? 0)..\(dots.map(\.y).max() ?? 0)"
                )
                // One line per stroke, in transfer order, so a mark written on a
                // page can be found in the transfer by shape and time even after
                // the pen has been used again. The pen's offline data only grows,
                // so a page written after the mark cannot be checked by totals.
                //
                // `fp` is the stroke's replay fingerprint, which is the identity a
                // comparison between two runs and the library uses. It is recorded
                // truncated to its first 16 hexadecimal characters: that is
                // plenty to tell two of these strokes apart, and the library holds
                // the full digest.
                for (index, stroke) in strokes.enumerated() {
                    let offsets = stroke.points.map(\.penTimeOffsetMilliseconds)
                    let xs = stroke.points.map(\.x)
                    let ys = stroke.points.map(\.y)
                    let fingerprint = StrokeIdentity.fingerprint(of: stroke)
                    record(
                        "stroke page=\(page.page) index=\(index) dots=\(stroke.points.count)"
                            + " x=\(xs.min() ?? 0)..\(xs.max() ?? 0)"
                            + " y=\(ys.min() ?? 0)..\(ys.max() ?? 0)"
                            + " origin=\(stroke.originTime.reportedMilliseconds.map(String.init) ?? "none")"
                            + " t=\(offsets.min() ?? 0)..\(offsets.max() ?? 0)"
                            + " fp=\(fingerprint.hexDigest.prefix(16))"
                    )
                }
            }
        }
        record(
            "result strokes=\(result.strokeCount) dots=\(result.dotCount)"
                + " pages=\(result.distinctPageCount) notes=\(result.notes.count)"
        )
    }

    /// Records a failure, with the message the shell would show.
    public func recordFailure(_ error: any Error) {
        record("failed \(penSyncErrorMessage(for: error))")
        if let diagnostic = penSyncErrorDiagnostic(for: error) {
            record("diagnostic \(diagnostic)")
        }
    }

    /// Records one free-form line.
    public func record(_ line: String) {
        state.withLock { $0.lines.append(line) }
    }

    /// The transcript, followed by the totals the deletion check reads.
    ///
    /// The final line lists every outbound command identifier in order, so a
    /// single grep proves the run sent no `0x25` or `0x27`.
    public func contents() -> String {
        let (lines, commands, frames, outboundBytes, chunks, bytes) = state.withLock { state in
            (
                state.lines,
                state.outboundCommands,
                state.outboundFrameCount,
                state.outboundByteCount,
                state.inboundChunkCount,
                state.inboundByteCount
            )
        }

        var all = lines
        all.append(
            "totals outboundFrames=\(frames) outboundBytes=\(outboundBytes)"
                + " inboundChunks=\(chunks) inboundBytes=\(bytes)"
        )
        all.append(
            "outboundCommands \(commands.map { $0.map(Self.label) ?? "unknown" }.joined(separator: ","))"
        )
        return all.joined(separator: "\n") + "\n"
    }

    /// The distinct outbound command identifiers, in the order first sent.
    public var outboundCommands: [PenCommand?] {
        let commands = state.withLock { $0.outboundCommands }
        var seen = Set<String>()
        var distinct: [PenCommand?] = []
        for command in commands where seen.insert(Self.label(command)).inserted {
            distinct.append(command)
        }
        return distinct
    }

    /// Writes the transcript to a file, replacing any previous contents.
    public func write(to url: URL) throws {
        try contents().write(to: url, atomically: true, encoding: .utf8)
    }

    /// A stable label for a command identifier.
    private static func label(_ command: PenCommand?) -> String {
        guard let command else { return "unknown" }
        return String(format: "0x%02X", command.rawValue)
    }
}
