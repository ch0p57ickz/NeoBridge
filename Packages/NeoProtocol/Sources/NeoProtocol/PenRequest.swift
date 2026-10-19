/// How the pen should treat the note after a `0x23` transfer completes.
///
/// Values come from `REQ.OfflineTransOption` in Neo iOS SDK 3.0
/// (`NISDK3/Classes/Model/RequestStruct.swift`).
public enum OfflineTransferOption: UInt8, Hashable, Sendable {
    /// `NotNextTransfer`: leave the note's data untouched.
    case notNextTransfer = 0

    /// `NextAndDelete`: delete the note's data after the transfer.
    case nextAndDelete = 1

    /// `NextAndReserve`: keep the note's data so a later read still finds it.
    case nextAndReserve = 2
}

/// Whether the pen should compress a `0x23` transfer.
///
/// Values come from `REQ.OfflineCompress` in Neo iOS SDK 3.0.
public enum OfflineCompressionOption: UInt8, Hashable, Sendable {
    /// `None`: the pen streams uncompressed data.
    case none = 0

    /// `Compress`: the pen may compress the transfer.
    case compressed = 1
}

/// The `0xA4` acknowledgement the host sends for each `0x24` data packet.
///
/// Values come from `REQ.OfflineAckTransOP` in Neo iOS SDK 3.0.
public enum PenTransferAcknowledgement: UInt8, Hashable, Sendable {
    /// `Stop` (0): the transfer is finished.
    case stop = 0

    /// `Continue` (1): the pen should send the next packet.
    case next = 1
}

/// Builds the host-to-pen frames the offline read path sends.
///
/// Every layout comes from the Neo iOS SDK 3.0 request structures in
/// `NISDK3/Classes/Model/RequestStruct.swift`, and the connection code, app
/// type, app version, and declared protocol version defaults are the ones the
/// recorded A1 handshake carries. A builder returns `nil` when the evidence
/// table does not classify the command's framing, because the position of the
/// length field would then be a guess.
public enum PenRequest {
    /// The `sectionOwnerId` the SDK sends in its initial `0x21` request.
    ///
    /// Source: `REQ.OfflineNoteList`, whose `sectionOwnerId` is initialized to
    /// `0xffffffff` and never changed, so the SDK asks the pen for every note
    /// rather than for one section and owner.
    public static let noteListSectionOwnerWildcard: UInt32 = 0xFFFF_FFFF

    /// The SDK's default 16-zero connection code.
    public static let defaultConnectionCode = [UInt8](repeating: 0, count: 16)

    /// The application type the SDK reports: `0x1211` for the iOS SDK.
    public static let sdkAppType: UInt16 = 0x1211

    /// The protocol version the SDK declares in its `0x01` request.
    public static let sdkDeclaredProtocolVersion = "2.18"

    /// Builds the `0x01` version request.
    ///
    /// Body: connection code (16), application type (2), application version
    /// (16), declared protocol version (8).
    public static func versionInfo(
        connectionCode: [UInt8] = defaultConnectionCode,
        appType: UInt16 = sdkAppType,
        appVersion: String = "1.0.0",
        protocolVersion: String = sdkDeclaredProtocolVersion
    ) -> [UInt8]? {
        var payload = [UInt8](connectionCode.prefix(16))
        payload.append(contentsOf: repeatElement(0, count: 16 - payload.count))
        payload.append(contentsOf: PenWire.bytes(appType))
        payload.append(contentsOf: PenWire.paddedText(appVersion, width: 16))
        payload.append(contentsOf: PenWire.paddedText(protocolVersion, width: 8))
        return PenFrameEncoder.encode(command: .versionInfo, payload: payload)
    }

    /// Builds the `0x21` offline note list request.
    ///
    /// Body: `sectionOwnerId` (4).
    public static func noteList(
        sectionOwnerId: UInt32 = noteListSectionOwnerWildcard
    ) -> [UInt8]? {
        PenFrameEncoder.encode(
            command: .offlineNoteListRequest,
            payload: PenWire.bytes(sectionOwnerId)
        )
    }

    /// Builds the `0x22` offline page list request.
    ///
    /// Body: `sectionOwnerId` (4), note identifier (4).
    public static func pageList(sectionOwnerId: UInt32, noteId: UInt32) -> [UInt8]? {
        PenFrameEncoder.encode(
            command: .offlinePageListRequest,
            payload: PenWire.bytes(sectionOwnerId) + PenWire.bytes(noteId)
        )
    }

    /// Builds the `0x22` page list request for a discovered note.
    public static func pageList(for note: PenOfflineNote) -> [UInt8]? {
        pageList(sectionOwnerId: note.sectionOwnerId, noteId: note.note)
    }

    /// Builds the `0x23` offline data request.
    ///
    /// Body: transfer option (1), compression option (1), `sectionOwnerId` (4),
    /// note identifier (4), page count (4), then one page identifier (4) per
    /// requested page. A page count of zero asks for the whole note.
    public static func offlineData(
        sectionOwnerId: UInt32,
        noteId: UInt32,
        transferOption: OfflineTransferOption,
        compressionOption: OfflineCompressionOption,
        pageCount: UInt32 = 0,
        pages: [UInt32] = []
    ) -> [UInt8]? {
        let declaredPages = pages.isEmpty ? pageCount : UInt32(pages.count)
        var payload: [UInt8] = [
            transferOption.rawValue,
            compressionOption.rawValue
        ]
        payload.append(contentsOf: PenWire.bytes(sectionOwnerId))
        payload.append(contentsOf: PenWire.bytes(noteId))
        payload.append(contentsOf: PenWire.bytes(declaredPages))
        for page in pages {
            payload.append(contentsOf: PenWire.bytes(page))
        }
        return PenFrameEncoder.encode(command: .offlineDataRequest1, payload: payload)
    }

    /// Builds the `0x23` request for a discovered note.
    ///
    /// The physical A1 trace of 2026-10-18 used `next-and-reserve`, no
    /// compression, and a zero page count; the session follows that trace.
    public static func offlineData(
        for note: PenOfflineNote,
        transferOption: OfflineTransferOption = .nextAndReserve,
        compressionOption: OfflineCompressionOption = .none
    ) -> [UInt8]? {
        offlineData(
            sectionOwnerId: note.sectionOwnerId,
            noteId: note.note,
            transferOption: transferOption,
            compressionOption: compressionOption
        )
    }

    /// Builds the `0xA4` acknowledgement for one `0x24` data packet.
    ///
    /// Body: packet identifier (2), acknowledgement operation (1). The frame is
    /// a response, so an error code of zero sits between the command and the
    /// length, which is what the pen accepted for all 604 acknowledgements in
    /// the capture.
    public static func acknowledgement(
        packetID: UInt16,
        operation: PenTransferAcknowledgement
    ) -> [UInt8]? {
        PenFrameEncoder.encode(
            command: .responseOfflineData,
            payload: PenWire.bytes(packetID) + [operation.rawValue],
            errorCode: 0
        )
    }
}
