import Foundation
import NeoCore
import Synchronization

/// One lifecycle state of a pen session.
///
/// A session reports one state at a time. Scanning and connecting the Bluetooth
/// link belong to the host, so a session starts at `connecting` once it has a
/// transport to drive.
public enum PenSessionState: Hashable, Sendable {
    /// No session has started.
    case idle

    /// The version handshake is in progress.
    case connecting

    /// The pen reported a version and the session is checking it.
    case verifying

    /// The session is discovering notes and reading offline data.
    case syncing

    /// Every discovered note was read.
    case complete

    /// A step failed. A new session can begin without restarting the host.
    case failed(PenSessionError)

    /// Whether the session has stopped and will do no more work.
    public var isTerminal: Bool {
        switch self {
        case .complete, .failed:
            return true
        case .idle, .connecting, .verifying, .syncing:
            return false
        }
    }

    /// A short, stable label for presentation.
    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .connecting: return "Connecting"
        case .verifying: return "Verifying pen"
        case .syncing: return "Reading pen data"
        case .complete: return "Complete"
        case .failed: return "Failed"
        }
    }
}

/// The wait a bounded session step guards.
public enum PenSessionStep: String, Hashable, Sendable, CaseIterable {
    /// Sending `0x01` and awaiting the `0x81` version response.
    case handshake

    /// Sending `0x04` and awaiting the `0x84` pen state.
    case penState

    /// Sending `0x21` and awaiting the `0xA1` note list.
    case noteList

    /// Sending `0x22` and awaiting the `0xA2` page list.
    case pageList

    /// Sending `0x23` and awaiting the `0xA3` info response.
    case dataInfo

    /// Awaiting the next `0x24` data packet.
    case dataPacket

    /// A short description for an error message.
    public var label: String {
        switch self {
        case .handshake: return "the version handshake"
        case .penState: return "the pen state response"
        case .noteList: return "the offline note list"
        case .pageList: return "the offline page list"
        case .dataInfo: return "the offline data info response"
        case .dataPacket: return "the next offline data packet"
        }
    }
}

/// Why a pen session failed.
///
/// Every case is descriptive, because the app shows the message to the user and
/// offers a retry.
public enum PenSessionError: Error, Hashable, Sendable {
    /// A framing, size-limit, or payload failure reported by the codec.
    case protocolFailure(PenProtocolError)

    /// The transport's inbound stream ended while a response was expected.
    case transportEnded(step: PenSessionStep)

    /// A required response or packet did not arrive before its deadline.
    case timedOut(step: PenSessionStep)

    /// The caller cancelled the session.
    case cancelled

    /// The transport failed for a reason outside the protocol.
    case transportFailure(description: String)

    /// The pen rejected the SDK's default `0x01` connection code.
    ///
    /// This pen is passcode-protected or outside the supported family. The
    /// session does not guess another code.
    case penRejectedHandshake(code: UInt8)

    /// The pen reported a protocol version the validated-minor policy rejects.
    case unsupportedVersion(ProtocolVersion)

    /// The command has no official SDK or physical-device evidence.
    case unsupportedCommand(PenCommand)

    /// The evidence table does not classify the command's framing.
    case missingFramingEvidence(command: PenCommand)

    /// No evidence-backed initial section and owner, so discovery cannot start.
    case discoveryUnsupported(reason: String)

    /// The inbound stream ended before the transfer's end-position packet.
    case incompleteTransfer(assembledPacketCount: Int)

    /// The transfer uses a shape this build has no evidence for.
    case unsupportedTransfer(reason: String)

    /// A frame arrived where a different command was expected.
    case unexpectedResponse(expected: PenCommand, received: PenCommand?)

    /// The session is already running.
    case alreadyRunning

    /// A human-readable message for the app's error row.
    public var message: String {
        switch self {
        case .protocolFailure(let error):
            return "The pen sent a frame that could not be decoded (\(error.kind))."
        case .transportEnded(let step):
            return "The pen stopped responding while waiting for \(step.label)."
        case .timedOut(let step):
            return "Timed out waiting for \(step.label)."
        case .cancelled:
            return "The read was cancelled."
        case .transportFailure(let description):
            return "The pen connection failed: \(description)"
        case .penRejectedHandshake(let code):
            return "The pen rejected the SDK's default connection code (error \(code)). It may be passcode-protected or unsupported."
        case .unsupportedVersion(let version):
            return "Protocol version \(version) is not validated for this build."
        case .unsupportedCommand(let command):
            return "Command 0x\(String(command.rawValue, radix: 16, uppercase: true)) has no evidence and was not sent."
        case .missingFramingEvidence(let command):
            return "Command 0x\(String(command.rawValue, radix: 16, uppercase: true)) has no recorded frame layout and was not sent."
        case .discoveryUnsupported(let reason):
            return "Offline discovery is unsupported: \(reason)"
        case .incompleteTransfer(let packetCount):
            return "The transfer ended after \(packetCount) packet(s) without an end packet."
        case .unsupportedTransfer(let reason):
            return "The transfer uses an unsupported shape: \(reason)"
        case .unexpectedResponse(let expected, let received):
            let receivedLabel = received.map { "0x\(String($0.rawValue, radix: 16, uppercase: true))" } ?? "an unknown command"
            return "Expected 0x\(String(expected.rawValue, radix: 16, uppercase: true)) but received \(receivedLabel)."
        case .alreadyRunning:
            return "This session is already running."
        }
    }
}

/// The bounded waits one session applies.
///
/// Every wait is bounded so a silent pen fails the session instead of hanging
/// the app.
public struct PenSessionTimeouts: Hashable, Sendable {
    /// The wait for the `0x81` version response.
    public var handshake: Duration

    /// The wait for the `0x84` pen state response.
    public var penState: Duration

    /// The wait for the `0xA1` note list.
    public var noteList: Duration

    /// The wait for the `0xA2` page list.
    public var pageList: Duration

    /// The wait for the `0xA3` info response.
    public var dataInfo: Duration

    /// The wait for one `0x24` data packet.
    public var dataPacket: Duration

    public init(
        handshake: Duration = .seconds(10),
        penState: Duration = .seconds(10),
        noteList: Duration = .seconds(10),
        pageList: Duration = .seconds(10),
        dataInfo: Duration = .seconds(10),
        dataPacket: Duration = .seconds(20)
    ) {
        self.handshake = handshake
        self.penState = penState
        self.noteList = noteList
        self.pageList = pageList
        self.dataInfo = dataInfo
        self.dataPacket = dataPacket
    }

    /// The values a session uses when the caller does not override them.
    public static let `default` = PenSessionTimeouts()

    /// The duration for one step.
    public func duration(for step: PenSessionStep) -> Duration {
        switch step {
        case .handshake: return handshake
        case .penState: return penState
        case .noteList: return noteList
        case .pageList: return pageList
        case .dataInfo: return dataInfo
        case .dataPacket: return dataPacket
        }
    }
}

/// The evidence behind the session's initial offline note list request.
///
/// The request layout needs a starting `sectionOwnerId`, and the offline capture
/// summary does not record the one the spike harness sent. The official SDK
/// answers that question: `REQ.OfflineNoteList` hard-codes `0xffffffff`, which
/// asks the pen for every note instead of for one section and owner. A host
/// without that evidence must not guess, so it reports discovery as unsupported
/// and sends no list request.
public enum PenOfflineDiscoveryBootstrap: Hashable, Sendable {
    /// The documented wildcard, from `REQ.OfflineNoteList`.
    case documentedWildcard(UInt32)

    /// No evidence-backed value, so no `0x21` request may be sent.
    case unavailable(reason: String)

    /// The value the Neo iOS SDK 3.0 sends.
    public static let neoSDK3 = PenOfflineDiscoveryBootstrap.documentedWildcard(
        PenRequest.noteListSectionOwnerWildcard
    )
}

/// One note's contribution to a completed sync.
public struct PenNoteTransfer: Hashable, Sendable {
    /// The note that was read.
    public let note: PenOfflineNote

    /// The pages the `0xA2` list reported for the note.
    public let listedPages: [UInt32]

    /// The distinct canonical pages the transfer's strokes belong to.
    public let pageIdentities: [PageIdentity]

    /// The `0xA3` summary the pen reported before the transfer. Diagnostic only.
    public let info: PenOfflineDataInfo

    /// Strokes assembled from the transfer's `0x24` packets.
    public let strokes: [Stroke]

    /// How many `0x24` packets carried the transfer.
    public let packetCount: Int

    /// Strokes the transfer carried.
    public var strokeCount: Int { strokes.count }

    /// Dots in those strokes.
    public var dotCount: Int {
        strokes.reduce(0) { total, stroke in total + stroke.points.count }
    }
}

/// The assembled result of one pen session.
///
/// The counts come from the accepted `0x24` packets, not from the `0xA3`
/// summary, because the physical A1's summary lagged its transfer by two stroke
/// records. The summary is kept alongside for diagnostics.
public struct PenSessionResult: Hashable, Sendable {
    /// The protocol version the pen reported.
    public let version: ProtocolVersion

    /// The pen's advertised device name and firmware version.
    public let versionInfo: PenVersionInfo

    /// The measured state when this session requested it.
    public let penState: PenState?

    /// One entry per note that was read, in the order the pen listed them.
    public let notes: [PenNoteTransfer]

    /// Every assembled stroke, in transfer order.
    public let strokes: [Stroke]

    /// Strokes assembled from the accepted packets.
    public var strokeCount: Int { strokes.count }

    /// Dots in the assembled strokes.
    public var dotCount: Int {
        strokes.reduce(0) { total, stroke in total + stroke.points.count }
    }

    /// Distinct canonical pages the assembled strokes belong to.
    public var distinctPageCount: Int {
        Set(strokes.map(\.page)).count
    }

    /// Whether the pen reported no offline note at all.
    public var isEmpty: Bool { notes.isEmpty }
}

/// Drives one pen through the verified handshake and offline retrieval.
///
/// The session exchanges bytes only through `PenTransport`, so the same
/// lifecycle runs against `FakePenTransport` on Linux and against
/// `CoreBluetoothPenTransport` in the app. It performs the `0x01`/`0x81`
/// handshake, gates on `ProtocolVersionPolicy`, discovers notes with `0x21` /
/// `0xA1` and pages with `0x22` / `0xA2`, requests each discovered note with
/// `0x23`, reads its `0xA3` info response, assembles the `0x24` stream, and
/// acknowledges every packet with `0xA4` — `Continue` while the transfer runs
/// and `Stop` for the end-position packet.
///
/// A session is one attempt. `run()` creates fresh framing and assembly state,
/// so a retry is a new session over a new transport; the failed session closes
/// the transport it was given.
///
/// The session sends the `0x23` transfer option it was built with, which defaults
/// to the non-destructive ``OfflineReadTransferOption/nextAndReserve``. The option
/// is a parameter so the acceptance run can vary it while establishing which value
/// is incremental; no trace has settled that yet.
///
/// Deletion is not part of a read: the session sends no `0x25` or `0x27` command,
/// and the evidence table gates both behind the deletion evidence, which no
/// physical A1 trace has opened yet. Cleanup travels on the acknowledged path
/// instead, so it can be ordered after a durable import and published exports;
/// see ``PenCleanupPolicy``.
public final class PenSession: Sendable {
    private struct Status: Sendable {
        var state: PenSessionState = .idle
        var isRunning = false
    }

    private let transport: PenTransport
    private let versionPolicy: ProtocolVersionPolicy
    private let registry: CommandEvidenceRegistry
    private let timeouts: PenSessionTimeouts
    private let bootstrap: PenOfflineDiscoveryBootstrap
    private let transferOption: OfflineReadTransferOption
    private let connectionCode: [UInt8]
    private let appVersion: String
    private let declaredProtocolVersion: String
    private let penClockIsTrusted: Bool
    private let queryPenState: Bool
    private let onStateChange: (@Sendable (PenSessionState) -> Void)?
    private let status = Mutex(Status())

    /// Creates a session over an existing transport.
    ///
    /// - Parameters:
    ///   - transport: The byte channel to the pen. The host owns scanning and
    ///     connecting; the session takes over once a transport exists.
    ///   - versionPolicy: The validated-minor policy the version gate applies.
    ///   - registry: The command evidence table. A command the table does not
    ///     authorize is never sent.
    ///   - timeouts: The bounded waits.
    ///   - bootstrap: The evidence behind the initial `0x21` `sectionOwnerId`.
    ///   - transferOption: The `0x23` transfer option the read sends. It defaults
    ///     to ``OfflineReadTransferOption/nextAndReserve``, the option two physical
    ///     reads established as non-destructive. The parameter exists because
    ///     establishing which option is incremental is an experiment: the
    ///     acceptance run varies it, and the default is what the app sends until a
    ///     trace says otherwise.
    ///   - connectionCode: The `0x01` connection code. The SDK default of
    ///     sixteen zero bytes is the only value with evidence.
    ///   - appVersion: The application version the `0x01` request reports.
    ///   - declaredProtocolVersion: The protocol version the `0x01` request
    ///     declares, which is the version the host's wire format was built
    ///     against.
    ///   - penClockIsTrusted: Whether the pen's clock may be trusted for
    ///     cross-source stroke deduplication.
    ///   - onStateChange: Called on every state change, for presentation.
    public init(
        transport: PenTransport,
        versionPolicy: ProtocolVersionPolicy = .neoSDK3,
        registry: CommandEvidenceRegistry = .neoSDK3,
        timeouts: PenSessionTimeouts = .default,
        bootstrap: PenOfflineDiscoveryBootstrap = .neoSDK3,
        transferOption: OfflineReadTransferOption = .nextAndReserve,
        connectionCode: [UInt8] = PenRequest.defaultConnectionCode,
        appVersion: String = "1.0.0",
        declaredProtocolVersion: String = PenRequest.sdkDeclaredProtocolVersion,
        penClockIsTrusted: Bool = true,
        queryPenState: Bool = false,
        onStateChange: (@Sendable (PenSessionState) -> Void)? = nil
    ) {
        self.transport = transport
        self.versionPolicy = versionPolicy
        self.registry = registry
        self.timeouts = timeouts
        self.bootstrap = bootstrap
        self.transferOption = transferOption
        self.connectionCode = connectionCode
        self.appVersion = appVersion
        self.declaredProtocolVersion = declaredProtocolVersion
        self.penClockIsTrusted = penClockIsTrusted
        self.queryPenState = queryPenState
        self.onStateChange = onStateChange
    }

    /// The current lifecycle state.
    public var state: PenSessionState {
        status.withLock { $0.state }
    }

    /// Runs the handshake, the version gate, and offline retrieval.
    ///
    /// - Returns: The assembled transfers and their decoded counts.
    /// - Throws: A `PenSessionError` describing the failed step. The transport is
    ///   closed before the error is rethrown.
    public func run() async throws -> PenSessionResult {
        let started = status.withLock { status -> Bool in
            guard !status.isRunning else { return false }
            status.isRunning = true
            return true
        }
        guard started else {
            throw PenSessionError.alreadyRunning
        }

        transition(to: .connecting)

        do {
            let result = try await perform()
            status.withLock { $0.isRunning = false }
            transition(to: .complete)
            return result
        } catch {
            let failure = Self.normalize(error)
            status.withLock { $0.isRunning = false }
            transition(to: .failed(failure))
            await transport.close()
            throw failure
        }
    }

    // MARK: - Session body

    private func perform() async throws -> PenSessionResult {
        // Fresh framing state for this attempt: the decoder buffers a partial
        // frame across chunks, so it must not outlive one session.
        let channel = PenFrameChannel(stream: transport.receive())

        // 1. Handshake.
        try await send(
            PenRequest.versionInfo(
                connectionCode: connectionCode,
                appVersion: appVersion,
                protocolVersion: declaredProtocolVersion
            ),
            command: .versionInfo
        )

        guard let versionFrame = try await awaitFrame(
            channel: channel,
            expecting: .responseVersionInfo,
            step: .handshake
        ) else {
            throw PenSessionError.transportEnded(step: .handshake)
        }
        try requireHandshakeAccepted(versionFrame)

        guard let info = PenVersionInfo(payload: versionFrame.payload),
              let version = info.protocolVersion
        else {
            throw PenSessionError.protocolFailure(
                .malformedPayload(
                    command: .responseVersionInfo,
                    reason: "version response could not be decoded"
                )
            )
        }

        // 2. Version gate.
        transition(to: .verifying)
        guard versionPolicy.support(for: version).isSupported else {
            throw PenSessionError.unsupportedVersion(version)
        }

        let measuredState: PenState?
        if queryPenState {
            try await send(PenRequest.penState(), command: .penState)
            guard let stateFrame = try await awaitFrame(
                channel: channel,
                expecting: .responsePenState,
                step: .penState
            ) else {
                throw PenSessionError.transportEnded(step: .penState)
            }
            try requireAccepted(stateFrame)
            guard let state = PenState(payload: stateFrame.payload) else {
                throw PenSessionError.protocolFailure(
                    .malformedPayload(command: .responsePenState, reason: "expected a 64-byte state with percentages from 0 through 100")
                )
            }
            measuredState = state
        } else {
            measuredState = nil
        }

        // 3. Discovery and retrieval.
        transition(to: .syncing)

        let notes = try await discoverNotes(channel: channel)

        // An empty list is a completed sync with zero counts, not a failure:
        // there is simply nothing to read.
        guard !notes.isEmpty else {
            return PenSessionResult(
                version: version,
                versionInfo: info,
                penState: measuredState,
                notes: [],
                strokes: []
            )
        }

        var transfers: [PenNoteTransfer] = []
        var strokes: [Stroke] = []
        for note in notes {
            let transfer = try await readNote(note, channel: channel)
            transfers.append(transfer)
            strokes.append(contentsOf: transfer.strokes)
        }

        return PenSessionResult(
            version: version,
            versionInfo: info,
            penState: measuredState,
            notes: transfers,
            strokes: strokes
        )
    }

    /// Sends `0x21` and decodes the `0xA1` note list.
    private func discoverNotes(channel: PenFrameChannel) async throws -> [PenOfflineNote] {
        let sectionOwnerId: UInt32
        switch bootstrap {
        case .documentedWildcard(let wildcard):
            sectionOwnerId = wildcard
        case .unavailable(let reason):
            // No evidence-backed value, so no list request may be sent.
            throw PenSessionError.discoveryUnsupported(reason: reason)
        }

        try await send(
            PenRequest.noteList(sectionOwnerId: sectionOwnerId),
            command: .offlineNoteListRequest
        )

        guard let frame = try await awaitFrame(
            channel: channel,
            expecting: .responseOfflineNoteList,
            step: .noteList
        ) else {
            throw PenSessionError.transportEnded(step: .noteList)
        }
        try requireAccepted(frame)

        switch PenOfflineListDecoder.decodeNoteList(payload: frame.payload) {
        case .notes(let notes):
            return notes
        case .error(let error):
            // No guessed identifier is sent: a list that cannot be decoded stops
            // retrieval before `0x23`.
            throw PenSessionError.protocolFailure(error)
        }
    }

    /// Reads one discovered note: `0x22`, `0x23`, `0xA3`, then the `0x24` stream.
    private func readNote(
        _ note: PenOfflineNote,
        channel: PenFrameChannel
    ) async throws -> PenNoteTransfer {
        try await send(
            PenRequest.pageList(for: note),
            command: .offlinePageListRequest
        )

        guard let pageFrame = try await awaitFrame(
            channel: channel,
            expecting: .responseOfflinePageList,
            step: .pageList
        ) else {
            throw PenSessionError.transportEnded(step: .pageList)
        }
        try requireAccepted(pageFrame)

        let listedPages: [UInt32]
        switch PenOfflineListDecoder.decodePageList(payload: pageFrame.payload) {
        case .pages(let decoded):
            listedPages = decoded.pages
        case .error(let error):
            throw PenSessionError.protocolFailure(error)
        }

        try await send(
            PenRequest.offlineData(for: note, transferOption: transferOption),
            command: .offlineDataRequest1
        )

        guard let infoFrame = try await awaitFrame(
            channel: channel,
            expecting: .responseOfflineDataInfo,
            step: .dataInfo
        ) else {
            throw PenSessionError.transportEnded(step: .dataInfo)
        }
        try requireAccepted(infoFrame)

        guard let info = PenOfflineListDecoder.decodeInfo(payload: infoFrame.payload) else {
            throw PenSessionError.protocolFailure(
                .malformedPayload(
                    command: .responseOfflineDataInfo,
                    reason: "offline data info payload is too short"
                )
            )
        }

        // The stream: one packet per acknowledgement, until the end packet.
        var assembler = OfflineTransferAssembler()
        var packets: [OfflineTransferProgress] = []
        var strokes: [Stroke] = []

        while true {
            guard let frame = try await awaitFrame(
                channel: channel,
                expecting: .offlineDataRequest2,
                step: .dataPacket
            ) else {
                // A normal stream finish before an end-position packet is an
                // incomplete transfer, never a completed result.
                throw PenSessionError.incompleteTransfer(
                    assembledPacketCount: assembler.assembledPacketCount
                )
            }

            let progress: OfflineTransferProgress
            switch assembler.ingest(payload: frame.payload, penClockIsTrusted: penClockIsTrusted) {
            case .packet(let accepted):
                progress = accepted
            case .unsupported(let reason):
                throw PenSessionError.unsupportedTransfer(reason: reason)
            case .error(let error):
                throw PenSessionError.protocolFailure(error)
            }

            packets.append(progress)
            strokes.append(contentsOf: progress.records.map(\.stroke))

            // One acknowledgement per packet: Continue while the transfer runs,
            // Stop for the end packet. The pen sends the next packet only after
            // the acknowledgement, so this must happen before the next read.
            let operation: PenTransferAcknowledgement = progress.isTransferComplete ? .stop : .next
            try await send(
                PenRequest.acknowledgement(packetID: progress.header.packetID, operation: operation),
                command: .responseOfflineData
            )

            if progress.isTransferComplete {
                break
            }
        }

        guard assembler.isComplete else {
            throw PenSessionError.incompleteTransfer(
                assembledPacketCount: assembler.assembledPacketCount
            )
        }

        // Counts come from the accepted packets, never from the `0xA3` summary.
        return PenNoteTransfer(
            note: note,
            listedPages: listedPages,
            pageIdentities: Self.distinctPages(in: strokes),
            info: info,
            strokes: strokes,
            packetCount: packets.count
        )
    }

    // MARK: - Transport helpers

    /// Sends one outbound frame, refusing a command without evidence.
    private func send(_ frame: [UInt8]?, command: PenCommand) async throws {
        guard registry.maySendProductionRequest(command) else {
            throw PenSessionError.unsupportedCommand(command)
        }
        guard let frame else {
            throw PenSessionError.missingFramingEvidence(command: command)
        }
        try await transport.send(frame)
    }

    /// Returns the next frame, or `nil` when the inbound stream ended.
    ///
    /// - Throws: `PenSessionError.unexpectedResponse` when a different command
    ///   arrived, and `protocolFailure` when the frame itself is malformed.
    private func awaitFrame(
        channel: PenFrameChannel,
        expecting command: PenCommand,
        step: PenSessionStep
    ) async throws -> PenFrame? {
        let outcome = try await withDeadline(step) {
            try await channel.next()
        }

        guard let outcome else {
            if Task.isCancelled {
                throw PenSessionError.cancelled
            }
            return nil
        }

        switch outcome {
        case .error(let error):
            throw PenSessionError.protocolFailure(error)
        case .frame(let frame):
            guard frame.command == command else {
                throw PenSessionError.unexpectedResponse(
                    expected: command,
                    received: frame.command
                )
            }
            return frame
        }
    }

    /// Races a wait against its deadline.
    ///
    /// The group must return even when the losing branch is suspended inside a
    /// read, because `PenSession` can only close the transport after this call
    /// fails. That holds because the only `operation` is
    /// `PenFrameChannel.next()`, whose read is an
    /// `AsyncThrowingStream.Iterator.next()`: the standard library installs a
    /// cancellation handler on that read, so cancelling the branch terminates the
    /// stream and resumes the pending read with `nil`. Keep `operation` reachable
    /// only from `awaitFrame` so this stays true —
    /// `testSilentPenTimesOutOnTheNoteListAndClosesTheTransport` proves it end to
    /// end with a transport whose stream never finishes: the wait reports
    /// `timedOut` and the transport is closed.
    private func withDeadline<T: Sendable>(
        _ step: PenSessionStep,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let duration = timeouts.duration(for: step)
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw PenSessionError.timedOut(step: step)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw PenSessionError.timedOut(step: step)
            }
            return first
        }
    }

    /// Fails when a response reported a non-zero error code.
    private func requireAccepted(_ frame: PenFrame) throws {
        guard let command = frame.command else {
            throw PenSessionError.protocolFailure(.unknownCommand(byte: frame.commandByte))
        }
        guard let code = frame.errorCode else {
            throw PenSessionError.protocolFailure(
                .malformedPayload(command: command, reason: "response carried no error code")
            )
        }
        guard code == 0 else {
            throw PenSessionError.protocolFailure(.commandFailed(command: command, code: code))
        }
    }

    /// Fails when the handshake response reported a non-zero error code.
    ///
    /// The handshake is the one step with a dedicated failure: a rejected
    /// connection code means a protected or unsupported pen, and the session
    /// must not guess another code.
    private func requireHandshakeAccepted(_ frame: PenFrame) throws {
        guard let code = frame.errorCode else {
            throw PenSessionError.protocolFailure(
                .malformedPayload(
                    command: .responseVersionInfo,
                    reason: "version response carried no error code"
                )
            )
        }
        guard code == 0 else {
            throw PenSessionError.penRejectedHandshake(code: code)
        }
    }

    private func transition(to state: PenSessionState) {
        status.withLock { $0.state = state }
        onStateChange?(state)
    }

    private static func distinctPages(in strokes: [Stroke]) -> [PageIdentity] {
        var seen = Set<PageIdentity>()
        var ordered: [PageIdentity] = []
        for stroke in strokes where seen.insert(stroke.page).inserted {
            ordered.append(stroke.page)
        }
        return ordered
    }

    private static func normalize(_ error: any Error) -> PenSessionError {
        switch error {
        case let sessionError as PenSessionError:
            return sessionError
        case let protocolError as PenProtocolError:
            return .protocolFailure(protocolError)
        case is CancellationError:
            return .cancelled
        default:
            return .transportFailure(description: String(describing: error))
        }
    }
}
