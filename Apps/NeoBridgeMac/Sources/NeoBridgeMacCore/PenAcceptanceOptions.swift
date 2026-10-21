import Foundation
import NeoCore
import NeoProtocol

/// The options a headless acceptance run takes from its environment.
///
/// `Tests/Hardware/README.md` drives the physical A1 with the app binary rather
/// than the menu bar, because a menu-bar app cannot be scripted without an
/// accessibility grant. A run is selected by ``traceEnvironmentKey``: with the key
/// set the process performs one read attempt and writes a transcript instead of
/// showing the interface.
///
/// The remaining keys vary the attempt so one binary can run the whole checklist,
/// including the experiments that have to read the pen differently from the way
/// the app does by default:
///
/// | Key | Effect | Default |
/// | --- | --- | --- |
/// | ``traceEnvironmentKey`` | Selects the headless run and names the transcript. | unset; the app runs normally |
/// | ``exportDirectoryEnvironmentKey`` | Commits the read to the library and publishes files there. | unset; the read stores without exporting |
/// | ``transferOptionEnvironmentKey`` | The `0x23` transfer option the read sends. | `nextAndReserve` |
/// | ``cleanupModeEnvironmentKey`` | The cleanup intent the run starts with. | the policy default, cleanup |
/// | ``confirmCleanupEnvironmentKey`` | Whether the run confirms cleanup for its sync, which is what authorizes a deleting transfer. | unset; not confirmed, so the read is non-destructive |
/// | ``abortAtPacketEnvironmentKey`` | Drops the link when that `0x24` packet arrives. | unset; the transfer runs to its end |
///
/// A value that cannot be understood is refused rather than ignored, so a run that
/// was meant to test one option cannot silently test another.
///
/// The intent and the confirmation are separate keys on purpose. A deleting transfer
/// needs both, because the confirmation is the user's act and not a consequence of
/// intending cleanup: a run that sets only ``cleanupModeEnvironmentKey`` takes the
/// ordinary non-destructive read, exactly as a person who has not confirmed it does.
public struct PenAcceptanceOptions: Hashable, Sendable {
    /// The environment variable that selects the headless run and names its
    /// transcript.
    public static let traceEnvironmentKey = "NEOBRIDGE_ACCEPTANCE_TRACE"

    /// The environment variable that names the export folder.
    ///
    /// A headless run cannot open a folder picker, so the folder comes from the
    /// environment. The interface stores a security-scoped bookmark instead.
    public static let exportDirectoryEnvironmentKey = "NEOBRIDGE_EXPORT_DIRECTORY"

    /// The environment variable that chooses the `0x23` transfer option.
    public static let transferOptionEnvironmentKey = "NEOBRIDGE_ACCEPTANCE_TRANSFER_OPTION"

    /// The environment variable that chooses the cleanup intent for the run.
    public static let cleanupModeEnvironmentKey = "NEOBRIDGE_ACCEPTANCE_CLEANUP"

    /// The environment variable that confirms cleanup for the run's sync.
    ///
    /// It is what authorizes a deleting transfer, and it is a separate key from the
    /// intent so that asking for the intent cannot silently authorize removal.
    public static let confirmCleanupEnvironmentKey = "NEOBRIDGE_ACCEPTANCE_CONFIRM_CLEANUP"

    /// The environment variable that interrupts the transfer.
    public static let abortAtPacketEnvironmentKey = "NEOBRIDGE_ACCEPTANCE_ABORT_AT_PACKET"

    /// Where to write the transcript.
    public let traceURL: URL

    /// The export folder, or `nil` to store without exporting.
    public let exportDirectory: String?

    /// The `0x23` transfer option the read sends.
    public let transferOption: OfflineReadTransferOption

    /// The cleanup intent the run starts with.
    public let cleanupMode: PenCleanupMode

    /// Whether the run confirms cleanup for its sync.
    public let confirmCleanup: Bool

    /// The arriving `0x24` packet that drops the link, or `nil` for a full
    /// transfer.
    public let abortAtPacket: Int?

    /// Why an environment value could not be understood.
    public enum ParseError: Error, Hashable, Sendable {
        /// The transfer option is not one this build sends.
        case unknownTransferOption(String)

        /// The cleanup mode is not one this build has.
        case unknownCleanupMode(String)

        /// The confirmation flag is not a yes or a no.
        case invalidConfirmCleanup(String)

        /// The run confirmed cleanup while asking to keep the pen's strokes.
        case confirmationWithoutIntent

        /// The packet number is not a positive whole number.
        case invalidAbortAtPacket(String)

        /// A one-line message for the process to print before it exits.
        public var message: String {
            switch self {
            case .unknownTransferOption(let value):
                let accepted = OfflineReadTransferOption.allCases
                    .map(\.argumentName)
                    .joined(separator: ", ")
                return "\(PenAcceptanceOptions.transferOptionEnvironmentKey)=\(value)"
                    + " is not a transfer option; use one of \(accepted)"
            case .unknownCleanupMode(let value):
                let accepted = PenCleanupMode.acceptedArguments.joined(separator: ", ")
                return "\(PenAcceptanceOptions.cleanupModeEnvironmentKey)=\(value)"
                    + " is not a cleanup mode; use one of \(accepted)"
            case .invalidConfirmCleanup(let value):
                let accepted = PenAcceptanceOptions.confirmCleanupArguments
                    .map(\.spelling)
                    .joined(separator: ", ")
                return "\(PenAcceptanceOptions.confirmCleanupEnvironmentKey)=\(value)"
                    + " is not a yes or a no; use one of \(accepted)"
            case .confirmationWithoutIntent:
                return "\(PenAcceptanceOptions.confirmCleanupEnvironmentKey) confirms cleanup,"
                    + " but \(PenAcceptanceOptions.cleanupModeEnvironmentKey) asks to keep the pen's"
                    + " strokes, so nothing would be confirmed; ask for cleanup or drop the"
                    + " confirmation"
            case .invalidAbortAtPacket(let value):
                return "\(PenAcceptanceOptions.abortAtPacketEnvironmentKey)=\(value)"
                    + " is not a packet number; use a positive whole number"
            }
        }
    }

    /// Creates the options for a run.
    ///
    /// - Parameters:
    ///   - traceURL: Where to write the transcript.
    ///   - exportDirectory: The export folder, or `nil` to store without
    ///     exporting.
    ///   - transferOption: The `0x23` transfer option the read sends.
    ///   - cleanupMode: The cleanup intent the run starts with.
    ///   - confirmCleanup: Whether the run confirms cleanup for its sync.
    ///   - abortAtPacket: The arriving `0x24` packet that drops the link, or `nil`
    ///     for a full transfer.
    public init(
        traceURL: URL,
        exportDirectory: String? = nil,
        transferOption: OfflineReadTransferOption = .nextAndReserve,
        cleanupMode: PenCleanupMode = .deleteAfterAcknowledge,
        confirmCleanup: Bool = false,
        abortAtPacket: Int? = nil
    ) {
        self.traceURL = traceURL
        self.exportDirectory = exportDirectory
        self.transferOption = transferOption
        self.cleanupMode = cleanupMode
        self.confirmCleanup = confirmCleanup
        self.abortAtPacket = abortAtPacket
    }

    /// Reads the options for this process.
    ///
    /// The other keys are read only once a transcript is named, because the trace
    /// key is what selects this mode. A stray acceptance key in a developer's shell
    /// therefore cannot change how the interface behaves, and a mistake in one of the
    /// other keys is only refused for a run that was going to be headless anyway.
    ///
    /// - Parameter environment: The process environment, or a test's stand-in.
    /// - Returns: The options, or `nil` when no transcript was named, which is a
    ///   normal interactive launch.
    /// - Throws: ``ParseError`` when a value present in the environment is not
    ///   understood.
    public init?(environment: [String: String]) throws {
        guard let tracePath = Self.value(Self.traceEnvironmentKey, in: environment) else {
            return nil
        }

        let transferOption: OfflineReadTransferOption
        if let text = Self.value(Self.transferOptionEnvironmentKey, in: environment) {
            guard let option = OfflineReadTransferOption(argument: text) else {
                throw ParseError.unknownTransferOption(text)
            }
            transferOption = option
        } else {
            transferOption = .nextAndReserve
        }

        let cleanupMode: PenCleanupMode
        if let text = Self.value(Self.cleanupModeEnvironmentKey, in: environment) {
            guard let mode = PenCleanupMode(argument: text) else {
                throw ParseError.unknownCleanupMode(text)
            }
            cleanupMode = mode
        } else {
            cleanupMode = .deleteAfterAcknowledge
        }

        let abortAtPacket: Int?
        if let text = Self.value(Self.abortAtPacketEnvironmentKey, in: environment) {
            let digits = text.trimmingCharacters(in: .whitespaces)
            guard let packets = Int(digits), packets > 0 else {
                throw ParseError.invalidAbortAtPacket(text)
            }
            abortAtPacket = packets
        } else {
            abortAtPacket = nil
        }

        let confirmCleanup: Bool
        if let text = Self.value(Self.confirmCleanupEnvironmentKey, in: environment) {
            guard let confirmed = Self.confirmCleanupArguments
                .first(where: { $0.spelling == text.trimmingCharacters(in: .whitespaces).lowercased() })
            else {
                throw ParseError.invalidConfirmCleanup(text)
            }
            confirmCleanup = confirmed.confirmed
        } else {
            confirmCleanup = false
        }

        guard !(confirmCleanup && cleanupMode == .keepOnPen) else {
            throw ParseError.confirmationWithoutIntent
        }

        self.init(
            traceURL: URL(fileURLWithPath: tracePath),
            exportDirectory: Self.value(Self.exportDirectoryEnvironmentKey, in: environment),
            transferOption: transferOption,
            cleanupMode: cleanupMode,
            confirmCleanup: confirmCleanup,
            abortAtPacket: abortAtPacket
        )
    }

    /// Every spelling the confirmation key accepts, paired with what it means.
    ///
    /// A yes or a no has to be spelled out, because an unreadable value is refused:
    /// a run that meant to confirm and misspelled it would otherwise take the
    /// ordinary non-destructive read and look like a successful deleting read.
    public static let confirmCleanupArguments: [(spelling: String, confirmed: Bool)] = [
        ("true", true),
        ("yes", true),
        ("1", true),
        ("false", false),
        ("no", false),
        ("0", false),
    ]

    /// A variable's value, or `nil` when it is unset or empty.
    ///
    /// An empty value counts as unset rather than as a mistake, because a shell
    /// variable that expanded to nothing did not ask for anything. The `run` line at
    /// the head of every transcript records the option, cleanup intent, confirmation,
    /// and abort the run actually used, so a run that fell back to a default is
    /// visible in the record even when the operator did not notice the missing value.
    private static func value(_ key: String, in environment: [String: String]) -> String? {
        guard let value = environment[key], !value.isEmpty else { return nil }
        return value
    }
}

extension PenAcceptanceOptions {
    /// Applies the run's cleanup choice to a controller.
    ///
    /// It goes through the same two calls the menu makes, so a headless run cannot
    /// reach a state the interface does not have: the intent first, and the
    /// confirmation — which is what authorizes a deleting transfer — only when the
    /// run asked for it. A run that sets the intent without confirming therefore
    /// takes the ordinary non-destructive read, exactly as a person who has not
    /// confirmed cleanup does.
    ///
    /// - Parameter controller: The controller the run will read through.
    @MainActor
    public func applyCleanupChoice(to controller: PenSyncController) {
        switch cleanupMode {
        case .keepOnPen:
            controller.retainPenDataForThisSync()
        case .deleteAfterAcknowledge:
            controller.intendCleanupForThisSync()
            if confirmCleanup {
                controller.confirmCleanupForThisSync()
            }
        }
    }
}

extension OfflineReadTransferOption {
    /// The name this option is written as in an environment variable.
    public var argumentName: String {
        switch self {
        case .notNextTransfer: return "notNextTransfer"
        case .nextAndReserve: return "nextAndReserve"
        }
    }

    /// The option named by an environment value, or `nil` when none matches.
    ///
    /// The case name and the option's byte are both accepted, in decimal or
    /// hexadecimal, so a transcript can be produced from either wording without
    /// the writer having to remember which one the parser wants.
    public init?(argument: String) {
        let text = argument.trimmingCharacters(in: .whitespaces)
        if let match = OfflineReadTransferOption.allCases.first(where: {
            $0.argumentName.lowercased() == text.lowercased()
        }) {
            self = match
            return
        }

        let isHexadecimal = text.hasPrefix("0x") || text.hasPrefix("0X")
        let digits = isHexadecimal ? String(text.dropFirst(2)) : text
        guard let value = UInt8(digits, radix: isHexadecimal ? 16 : 10),
              let match = OfflineReadTransferOption.allCases.first(where: {
                  $0.rawValue == value
              })
        else { return nil }
        self = match
    }
}

extension PenCleanupMode {
    /// The name this mode is written as in an environment variable.
    public var argumentName: String {
        switch self {
        case .keepOnPen: return "keepOnPen"
        case .deleteAfterAcknowledge: return "deleteAfterAcknowledge"
        }
    }

    /// Every spelling ``init?(argument:)`` accepts, for the refusal message.
    ///
    /// A value the parser accepts has to be documented somewhere an operator can
    /// find it, so this list is built from the same table the parser reads rather
    /// than written out beside it.
    public static var acceptedArguments: [String] {
        spellings.map(\.spelling)
    }

    /// The mode named by an environment value, or `nil` when none matches.
    ///
    /// The case names are accepted, and so are the shorter `keep` and `cleanup`,
    /// which is how the checklist names the two outcomes a user chooses between.
    /// Nothing else is: an alias the documentation does not name would let a
    /// transcript be produced from a value the record does not explain.
    public init?(argument: String) {
        let text = argument.trimmingCharacters(in: .whitespaces).lowercased()
        guard let match = Self.spellings.first(where: {
            $0.spelling.lowercased() == text
        }) else { return nil }
        self = match.mode
    }

    /// The accepted spellings, each paired with the mode it selects.
    private static let spellings: [(spelling: String, mode: PenCleanupMode)] = [
        ("keepOnPen", .keepOnPen),
        ("keep", .keepOnPen),
        ("deleteAfterAcknowledge", .deleteAfterAcknowledge),
        ("cleanup", .deleteAfterAcknowledge),
    ]
}
