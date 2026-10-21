import Foundation
import NeoBridgeMacCore
import NeoProtocol
import Synchronization

/// One command the lab sends, and the answer it expects.
struct PenLabStep: Sendable {
    /// A name for the transcript.
    let name: String

    /// The request identifier.
    let request: UInt8

    /// The identifier that answers it.
    let response: UInt8

    /// What the pen is being told to remove, in words.
    let scope: String

    /// The framed bytes to send.
    let frame: [UInt8]
}

/// The inbound bytes, and how the consumer task hands them to the run.
///
/// A stream cannot be polled, and the run wants a deadline it can honour without
/// risking a hang on a stream that has nothing to deliver. The consumer task drains
/// the stream into this lock-protected buffer, and the run reads the frames out of
/// it while it waits. The buffer holds raw bytes rather than frames so that the
/// same accumulated run can be parsed again as more bytes arrive.
private final class PenLabInbox: Sendable {
    private struct State: Sendable {
        var bytes: [UInt8] = []
        var isFinished = false
        var failure: String?
        var chunkCount = 0
    }

    private let state = Mutex(State())

    /// Appends one inbound chunk.
    func append(chunk: [UInt8]) {
        state.withLock {
            $0.bytes.append(contentsOf: chunk)
            $0.chunkCount += 1
        }
    }

    /// Marks the stream as finished.
    func finish(failure: String? = nil) {
        state.withLock {
            $0.isFinished = true
            $0.failure = failure
        }
    }

    /// Every complete frame received so far.
    var frames: [PenLabFrame] {
        PenLabFrames.extract(from: state.withLock { $0.bytes })
    }

    /// How many chunks arrived.
    var chunkCount: Int {
        state.withLock { $0.chunkCount }
    }

    /// Whether the stream has ended, and why.
    var ending: (isFinished: Bool, failure: String?) {
        state.withLock { ($0.isFinished, $0.failure) }
    }
}

/// Runs one deletion experiment over the real radio.
///
/// The run is deliberately narrow: connect, hand shake, send one frame per step, wait
/// for each answer, close. It neither reads nor writes the library, and it does not
/// follow the app's ordering rule, because the point is to see what the pen says to a
/// command on its own. Everything the pen answers is recorded, including silence.
struct PenLabRun {
    /// The steps to send, in order.
    let steps: [PenLabStep]

    /// How long to wait for each response.
    let timeout: Double

    /// Whether to send anything at all.
    ///
    /// A dry run prints every frame and opens no connection, so the frames can be
    /// read and checked before the pen sees them.
    let shouldSend: Bool

    /// Where to write the transcript in addition to standard output.
    let traceURL: URL?

    /// The header lines the invocation wants recorded, so the transcript says what
    /// was asked for as well as what happened.
    let header: [String]

    /// Runs the experiment.
    ///
    /// - Returns: The process status: 0 when every step was answered with error code
    ///   0, 1 when a step was refused or went unanswered, 2 when the invocation was.
    func run() async -> Int32 {
        var transcript = PenLabTranscript()
        transcript.record("run pen-lab")
        for line in header {
            transcript.record(line)
        }
        for step in steps {
            transcript.record("plan \(step.name) scope=\(step.scope)")
            transcript.record(
                "plan \(step.name) request=0x\(String(format: "%02X", step.request))"
                    + " expects=0x\(String(format: "%02X", step.response))"
                    + " frame=\(PenLabFrames.hex(step.frame))"
            )
        }

        guard shouldSend else {
            transcript.record("result dry run: nothing was sent, no connection was opened")
            try? transcript.publish(to: traceURL)
            return 0
        }

        do {
            try await perform(transcript: &transcript)
            try transcript.publish(to: traceURL)
            return 0
        } catch let failure as PenLabFailure {
            transcript.record("result failed \(failure)")
            try? transcript.publish(to: traceURL)
            return failure.exitStatus
        } catch {
            transcript.record("result failed unexpected \(error)")
            try? transcript.publish(to: traceURL)
            return 1
        }
    }

    // MARK: - The exchange

    private func perform(transcript: inout PenLabTranscript) async throws {
        let central = CoreBluetoothPenCentral()
        let transport = CoreBluetoothPenTransport(central: central)

        let peripheral: PenPeripheral
        do {
            peripheral = try await transport.connect()
        } catch {
            throw PenLabFailure.connection(String(describing: error))
        }
        // The advertised name is recorded; the peripheral identifier is not, because
        // it names the device.
        transcript.record("link connected name=\(peripheral.name ?? "unnamed")")

        let inbox = PenLabInbox()
        let consumer = Task {
            do {
                for try await chunk in transport.receive() {
                    inbox.append(chunk: chunk)
                }
                inbox.finish()
            } catch {
                inbox.finish(failure: String(describing: error))
            }
        }

        do {
            try await exchange(over: transport, inbox: inbox, transcript: &transcript)
        } catch {
            // A refused or unanswered step must still release the link. A connected
            // pen stops advertising, so a run that walked away from a refusal would
            // leave the next run unable to find the pen.
            await finish(over: transport, inbox: inbox, consumer: consumer, transcript: &transcript)
            throw error
        }
        await finish(over: transport, inbox: inbox, consumer: consumer, transcript: &transcript)
    }

    /// The handshake and the steps, in order.
    private func exchange(
        over transport: CoreBluetoothPenTransport,
        inbox: PenLabInbox,
        transcript: inout PenLabTranscript
    ) async throws {
        // The version handshake is the same `0x01` request the session sends, and it
        // is framed by the evidence table, so the lab reuses `PenRequest` for it.
        guard let handshake = PenRequest.versionInfo() else {
            throw PenLabFailure.handshake("the version request could not be framed")
        }
        transcript.record("link handshake request=\(PenLabFrames.hex(handshake))")
        try await send(handshake, over: transport)

        var cursor = 0
        guard let versionResponse = try await awaitFrame(
            command: PenCommand.responseVersionInfo.rawValue,
            inbox: inbox,
            cursor: &cursor,
            seconds: timeout,
            step: "handshake"
        ) else {
            throw PenLabFailure.handshake("the pen did not answer the version request")
        }
        // The version payload is not recorded: it carries the pen's address.
        transcript.record(
            "link handshake answered error="
                + "\(versionResponse.errorCode.map { String(format: "0x%02X", $0) } ?? "none")"
        )
        if let errorCode = versionResponse.errorCode, errorCode != 0 {
            throw PenLabFailure.handshake("the pen reported error code 0x\(String(format: "%02X", errorCode))")
        }

        for step in steps {
            transcript.record("send \(step.name) bytes=\(step.frame.count)")
            try await send(step.frame, over: transport)

            let started = ContinuousClock.now
            guard let response = try await awaitFrame(
                command: step.response,
                inbox: inbox,
                cursor: &cursor,
                seconds: timeout,
                step: step.name
            ) else {
                throw PenLabFailure.noResponse(step: step.name, seconds: timeout)
            }
            let elapsed = ContinuousClock.now - started
            transcript.record(
                "response \(step.name) command=\(String(format: "%02X", response.command))"
                    + " error=\(response.errorCode.map { String(format: "0x%02X", $0) } ?? "none")"
                    + " milliseconds=\(elapsed.milliseconds)"
                    + " framing=\(response.framingIsFromEvidence ? "evidence" : "unclassified")"
            )
            transcript.record(
                "response \(step.name) body=\(response.bodyHex)"
                    + " declaredLength=\(response.declaredLength.map(String.init) ?? "none")"
                    + (response.isTruncated ? " truncated" : "")
            )
            transcript.record(
                "response \(step.name) payload=\(PenLabFrames.hex(response.payload))"
            )
            transcript.record("response \(step.name) \(describe(response))")

            if let errorCode = response.errorCode, errorCode != 0 {
                throw PenLabFailure.rejected(step: step.name, errorCode: errorCode)
            }
        }

    }

    /// Accounts for every inbound frame and releases the link.
    ///
    /// This runs on the success path and after a failure, so the transcript always
    /// ends with what arrived and with the link being closed.
    private func finish(
        over transport: CoreBluetoothPenTransport,
        inbox: PenLabInbox,
        consumer: Task<Void, Never>,
        transcript: inout PenLabTranscript
    ) async {
        // Every inbound frame is accounted for, so a response that was not the one
        // expected is still visible rather than silently dropped.
        for frame in inbox.frames where frame.command != PenCommand.responseVersionInfo.rawValue {
            if isPayloadRecorded(frame) { continue }
            transcript.record(
                "inbound other command=\(String(format: "%02X", frame.command))"
                    + " bytes=\(frame.payload.count) (payload not recorded)"
            )
        }

        transcript.record("link closing chunks=\(inbox.chunkCount)")
        await transport.close()
        consumer.cancel()
        try? await Task.sleep(for: .milliseconds(1500))
        if let failure = inbox.ending.failure {
            transcript.record("link inbound stream ended with \(failure)")
        }
    }

    /// Sends one frame.
    private func send(_ bytes: [UInt8], over transport: CoreBluetoothPenTransport) async throws {
        do {
            try await transport.send(bytes)
        } catch {
            throw PenLabFailure.connection(String(describing: error))
        }
    }

    /// Waits for one response identifier, advancing the cursor past what it read.
    private func awaitFrame(
        command: UInt8,
        inbox: PenLabInbox,
        cursor: inout Int,
        seconds: Double,
        step: String
    ) async throws -> PenLabFrame? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            let frames = inbox.frames
            while cursor < frames.count {
                let frame = frames[cursor]
                cursor += 1
                if frame.command == command {
                    return frame
                }
            }
            if inbox.ending.isFinished {
                return nil
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    // MARK: - Rendering

    /// Whether a frame's payload is one the transcript records in full.
    ///
    /// Only the two deletion answers qualify. Every other inbound frame is recorded by
    /// identifier and size, because the version response carries the pen's address.
    private func isPayloadRecorded(_ frame: PenLabFrame) -> Bool {
        PenLabFrames.recordedResponseCommands.contains(frame.command)
    }

    /// A sentence describing what the pen answered.
    ///
    /// The SDK's parser reads a deletion response as a count followed by that many
    /// identifiers. A payload that does not carry them is reported as the mismatch it
    /// is, rather than being smoothed into a reading the bytes do not support.
    private func describe(_ frame: PenLabFrame) -> String {
        guard isPayloadRecorded(frame) else {
            return "no decoded meaning"
        }
        if let errorCode = frame.errorCode, errorCode != 0 {
            return "the pen refused the command with error code 0x\(String(format: "%02X", errorCode))"
        }
        guard let count = frame.payload.first else {
            return "the pen reported success with no payload"
        }
        guard let identifiers = PenLabFrames.deletedIdentifiers(in: frame.payload) else {
            return "the pen reported success and declared \(count) removed,"
                + " but the payload carries no identifier list of that length"
        }
        guard !identifiers.isEmpty else {
            return "the pen reported success and removed nothing"
        }
        return "the pen reported success and removed \(identifiers.count): "
            + identifiers.map(String.init).joined(separator: ",")
    }

}

private extension Duration {
    /// The duration in whole milliseconds.
    var milliseconds: Int {
        let parts = components
        return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }
}
