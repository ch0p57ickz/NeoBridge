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

/// A `0x23` transfer the lab drives itself.
///
/// The read path takes an ``OfflineReadTransferOption``, which has no deleting member,
/// so a transfer that asks the pen to delete as it streams has to be driven here. The
/// loop is the session's: acknowledge each `0x24` packet as it arrives, and answer the
/// end packet with Stop.
struct PenLabTransfer: Sendable {
    /// The `0x23` request frame, carrying transfer option `0x01`.
    let request: [UInt8]

    /// What the transfer reads, in words, for the transcript.
    let scope: String

    /// The arriving packet whose acknowledgement is withheld, or `nil`.
    ///
    /// Packet numbers are the run's own count of arriving packets, not the wire
    /// identifier. Withholding one acknowledgement leaves the pen waiting, which is
    /// what a closed link looks like from the pen's side.
    let abortAtPacket: Int?
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

/// How many inbound frames the run has taken.
///
/// The count is held outside the run's local state so that the accounting at the end
/// of a run can name the frames no step consumed even when a step failed and unwound
/// the call it was reading from.
///
/// One task takes frames, and the frame list only grows, so reading `count` while
/// `take()` advances it is safe. A second taker would double-count the frames between
/// the two calls, and the frame list must stay append-only for the indices to mean the
/// same thing at the end of the run as they did when they were taken.
private final class PenLabCursor: Sendable {
    private let position = Mutex(0)

    /// How many frames have been taken.
    var count: Int {
        position.withLock { $0 }
    }

    /// Takes the next frame's index.
    func take() -> Int {
        position.withLock {
            let index = $0
            $0 += 1
            return index
        }
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

    /// The `0x23` transfer to drive after the steps, or `nil` when the experiment
    /// sends one frame per step.
    let transfer: PenLabTransfer?

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
    ///   0, 1 when a step was refused or went unanswered or a requested abort never
    ///   fired, 2 when the invocation was.
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
        if let transfer {
            transcript.record("plan next-delete-0x23 scope=\(transfer.scope)")
            transcript.record(
                "plan next-delete-0x23 request=0x23 transferOption=0x01"
                    + " frame=\(PenLabFrames.hex(transfer.request))"
            )
            transcript.record(
                "plan next-delete abortAtPacket="
                    + (transfer.abortAtPacket.map(String.init) ?? "none")
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
        let cursor = PenLabCursor()
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
            try await exchange(
                over: transport,
                inbox: inbox,
                cursor: cursor,
                transcript: &transcript
            )
        } catch {
            // A refused or unanswered step must still release the link. A connected
            // pen stops advertising, so a run that walked away from a refusal would
            // leave the next run unable to find the pen.
            await finish(
                over: transport,
                inbox: inbox,
                consumer: consumer,
                cursor: cursor,
                transcript: &transcript
            )
            throw error
        }
        await finish(
            over: transport,
            inbox: inbox,
            consumer: consumer,
            cursor: cursor,
            transcript: &transcript
        )
    }

    /// The handshake and the steps, in order.
    private func exchange(
        over transport: CoreBluetoothPenTransport,
        inbox: PenLabInbox,
        cursor: PenLabCursor,
        transcript: inout PenLabTranscript
    ) async throws {
        // The version handshake is the same `0x01` request the session sends, and it
        // is framed by the evidence table, so the lab reuses `PenRequest` for it.
        guard let handshake = PenRequest.versionInfo() else {
            throw PenLabFailure.handshake("the version request could not be framed")
        }
        transcript.record("link handshake request=\(PenLabFrames.hex(handshake))")
        try await send(handshake, over: transport)

        guard let versionResponse = try await awaitFrame(
            command: PenCommand.responseVersionInfo.rawValue,
            inbox: inbox,
            cursor: cursor,
            seconds: timeout,
            step: "handshake",
            transcript: &transcript
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
                cursor: cursor,
                seconds: timeout,
                step: step.name,
                transcript: &transcript
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

        if let transfer {
            try await runTransfer(
                transfer,
                over: transport,
                inbox: inbox,
                cursor: cursor,
                transcript: &transcript
            )
        }
    }

    /// Drives one `0x23` transfer, acknowledging each packet as the session does.
    ///
    /// The loop is the session's, with one difference: the option is the deleting one.
    /// An aborted run stops acknowledging at the chosen packet and returns normally,
    /// because the abort is the experiment rather than a failure; what the pen still
    /// holds is only visible to a read afterwards, which is another run. An abort that
    /// never fires — a packet number past the transfer's length — is a failure: the
    /// run would otherwise report an interrupt it did not perform.
    private func runTransfer(
        _ transfer: PenLabTransfer,
        over transport: CoreBluetoothPenTransport,
        inbox: PenLabInbox,
        cursor: PenLabCursor,
        transcript: inout PenLabTranscript
    ) async throws {
        transcript.record("send next-delete-0x23 bytes=\(transfer.request.count)")
        try await send(transfer.request, over: transport)

        guard let infoFrame = try await awaitFrame(
            command: PenCommand.responseOfflineDataInfo.rawValue,
            inbox: inbox,
            cursor: cursor,
            seconds: timeout,
            step: "next-delete-0x23",
            transcript: &transcript
        ) else {
            throw PenLabFailure.noResponse(step: "next-delete data info", seconds: timeout)
        }
        transcript.record(
            "response next-delete-0x23 error="
                + "\(infoFrame.errorCode.map { String(format: "0x%02X", $0) } ?? "none")"
                + " declaredLength=\(infoFrame.declaredLength.map(String.init) ?? "none")"
                + " payload=\(PenLabFrames.hex(infoFrame.payload))"
        )
        if let errorCode = infoFrame.errorCode, errorCode != 0 {
            throw PenLabFailure.rejected(step: "next-delete-0x23", errorCode: errorCode)
        }
        if let info = PenOfflineListDecoder.decodeInfo(payload: infoFrame.payload) {
            // The pen's index is a lagging summary, so it is recorded as a claim and
            // never as the count of what the transfer carried.
            transcript.record(
                "response next-delete-0x23 info claimedStrokes=\(info.strokeCount)"
                    + " uncompressedBytes=\(info.uncompressedSize)"
                    + " compressed=\(info.isCompressed)"
            )
        } else {
            transcript.record(
                "response next-delete-0x23 info unreadable from"
                    + " \(infoFrame.payload.count) payload byte(s)"
            )
        }

        var assembler = OfflineTransferAssembler()
        var packets = 0
        var acknowledged = 0
        var stopSent = false
        var aborted = false

        while true {
            guard let frame = try await awaitFrame(
                command: PenCommand.offlineDataRequest2.rawValue,
                inbox: inbox,
                cursor: cursor,
                seconds: timeout,
                step: "next-delete data packet",
                transcript: &transcript
            ) else {
                transcript.record(
                    "transfer stream ended after \(packets) packet(s) with no end packet"
                )
                break
            }
            packets += 1
            let strokesBefore = assembler.assembledStrokeCount

            let progress: OfflineTransferProgress
            switch assembler.ingest(payload: frame.payload, penClockIsTrusted: true) {
            case .packet(let accepted):
                progress = accepted
            case .unsupported(let reason):
                throw PenLabFailure.framing("packet \(packets) is unsupported: \(reason)")
            case .error(let error):
                throw PenLabFailure.framing("packet \(packets) could not be assembled: \(error)")
            }
            let packetStrokes = assembler.assembledStrokeCount - strokesBefore

            if let abortAtPacket = transfer.abortAtPacket, packets >= abortAtPacket {
                transcript.record(
                    "transfer withholding the acknowledgement for packet \(packets)"
                        + " packetID=\(progress.header.packetID)"
                        + " strokesInPacket=\(packetStrokes)"
                        + " strokesSoFar=\(assembler.assembledStrokeCount)"
                        + " and closing the link"
                )
                aborted = true
                break
            }

            let operation: PenTransferAcknowledgement =
                progress.isTransferComplete ? .stop : .next
            guard let acknowledgement = PenRequest.acknowledgement(
                packetID: progress.header.packetID,
                operation: operation
            ) else {
                throw PenLabFailure.framing("the 0xA4 acknowledgement could not be framed")
            }
            try await send(acknowledgement, over: transport)
            acknowledged += 1

            if progress.isTransferComplete {
                transcript.record(
                    "transfer end packet packetID=\(progress.header.packetID)"
                        + " strokesInPacket=\(packetStrokes)"
                        + " acknowledged with Stop"
                )
                stopSent = true
                break
            }
        }

        transcript.record(
            "transfer result packets=\(packets)"
                + " acknowledged=\(acknowledged)"
                + " assembledPackets=\(assembler.assembledPacketCount)"
                + " strokes=\(assembler.assembledStrokeCount)"
                + " dots=\(assembler.assembledDotCount)"
                + " complete=\(assembler.isComplete)"
                + " stopSent=\(stopSent)"
                + " aborted=\(aborted)"
        )
        transcript.record(
            "transfer note: only a read afterwards shows what the pen still holds,"
                + " and this run did not read it"
        )

        // A run that neither reached the end packet nor chose to stop early failed,
        // even though the link is healthy: the pen answered the request and then
        // stopped, which is what a refused transfer looks like.
        guard assembler.isComplete || aborted else {
            throw PenLabFailure.noResponse(
                step: "next-delete data packet after \(packets)",
                seconds: timeout
            )
        }
        // An abort asked for and never performed is a failure rather than a quiet
        // success: every packet was acknowledged, so the pen removed everything it
        // sent, which is the opposite of what the operator asked for.
        if let abortAtPacket = transfer.abortAtPacket, !aborted {
            throw PenLabFailure.abortNotReached(requested: abortAtPacket, packets: packets)
        }
    }

    /// Accounts for every inbound frame and releases the link.
    ///
    /// This runs on the success path and after a failure, so the transcript always ends
    /// with what arrived and with the link being closed. A frame a step consumed is not
    /// repeated, because that step's own response line recorded it, and a transfer's
    /// packets are accounted for in one summary line rather than one line each. Every
    /// other frame is reported here: the ones that arrived after the last one taken, and
    /// the ones `awaitFrame` already recorded as unexpected while it waited. A version
    /// response is skipped, because its payload carries the pen's address.
    private func finish(
        over transport: CoreBluetoothPenTransport,
        inbox: PenLabInbox,
        consumer: Task<Void, Never>,
        cursor: PenLabCursor,
        transcript: inout PenLabTranscript
    ) async {
        let frames = inbox.frames
        for index in cursor.count ..< frames.count {
            let frame = frames[index]
            if frame.command == PenCommand.responseVersionInfo.rawValue { continue }
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

    /// Waits for one response identifier, taking the frames it reads.
    ///
    /// A frame whose command is not the one awaited is recorded where it is skipped,
    /// rather than being passed over: the lab rides through an unsolicited frame that
    /// would end an app session, so the transcript has to say it arrived.
    private func awaitFrame(
        command: UInt8,
        inbox: PenLabInbox,
        cursor: PenLabCursor,
        seconds: Double,
        step: String,
        transcript: inout PenLabTranscript
    ) async throws -> PenLabFrame? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            let frames = inbox.frames
            while cursor.count < frames.count {
                let frame = frames[cursor.take()]
                if frame.command == command {
                    return frame
                }
                if frame.command == PenCommand.responseVersionInfo.rawValue { continue }
                transcript.record(
                    "inbound unexpected command=\(String(format: "%02X", frame.command))"
                        + " bytes=\(frame.payload.count) while waiting for"
                        + " 0x\(String(format: "%02X", command)) at \(step)"
                        + " (payload not recorded)"
                )
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
