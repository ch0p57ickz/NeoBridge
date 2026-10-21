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

    /// A deleting packet could not be committed durably, so it was not
    /// acknowledged.
    ///
    /// A refused deleting route is not an error: the read continues
    /// non-destructively and reports the blocker on ``PenSessionResult/deletingReadRefusal``.
    case deletingPacketCommitFailed(reason: String)

    /// The batch a failed deleting read opened could not be marked failed, so it
    /// stays in progress with nothing in it.
    ///
    /// The read's own failure is named in the message: this case exists so a second
    /// storage fault cannot hide the first one.
    case deletingReadNotRecorded(reason: String)

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
        case .deletingPacketCommitFailed(let reason):
            return "The read stopped because a packet could not be stored durably: \(reason)"
        case .deletingReadNotRecorded(let reason):
            return "The read failed and its empty deleting batch could not be marked failed: \(reason)"
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

/// What one deleting transfer left durably committed.
///
/// The report is the honest shape of a deleting read: the pen removed only what
/// the host acknowledged, so the durable prefix, its completion, and whether the
/// last acknowledgement's delivery is certain are the facts the shell reports.
/// It never claims a completed whole-note removal, because the pen's internal
/// removal trigger is not settled by the trace.
public struct PenDeletingTransferReport: Hashable, Sendable {
    /// The batch the packets were committed to.
    public let batchID: UUID

    /// Packets durably committed before their acknowledgements.
    public let committedPacketCount: Int

    /// Strokes the batch added to the library.
    public let committedStrokeCount: Int

    /// Dots in the strokes this batch added to the library.
    ///
    /// A fresh read that replays a packet the pen never had acknowledged adds no
    /// stroke, so the report does not claim those dots twice.
    public let committedDotCount: Int

    /// Strokes the commits added rather than recognized as already stored.
    public let addedStrokeCount: Int

    /// Reliable strokes the commits recognized as already stored.
    public let duplicateStrokeCount: Int

    /// The distinct pages the committed strokes belong to, in canonical order.
    public let pages: [PageIdentity]

    /// Whether every discovered note reached its end packet and Stop was sent, and
    /// that completion was recorded durably.
    ///
    /// It is `false` when the transfer stopped short, and also when it finished but
    /// the durable completion marker could not be written: a restart reads the
    /// batch as still in progress, so the report does not claim more than the record
    /// holds.
    public let isComplete: Bool

    /// Whether every discovered note reached its end packet and Stop was sent.
    ///
    /// It is the transfer's own fact, independent of whether that completion could be
    /// recorded. A transfer that reached its last packet but whose completion marker
    /// could not be written reports this as `true` and ``isComplete`` as `false`: the
    /// pen holds no remainder of it, and the read is incomplete because its own record
    /// says so. A transfer that stopped short reports both as `false`.
    public let reachedEndPacket: Bool

    /// Whether the last acknowledgement's delivery is not certain.
    ///
    /// It is `true` when the transfer stopped after a durable commit but without
    /// a confirmed acknowledgement, which leaves the pen's copy of that packet
    /// unknown.
    public let acknowledgementUncertain: Bool

    /// Why the read is not durably complete, or `nil` when it is.
    ///
    /// It names why the transfer stopped short, and also why a finished transfer's
    /// completion could not be recorded.
    public let reason: String?

    public init(
        batchID: UUID,
        committedPacketCount: Int,
        committedStrokeCount: Int,
        committedDotCount: Int,
        addedStrokeCount: Int,
        duplicateStrokeCount: Int,
        pages: [PageIdentity],
        isComplete: Bool,
        reachedEndPacket: Bool,
        acknowledgementUncertain: Bool,
        reason: String?
    ) {
        self.batchID = batchID
        self.committedPacketCount = committedPacketCount
        self.committedStrokeCount = committedStrokeCount
        self.committedDotCount = committedDotCount
        self.addedStrokeCount = addedStrokeCount
        self.duplicateStrokeCount = duplicateStrokeCount
        self.pages = pages
        self.isComplete = isComplete
        self.reachedEndPacket = reachedEndPacket
        self.acknowledgementUncertain = acknowledgementUncertain
        self.reason = reason
    }

    /// Whether the read is not durably complete.
    ///
    /// It is `true` both for a transfer that stopped short and for one that reached its
    /// end packet whose completion could not be recorded; ``reachedEndPacket`` tells the
    /// two apart.
    public var isPartial: Bool { !isComplete }
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

    /// What a deleting read durably committed, or `nil` for an ordinary read.
    ///
    /// A partial deleting transfer still returns a result, so the caller can
    /// report the durable prefix and offer a fresh read instead of losing it.
    public let deletingTransfer: PenDeletingTransferReport?

    /// Why a requested deleting read took the ordinary non-destructive path, or
    /// `nil` when no deleting read was requested or one ran.
    ///
    /// The connected pen's identity is only known after the handshake, so a pen
    /// whose model, firmware, protocol, or response shape the transfer evidence
    /// does not cover closes the deleting route at that point. The read then
    /// continues non-destructively and this names the blocker, so the caller can
    /// report it instead of the whole read failing.
    public let deletingReadRefusal: String?

    /// Creates a session result.
    public init(
        version: ProtocolVersion,
        versionInfo: PenVersionInfo,
        penState: PenState?,
        notes: [PenNoteTransfer],
        strokes: [Stroke],
        deletingTransfer: PenDeletingTransferReport? = nil,
        deletingReadRefusal: String? = nil
    ) {
        self.version = version
        self.versionInfo = versionInfo
        self.penState = penState
        self.notes = notes
        self.strokes = strokes
        self.deletingTransfer = deletingTransfer
        self.deletingReadRefusal = deletingReadRefusal
    }

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
/// is incremental; the 2026-10-19 experiment found neither incremental, and
/// `nextAndReserve` is the option that experiment established for the read path.
/// The SDK's deleting value, `0x01`, was measured against the pen on 2026-10-21
/// (`docs/protocol-a1.md`, "Deleting transfer option, 2026-10-21"); it is not
/// reachable from ``OfflineReadTransferOption``.
///
/// Deleting is authorized per route, and each route has its own record. The session
/// sends no `0x25` or `0x27` command: the evidence table gates both behind the command
/// deletion evidence, whose recorded deletion-scope verdict is `unsafe`. The deleting
/// transfer is the route it may take, and only with a ``PenDeletingReadAuthorization``:
/// it removes a packet during the read, after the durable commit that precedes that
/// packet's acknowledgement, so the removal is bounded by what the library already
/// holds. That is a different order from the command route, which is requested after a
/// durable import and published exports; see ``PenCleanupPolicy``.
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
    private let deletingRead: PenDeletingReadIntent?
    private let packetBarrier: (any PenDeletingPacketBarrier)?
    private let onDeletingPacketCommitted: (@Sendable (UInt16, Int) -> Void)?
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
    ///   - deletingRead: This sync's request for a deleting read, or `nil` for an
    ///     ordinary read. The session resolves it against the identity the
    ///     handshake reports and sends `0x23` option `0x01` only when the policy
    ///     authorizes it. An ordinary session has no route to the deleting option.
    ///   - packetBarrier: The durable storage each deleting packet is committed
    ///     through before its acknowledgement. It is required for a deleting read
    ///     and unused otherwise.
    ///   - onDeletingPacketCommitted: Called with a packet's identifier and stroke
    ///     count after its durable commit returned and before its `0xA4`. An
    ///     acceptance run uses it to record the ordering in a transcript.
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
        deletingRead: PenDeletingReadIntent? = nil,
        packetBarrier: (any PenDeletingPacketBarrier)? = nil,
        onDeletingPacketCommitted: (@Sendable (UInt16, Int) -> Void)? = nil,
        onStateChange: (@Sendable (PenSessionState) -> Void)? = nil
    ) {
        self.transport = transport
        self.versionPolicy = versionPolicy
        self.registry = registry
        self.timeouts = timeouts
        self.bootstrap = bootstrap
        self.transferOption = transferOption
        self.deletingRead = deletingRead
        self.packetBarrier = packetBarrier
        self.onDeletingPacketCommitted = onDeletingPacketCommitted
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

        // A deleting read is authorized here, after the handshake reported the
        // pen's identity and before any `0x23` is sent. The option is decided once,
        // before the first request, and never switched mid-transfer. A route that
        // is not authorized takes the ordinary non-destructive path and names the
        // blocker: the pen's identity is only known now, so failing the whole read
        // would leave a pen the transfer record does not cover unreadable.
        let deleting: DeletingContext?
        var deletingRefusal: String?
        if let intent = deletingRead {
            switch intent.authorization(for: PenDeletingTransferIdentity(info)) {
            case .success(let authorization):
                if let barrier = packetBarrier {
                    deleting = DeletingContext(authorization: authorization, barrier: barrier)
                } else {
                    deleting = nil
                    deletingRefusal = "no durable packet storage is available"
                }
            case .failure(let refusal):
                deleting = nil
                deletingRefusal = refusal.reason
            }
        } else {
            deleting = nil
        }

        let notes = try await discoverNotes(channel: channel)

        // An empty list is a completed sync with zero counts, not a failure:
        // there is simply nothing to read.
        guard !notes.isEmpty else {
            if let deleting {
                // A deleting read with nothing to read commits no packet and is
                // complete: the pen held nothing to remove.
                try await deleting.finish(batchID: nil, isComplete: true)
            }
            return PenSessionResult(
                version: version,
                versionInfo: info,
                penState: measuredState,
                notes: [],
                strokes: [],
                deletingTransfer: nil,
                deletingReadRefusal: deletingRefusal
            )
        }

        // The batch is opened before the first `0x23`, so every packet has a
        // durable batch to commit into.
        let batchID: UUID?
        if let deleting {
            batchID = try await deleting.barrier.beginDeletingRead(
                notes: notes.map {
                    PenDeletingReadNote(sectionOwnerID: $0.sectionOwnerId, noteID: $0.note)
                }
            )
        } else {
            batchID = nil
        }

        // Everything from here to the return is one attempt at the transfer, and the
        // batch exists for all of it. A read that ends without a durable packet
        // leaves through this catch, so the batch it opened is marked failed instead
        // of staying in progress for ever. The progress is declared out here because
        // that catch has to know whether any packet became durable.
        var progress = DeletingProgress()
        do {
            return try await readEveryNote(
                notes: notes,
                channel: channel,
                deleting: deleting,
                batchID: batchID,
                version: version,
                info: info,
                measuredState: measuredState,
                deletingRefusal: deletingRefusal,
                progress: &progress
            )
        } catch {
            try await failEmptyDeletingBatch(
                deleting,
                batchID: batchID,
                progress: progress,
                error: error
            )
            throw error
        }
    }

    /// Reads every discovered note and reports the read.
    ///
    /// The batch a deleting read opened exists for the whole of this call, so the
    /// caller wraps it: a throw from here is a read that ended with the batch it
    /// opened still in progress.
    private func readEveryNote(
        notes: [PenOfflineNote],
        channel: PenFrameChannel,
        deleting: DeletingContext?,
        batchID: UUID?,
        version: ProtocolVersion,
        info: PenVersionInfo,
        measuredState: PenState?,
        deletingRefusal: String?,
        progress: inout DeletingProgress
    ) async throws -> PenSessionResult {
        var transfers: [PenNoteTransfer] = []
        var strokes: [Stroke] = []
        var stopReason: String?
        var acknowledgementUncertain = false

        for note in notes {
            let outcome: NoteReadOutcome
            do {
                outcome = try await readNote(
                    note,
                    channel: channel,
                    deleting: deleting,
                    batchID: batchID,
                    progress: &progress
                )
            } catch {
                // Starting a note can fail on its own — a dropped link, a rejected
                // request, a malformed page list. Once a packet is durable that is
                // a partial stop, not an ordinary failure: the pen may already have
                // removed the acknowledged prefix, so it is reported rather than
                // lost to the error.
                guard let stop = deletingStop(deleting, error: error, progress: progress) else {
                    throw error
                }
                stopReason = stop.reason
                break
            }

            transfers.append(outcome.transfer)
            strokes.append(contentsOf: outcome.transfer.strokes)

            if let reason = outcome.partialReason {
                stopReason = reason
                acknowledgementUncertain = outcome.acknowledgementUncertain
                // A partial deleting transfer stops the read: a later note is not
                // started, so nothing beyond the acknowledged prefix is claimed.
                break
            }
        }

        var deletingReport: PenDeletingTransferReport?
        if let deleting, let batchID {
            // Whether the transfer itself reached every end packet: the transfer's own
            // fact, which stays true even when its completion cannot be recorded.
            let reachedEndPacket = stopReason == nil
            // Completion is a durable fact, so it is claimed only when the marker
            // was written. A storage failure leaves the batch `inProgress`, which is
            // what a restart will read, so the report says the read is not durably
            // complete rather than disagreeing with its own record.
            var durablyComplete = reachedEndPacket
            var completionFailure: String?
            do {
                try await deleting.finish(batchID: batchID, isComplete: reachedEndPacket)
            } catch {
                durablyComplete = false
                completionFailure = "the read's completion could not be recorded: \(error)"
            }
            deletingReport = PenDeletingTransferReport(
                batchID: batchID,
                committedPacketCount: progress.packetCount,
                committedStrokeCount: progress.strokeCount,
                committedDotCount: progress.dotCount,
                addedStrokeCount: progress.addedStrokeCount,
                duplicateStrokeCount: progress.duplicateStrokeCount,
                pages: progress.pages.sorted(by: PageIdentity.canonicalOrder),
                isComplete: durablyComplete,
                reachedEndPacket: reachedEndPacket,
                acknowledgementUncertain: acknowledgementUncertain,
                reason: stopReason ?? completionFailure
            )
        }

        return PenSessionResult(
            version: version,
            versionInfo: info,
            penState: measuredState,
            notes: transfers,
            strokes: strokes,
            deletingTransfer: deletingReport,
            deletingReadRefusal: deletingRefusal
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

    /// One note's outcome from `readNote`.
    private struct NoteReadOutcome {
        /// The note's transfer, carrying only durably committed strokes for a
        /// deleting read.
        let transfer: PenNoteTransfer

        /// Why the transfer stopped short, or `nil` when it completed.
        let partialReason: String?

        /// Whether the last acknowledgement's delivery is uncertain.
        let acknowledgementUncertain: Bool
    }

    /// The state one deleting transfer's packets are committed through.
    private struct DeletingContext {
        /// The authorization the policy granted for this sync.
        let authorization: PenDeletingReadAuthorization

        /// The durable storage each packet is committed to.
        let barrier: any PenDeletingPacketBarrier

        /// Marks the batch's completion, or does nothing when no batch was opened.
        func finish(batchID: UUID?, isComplete: Bool) async throws {
            guard let batchID else { return }
            try await barrier.finishDeletingRead(batchID: batchID, isComplete: isComplete)
        }
    }

    /// The durable progress a deleting read accumulates across notes.
    private struct DeletingProgress {
        /// Packets committed so far.
        var packetCount = 0

        /// Strokes committed so far.
        var strokeCount = 0

        /// Dots the commits added, so a replayed packet contributes none.
        var dotCount = 0

        /// Strokes the commits added rather than recognized as already stored.
        var addedStrokeCount = 0

        /// Reliable strokes the commits recognized as already stored.
        var duplicateStrokeCount = 0

        /// The distinct pages the committed strokes belong to.
        var pages = Set<PageIdentity>()
    }

    /// Reads one discovered note: `0x22`, `0x23`, `0xA3`, then the `0x24` stream.
    ///
    /// For a deleting read, each accepted packet is committed through the storage
    /// barrier before its `0xA4`, so the pen never removes data the library does
    /// not hold. A failure after at least one commit stops the note and reports
    /// the durable prefix instead of throwing, because the prefix exists and must
    /// be reported honestly.
    private func readNote(
        _ note: PenOfflineNote,
        channel: PenFrameChannel,
        deleting: DeletingContext?,
        batchID: UUID?,
        progress: inout DeletingProgress
    ) async throws -> NoteReadOutcome {
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

        let request: [UInt8]?
        if let deleting {
            request = PenRequest.offlineData(for: note, deletingRead: deleting.authorization)
        } else {
            request = PenRequest.offlineData(for: note, transferOption: transferOption)
        }
        try await send(request, command: .offlineDataRequest1)

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
            let frame: PenFrame?
            do {
                frame = try await awaitFrame(
                    channel: channel,
                    expecting: .offlineDataRequest2,
                    step: .dataPacket
                )
            } catch {
                // A deleting read that already committed a packet reports the
                // durable prefix rather than losing it to an error.
                if let stop = deletingStop(deleting, error: error, progress: progress) {
                    return stop.outcome(note: note, listedPages: listedPages, info: info, strokes: strokes, packets: packets)
                }
                throw error
            }

            guard let frame else {
                if let stop = deletingStop(
                    deleting,
                    error: PenSessionError.incompleteTransfer(
                        assembledPacketCount: assembler.assembledPacketCount
                    ),
                    progress: progress
                ) {
                    return stop.outcome(note: note, listedPages: listedPages, info: info, strokes: strokes, packets: packets)
                }
                // A normal stream finish before an end-position packet is an
                // incomplete transfer, never a completed result.
                throw PenSessionError.incompleteTransfer(
                    assembledPacketCount: assembler.assembledPacketCount
                )
            }

            let packetProgress: OfflineTransferProgress
            switch assembler.ingest(payload: frame.payload, penClockIsTrusted: penClockIsTrusted) {
            case .packet(let accepted):
                packetProgress = accepted
            case .unsupported(let reason):
                if let stop = deletingStop(
                    deleting,
                    error: PenSessionError.unsupportedTransfer(reason: reason),
                    progress: progress
                ) {
                    return stop.outcome(note: note, listedPages: listedPages, info: info, strokes: strokes, packets: packets)
                }
                throw PenSessionError.unsupportedTransfer(reason: reason)
            case .error(let error):
                if let stop = deletingStop(deleting, error: error, progress: progress) {
                    return stop.outcome(note: note, listedPages: listedPages, info: info, strokes: strokes, packets: packets)
                }
                throw PenSessionError.protocolFailure(error)
            }

            // The durable commit barrier: for a deleting read the packet's
            // strokes and progress are committed before anything is acknowledged,
            // so a failure here sends no acknowledgement for this packet.
            if let deleting, let batchID {
                let commit: PenDeletingPacketCommitResult
                do {
                    commit = try await deleting.barrier.commitDeletingPacket(
                        PenDeletingPacket(
                            batchID: batchID,
                            sectionOwnerID: note.sectionOwnerId,
                            noteID: note.note,
                            packetID: packetProgress.header.packetID,
                            strokes: packetProgress.records.map(\.stroke),
                            isEndPacket: packetProgress.isTransferComplete
                        )
                    )
                } catch {
                    // A packet that could not be committed is never acknowledged.
                    // Once an earlier packet is durable the read reports that
                    // prefix; the first packet's failure has no prefix to report,
                    // so it is thrown rather than forced through a partial stop.
                    let failure = PenSessionError.deletingPacketCommitFailed(
                        reason: String(describing: error)
                    )
                    guard let stop = deletingStop(deleting, error: failure, progress: progress) else {
                        throw failure
                    }
                    return stop.outcome(
                        note: note,
                        listedPages: listedPages,
                        info: info,
                        strokes: strokes,
                        packets: packets
                    )
                }

                progress.packetCount = commit.committedPacketCount
                progress.strokeCount = commit.committedStrokeCount
                progress.dotCount = commit.committedDotCount
                progress.addedStrokeCount += commit.addedStrokeCount
                progress.duplicateStrokeCount += commit.duplicateStrokeCount
                progress.pages.formUnion(packetProgress.records.map(\.stroke.page))

                // The commit returned, so this packet is durable and the
                // acknowledgement below has not been sent yet. A transcript
                // recorded here proves that ordering without the pen.
                onDeletingPacketCommitted?(packetProgress.header.packetID, packetProgress.records.count)
            }

            packets.append(packetProgress)
            strokes.append(contentsOf: packetProgress.records.map(\.stroke))

            // One acknowledgement per packet: Continue while the transfer runs,
            // Stop for the end packet. The pen sends the next packet only after
            // the acknowledgement, so this must happen before the next read.
            let operation: PenTransferAcknowledgement = packetProgress.isTransferComplete ? .stop : .next
            do {
                try await send(
                    PenRequest.acknowledgement(
                        packetID: packetProgress.header.packetID,
                        operation: operation
                    ),
                    command: .responseOfflineData
                )
            } catch {
                // The packet is durable but its acknowledgement may not have
                // reached the pen, so the pen's copy is uncertain.
                if let stop = deletingStop(deleting, error: error, progress: progress) {
                    var outcome = stop.outcome(
                        note: note,
                        listedPages: listedPages,
                        info: info,
                        strokes: strokes,
                        packets: packets
                    )
                    outcome = NoteReadOutcome(
                        transfer: outcome.transfer,
                        partialReason: outcome.partialReason,
                        acknowledgementUncertain: true
                    )
                    return outcome
                }
                throw error
            }

            if packetProgress.isTransferComplete {
                break
            }
        }

        guard assembler.isComplete else {
            if let stop = deletingStop(
                deleting,
                error: PenSessionError.incompleteTransfer(
                    assembledPacketCount: assembler.assembledPacketCount
                ),
                progress: progress
            ) {
                return stop.outcome(note: note, listedPages: listedPages, info: info, strokes: strokes, packets: packets)
            }
            throw PenSessionError.incompleteTransfer(
                assembledPacketCount: assembler.assembledPacketCount
            )
        }

        // Counts come from the accepted packets, never from the `0xA3` summary.
        return NoteReadOutcome(
            transfer: PenNoteTransfer(
                note: note,
                listedPages: listedPages,
                pageIdentities: Self.distinctPages(in: strokes),
                info: info,
                strokes: strokes,
                packetCount: packets.count
            ),
            partialReason: nil,
            acknowledgementUncertain: false
        )
    }

    /// Whether a deleting read should report a partial stop rather than throw.
    ///
    /// A partial stop is possible only for a deleting read that already committed
    /// at least one packet: before that, nothing is durable and the failure is
    /// ordinary. A cancellation is included, because a committed prefix still
    /// exists and the pen may already have removed it.
    private func deletingStop(
        _ deleting: DeletingContext?,
        error: any Error,
        progress: DeletingProgress
    ) -> DeletingStop? {
        guard deleting != nil, progress.packetCount > 0 else { return nil }
        return DeletingStop(reason: Self.describe(error))
    }

    /// Marks the batch a deleting read opened failed when the read ended before its
    /// first durable packet.
    ///
    /// The batch is opened before the first `0x23`, so a read that ends before any
    /// packet commits would otherwise leave a `committed` batch claiming an
    /// in-progress transfer for ever: it can never publish, because publication
    /// needs a durable packet, and it holds no page, so it blocks nothing. Marking
    /// it keeps the row visible and unpublishable instead of removing it, because
    /// the journal and a later diagnosis need to see that the read was attempted.
    ///
    /// Only a read with no durable packet is marked: a read that stopped with a
    /// prefix reports that prefix, which is what its own record already says. A
    /// marking failure is reported together with the read's own reason rather than
    /// instead of it, so a second storage fault cannot hide the first.
    private func failEmptyDeletingBatch(
        _ deleting: DeletingContext?,
        batchID: UUID?,
        progress: DeletingProgress,
        error: any Error
    ) async throws {
        guard let deleting, let batchID, progress.packetCount == 0 else { return }
        do {
            try await deleting.barrier.failDeletingRead(batchID: batchID)
        } catch let markingFailure {
            throw PenSessionError.deletingReadNotRecorded(
                reason: "\(Self.describe(error)); the batch's failure could not be recorded:"
                    + " \(markingFailure)"
            )
        }
    }

    /// A short description of why a transfer stopped.
    private static func describe(_ error: any Error) -> String {
        switch error {
        case let sessionError as PenSessionError:
            return sessionError.message
        case is CancellationError:
            return PenSessionError.cancelled.message
        default:
            return String(describing: error)
        }
    }

    /// A partial stop of a deleting transfer.
    private struct DeletingStop {
        /// Why the transfer stopped.
        let reason: String

        /// Builds the note outcome for the durable prefix.
        func outcome(
            note: PenOfflineNote,
            listedPages: [UInt32],
            info: PenOfflineDataInfo,
            strokes: [Stroke],
            packets: [OfflineTransferProgress]
        ) -> NoteReadOutcome {
            NoteReadOutcome(
                transfer: PenNoteTransfer(
                    note: note,
                    listedPages: listedPages,
                    pageIdentities: PenSession.distinctPages(in: strokes),
                    info: info,
                    strokes: strokes,
                    packetCount: packets.count
                ),
                partialReason: reason,
                acknowledgementUncertain: false
            )
        }
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

extension PenDeletingTransferIdentity {
    /// The identity a connected pen reported.
    ///
    /// The compression field is the pen's advertised capability. The read always
    /// requests an uncompressed transfer, and a compressed `0x24` packet is
    /// refused by the transfer assembler before it could be acknowledged, so a
    /// pen that advertises compression never matches the uncompressed trace.
    public init(_ info: PenVersionInfo) {
        self.init(
            deviceName: info.deviceName,
            firmwareVersion: info.firmwareVersion,
            protocolVersion: info.protocolVersionText,
            isCompressed: info.supportsCompressedTransfer
        )
    }
}
