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

    /// The command is wire-documented but gated behind a later milestone.
    case blocked(reason: String)

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
}

/// The evidence table the decoder consults.
public struct CommandEvidenceRegistry: Hashable, Sendable {
    /// The registry built from the Neo iOS SDK 3.0 command table.
    ///
    /// Commands whose payload layout the SDK documents and whose behavior a
    /// fixture test covers are `officialSDK`. The SoundPen and log commands are
    /// `provisional`: their identifiers are known, but their wire behavior is not
    /// validated for the A1, so they stay inspection-only. Offline deletion is
    /// `blocked` until physical A1 acceptance passes.
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

    public init(entries: [PenCommand: CommandEvidence]) {
        self.entries = entries
    }

    /// The evidence for a command.
    ///
    /// - Returns: The recorded evidence, or `none` when the registry has none.
    public func evidence(for command: PenCommand) -> CommandEvidence {
        entries[command] ?? CommandEvidence(command: command, level: .none, source: "no recorded evidence")
    }

    /// What the decoder may do with a command.
    public func authorization(for command: PenCommand) -> CommandAuthorization {
        switch command {
        case .deleteOfflineNoteRequest, .deleteOfflinePageRequest:
            return .blocked(
                reason: "offline deletion stays disabled until physical A1 acceptance passes"
            )
        default:
            break
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
