import NeoCore

/// How well a command's wire behavior is established.
public enum CommandEvidenceLevel: String, Hashable, Sendable, Codable, CaseIterable {
    /// The wire behavior is documented by an official Neo SDK and covered by a
    /// fixture test.
    case officialSDK

    /// The wire behavior was validated against a physical A1 and covered by a
    /// fixture test.
    case physicalDevice

    /// The identifier is known but the wire behavior is not validated. The
    /// mapping may be inspected in tests and must never be used in production.
    case provisional

    /// No evidence exists.
    case none

    /// Whether the evidence authorizes production use.
    public var authorizesProduction: Bool {
        switch self {
        case .officialSDK, .physicalDevice:
            return true
        case .provisional, .none:
            return false
        }
    }
}

/// The evidence behind one command.
public struct CommandEvidence: Hashable, Sendable {
    /// The command the evidence covers.
    public let command: PenCommand

    /// The evidence level.
    public let level: CommandEvidenceLevel

    /// Where the evidence comes from, such as an SDK source path or an A1
    /// capture record.
    public let source: String

    public init(command: PenCommand, level: CommandEvidenceLevel, source: String) {
        self.command = command
        self.level = level
        self.source = source
    }
}

/// What the decoder may do with a command.
public enum CommandAuthorization: Hashable, Sendable {
    /// The command may be sent and may produce completed domain strokes.
    case production

    /// The mapping may be inspected in tests only. It must not authorize a
    /// production request and must not emit a completed stroke.
    case inspectionOnly(reason: String)

    /// The command is wire-documented but gated behind an evidence gate.
    ///
    /// The gate is data rather than a constant: the deletion commands become
    /// `production` only when the recorded ``PenDeletionEvidence`` proves their
    /// payload framing, deletion scope, response meaning, and interrupted-transfer
    /// retention safe. While the gate is closed the command may not be sent, and
    /// the reason names the conditions that are not yet established.
    case gated(reason: String)

    /// No evidence exists for the command.
    case unsupported(reason: String)

    /// Whether the command may be sent to a pen.
    public var allowsProductionRequest: Bool {
        self == .production
    }

    /// Whether the command may produce a completed domain stroke.
    public var allowsCompletedStroke: Bool {
        self == .production
    }

    /// Why an evidence gate refuses the command, or `nil` when none does.
    public var gateReason: String? {
        if case .gated(let reason) = self { return reason }
        return nil
    }
}

/// The evidence table the decoder consults.
public struct CommandEvidenceRegistry: Hashable, Sendable {
    /// The registry built from the Neo iOS SDK 3.0 command table.
    ///
    /// Commands whose payload layout the SDK documents and whose behavior a
    /// fixture test covers are `officialSDK`. The SoundPen and log commands are
    /// `provisional`: their identifiers are known, but their wire behavior is not
    /// validated for the A1, so they stay inspection-only. The offline deletion
    /// commands are `gated`: their identifiers are documented, and the deletion
    /// evidence gate in ``deletionEvidence`` decides whether they may be sent.
    public static let neoSDK3 = CommandEvidenceRegistry(entries: [
        .versionInfo: CommandEvidence(
            command: .versionInfo,
            level: .officialSDK,
            source: "Neo iOS SDK 3.0 NISDK3/Classes/Model/RequestStruct.swift (REQ.VersionInfo)"
        ),
        .responseVersionInfo: CommandEvidence(
            command: .responseVersionInfo,
            level: .officialSDK,
            source: "Neo iOS SDK 3.0 NISDK3/Classes/Model/ResponseStruct.swift (PenVersionInfo)"
        ),
        .penState: CommandEvidence(
            command: .penState,
            level: .physicalDevice,
            source: "2026-10-19 physical NWP-F151 0x04 request and 0x84 response"
        ),
        .responsePenState: CommandEvidence(
            command: .responsePenState,
            level: .physicalDevice,
            source: "2026-10-19 physical NWP-F151 64-byte pen-state payload and Neo iOS SDK 3.0"
        ),
        .eventPenUpDown: CommandEvidence(
            command: .eventPenUpDown,
            level: .officialSDK,
            source: "Neo iOS SDK 3.0 NISDK3/Classes/Model/ResponseStruct.swift (PenUpDown)"
        ),
        .eventNewPenDown: CommandEvidence(
            command: .eventNewPenDown,
            level: .officialSDK,
            source: "Neo iOS SDK 3.0 NISDK3/Classes/Model/ResponseStruct.swift (PenDown)"
        ),
        .eventNewPenUp: CommandEvidence(
            command: .eventNewPenUp,
            level: .officialSDK,
            source: "Neo iOS SDK 3.0 NISDK3/Classes/Model/ResponseStruct.swift (PenUp)"
        ),
        .eventPenNewId: CommandEvidence(
            command: .eventPenNewId,
            level: .officialSDK,
            source: "Neo iOS SDK 3.0 NISDK3/Classes/Model/ResponseStruct.swift (PageInfo, 0x64)"
        ),
        .eventNewPenNewId: CommandEvidence(
            command: .eventNewPenNewId,
            level: .officialSDK,
            source: "Neo iOS SDK 3.0 NISDK3/Classes/Model/ResponseStruct.swift (PageInfo, 0x6B)"
        ),
        .eventPenDotCode: CommandEvidence(
            command: .eventPenDotCode,
            level: .officialSDK,
            source: "Neo iOS SDK 3.0 NISDK3/Classes/Model/ResponseStruct.swift (Dot, 0x65)"
        ),
        .eventNewPenDot: CommandEvidence(
            command: .eventNewPenDot,
            level: .officialSDK,
            source: "Neo iOS SDK 3.0 NISDK3/Classes/Model/ResponseStruct.swift (Dot, 0x6C)"
        ),
        .responseOfflineData: CommandEvidence(
            command: .responseOfflineData,
            level: .officialSDK,
            source: "Neo iOS SDK 3.0 NISDK3/Classes/Model/ResponseStruct.swift (OffLineData, OffLineStroke)"
        ),
        .responseOfflineDataInfo: CommandEvidence(
            command: .responseOfflineDataInfo,
            level: .officialSDK,
            source: "Neo iOS SDK 3.0 NISDK3/Classes/Model/ResponseStruct.swift (offline data info)"
        ),
        .offlineNoteListRequest: CommandEvidence(
            command: .offlineNoteListRequest,
            level: .officialSDK,
            source: "Neo iOS SDK 3.0 NISDK3/Classes/Model/RequestStruct.swift (offline note list)"
        ),
        .offlinePageListRequest: CommandEvidence(
            command: .offlinePageListRequest,
            level: .officialSDK,
            source: "Neo iOS SDK 3.0 NISDK3/Classes/Model/RequestStruct.swift (offline page list)"
        ),
        .offlineDataRequest1: CommandEvidence(
            command: .offlineDataRequest1,
            level: .officialSDK,
            source: "Neo iOS SDK 3.0 NISDK3/Classes/Model/RequestStruct.swift (offline data request)"
        ),
        .offlineDataRequest2: CommandEvidence(
            command: .offlineDataRequest2,
            level: .officialSDK,
            source: "Neo iOS SDK 3.0 NISDK3/Classes/Model/RequestStruct.swift (offline data request)"
        ),
        .deleteOfflineNoteRequest: CommandEvidence(
            command: .deleteOfflineNoteRequest,
            level: .officialSDK,
            source: "Neo iOS SDK 3.0 NISDK3/Classes/Model/CMD.swift (REQ_DEL_OFFLINE_DATA_NOTE)"
        ),
        .deleteOfflinePageRequest: CommandEvidence(
            command: .deleteOfflinePageRequest,
            level: .officialSDK,
            source: "Neo iOS SDK 3.0 NISDK3/Classes/Model/CMD.swift (REQ_DEL_OFFLINE_DATA_PAGE)"
        ),
        .soundResponsePds: CommandEvidence(
            command: .soundResponsePds,
            level: .provisional,
            source: "Neo iOS SDK 3.0 CMD.swift lists the identifier; A1 payload behavior is not validated"
        ),
        .soundRequestLogInfo: CommandEvidence(
            command: .soundRequestLogInfo,
            level: .provisional,
            source: "Neo iOS SDK 3.0 CMD.swift lists the identifier; A1 payload behavior is not validated"
        ),
        .soundRequestLogData: CommandEvidence(
            command: .soundRequestLogData,
            level: .provisional,
            source: "Neo iOS SDK 3.0 CMD.swift lists the identifier; A1 payload behavior is not validated"
        ),
        .soundResponseOid: CommandEvidence(
            command: .soundResponseOid,
            level: .provisional,
            source: "Neo iOS SDK 3.0 CMD.swift lists the identifier; A1 payload behavior is not validated"
        ),
        .soundResponseStatus: CommandEvidence(
            command: .soundResponseStatus,
            level: .provisional,
            source: "Neo iOS SDK 3.0 CMD.swift lists the identifier; A1 payload behavior is not validated"
        ),
        .soundResponseLogInfo: CommandEvidence(
            command: .soundResponseLogInfo,
            level: .provisional,
            source: "Neo iOS SDK 3.0 CMD.swift lists the identifier; A1 payload behavior is not validated"
        ),
        .soundResponseLogData: CommandEvidence(
            command: .soundResponseLogData,
            level: .provisional,
            source: "Neo iOS SDK 3.0 CMD.swift lists the identifier; A1 payload behavior is not validated"
        )
    ])

    private let entries: [PenCommand: CommandEvidence]

    /// The evidence gate behind the offline deletion commands.
    ///
    /// The gate is data, so opening it is a change to the recorded verdicts rather
    /// than an edit to a boolean. The default is the closed gate: no physical A1
    /// deletion trace has established a payload framing, a scope, a response
    /// meaning, or interrupted-transfer retention for either command.
    public let deletionEvidence: PenDeletionEvidence

    /// Creates a registry.
    ///
    /// - Parameters:
    ///   - entries: The evidence for each command identifier.
    ///   - deletionEvidence: The gate the deletion commands consult.
    public init(
        entries: [PenCommand: CommandEvidence],
        deletionEvidence: PenDeletionEvidence = .unestablished
    ) {
        self.entries = entries
        self.deletionEvidence = deletionEvidence
    }

    /// The evidence for a command.
    ///
    /// - Returns: The recorded evidence, or `none` when the registry has none.
    public func evidence(for command: PenCommand) -> CommandEvidence {
        entries[command] ?? CommandEvidence(command: command, level: .none, source: "no recorded evidence")
    }

    /// What the decoder may do with a command.
    ///
    /// The offline deletion commands are decided by ``deletionEvidence`` rather
    /// than by a constant, so a command becomes sendable only when a physical trace
    /// proves the whole gate for that command.
    public func authorization(for command: PenCommand) -> CommandAuthorization {
        if let target = command.deletionTarget {
            guard deletionEvidence.proves(target) else {
                return .gated(reason: deletionEvidence.blockingReason(for: target))
            }
            return .production
        }

        let evidence = evidence(for: command)
        switch evidence.level {
        case .officialSDK, .physicalDevice:
            return .production
        case .provisional:
            return .inspectionOnly(reason: evidence.source)
        case .none:
            return .unsupported(reason: evidence.source)
        }
    }

    /// Whether the command may be sent to a pen.
    public func maySendProductionRequest(_ command: PenCommand) -> Bool {
        authorization(for: command).allowsProductionRequest
    }

    /// Whether the command may produce a completed domain stroke.
    public func mayEmitCompletedStroke(_ command: PenCommand) -> Bool {
        authorization(for: command).allowsCompletedStroke
    }
}

/// How a command's frame body is laid out on the wire.
///
/// The body is `command, optional error code, length, payload`. Which layout a
/// command uses is a property of the identifier alone, not of the direction it
/// travels in: the host's `0xA4` acknowledgement carries an error code like any
/// other response, while the pen's `0x24` data frames and the host's requests do
/// not.
public enum PenFrameKind: Hashable, Sendable, Codable, CaseIterable {
    /// The length field follows the command directly.
    ///
    /// This covers pen events and notifications, host requests, and the
    /// firmware and offline data streams the pen sends.
    case event

    /// An error code sits between the command and the length field.
    case response
}

extension PenCommand {
    /// The framing this identifier uses, or `nil` when the evidence does not
    /// classify it.
    ///
    /// Source: Neo iOS SDK 3.0 `PenCommParser.parsePenDataPacket`. It reads the
    /// length from `data[1..2]` for every identifier it parses as an event and
    /// from `data[2..3]` for every identifier it parses as a response, which is
    /// how a response's error code is skipped. The split it makes within the
    /// `SOUND_RES_*` family is why this is a table rather than a rule: `0x73`,
    /// `0x76`, and `0x77` are parsed without an error code, while `0xF4` and
    /// `0xF5` are parsed with one.
    ///
    /// The SDK parses only pen-to-host frames, so its case list cannot classify
    /// a host-to-pen response or the requests. Two groups are settled from other
    /// evidence:
    ///
    /// - `0xA4`, the host's offline data acknowledgement, is framed with an error
    ///   code and the pen accepted all 604 of them, so it is a response even
    ///   though the SDK never parses one.
    /// - `0x01`, `0x21`, `0x22`, and `0x23` are requests the physical A1
    ///   accepted without an error code, so they are events for framing
    ///   purposes.
    ///
    /// Every other identifier stays unclassified. The decoder rejects such a
    /// frame rather than guessing where its length field starts, so an
    /// unvalidated command cannot be mis-parsed as data.
    public var frameKind: PenFrameKind? {
        switch self {
        // Responses: the SDK parses each of these with an error code.
        case .responseVersionInfo,
             .responseComparePassword,
             .responseChangePassword,
             .responsePenState,
             .responseSetPenState,
             .responseSystemChange,
             .responseSystemInfo,
             .responseSetNoteList,
             .responseOfflineNoteList,
             .responseOfflinePageList,
             .responseOfflineDataInfo,
             .responseDeleteOfflineNote,
             .responseDeleteOfflinePage,
             .responseFirmwareFile1,
             .responseFirmwareFile2,
             .responseProfile,
             .soundResponseLogInfo,
             .soundResponseLogData:
            return .response

        // The host's offline data acknowledgement. Not in the SDK's case list,
        // because the SDK only parses what the pen sends; settled by the capture.
        case .responseOfflineData:
            return .response

        // Events and the pen-to-host streams, parsed by the SDK without an error
        // code.
        case .eventBatteryAlarm,
             .eventPowerOff,
             .eventPenUpDown,
             .eventPenNewId,
             .eventPenDotCode,
             .eventPenDotCode2,
             .eventPenDotCode3,
             .eventDotError,
             .eventNewPenDown,
             .eventNewPenUp,
             .eventNewPenNewId,
             .eventNewPenDot,
             .eventNewDotError,
             .eventHoverDot,
             .offlineDataRequest2,
             .firmwareFileRequest2,
             .soundResponsePds,
             .soundResponseOid,
             .soundResponseStatus:
            return .event

        // Requests the capture exercised, accepted without an error code.
        case .versionInfo,
             .penState,
             .offlineNoteListRequest,
             .offlinePageListRequest,
             .offlineDataRequest1:
            return .event

        // No framing evidence. Reject rather than guess. The two deletion
        // requests are here as well: their payload framing is one of the
        // conditions the deletion evidence gate must establish, so until a
        // physical trace settles it the decoder must not guess where their length
        // field starts.
        case .comparePassword,
             .changePassword,
             .setPenState,
             .systemChange,
             .systemInfo,
             .setNoteList,
             .deleteOfflineNoteRequest,
             .deleteOfflinePageRequest,
             .firmwareFileRequest1,
             .profileRequest,
             .soundRequestLogInfo,
             .soundRequestLogData:
            return nil
        }
    }

    /// The deletion target a command scopes to, or `nil` for every other command.
    ///
    /// The mapping is a property of the identifier, so the evidence gate can name
    /// the command it proves without the storage layer having to know a wire
    /// value.
    public var deletionTarget: PenDeletionTarget? {
        switch self {
        case .deleteOfflineNoteRequest: return .note
        case .deleteOfflinePageRequest: return .page
        default: return nil
        }
    }
}
