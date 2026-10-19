/// Command identifiers of the Neo pen protocol 2.x family.
///
/// Every case is present in the A1-capable official Neo iOS SDK 3.0 command
/// table (`NISDK3/Classes/Model/CMD.swift`). A known identifier is not by itself
/// evidence that the command is safe to use; see `CommandEvidenceRegistry`.
public enum PenCommand: UInt8, Hashable, Sendable, Codable, CaseIterable {
    case versionInfo = 0x01
    case comparePassword = 0x02
    case changePassword = 0x03
    case penState = 0x04
    case setPenState = 0x05
    case systemChange = 0x06
    case systemInfo = 0x07
    case setNoteList = 0x11
    case offlineNoteListRequest = 0x21
    case offlinePageListRequest = 0x22
    case offlineDataRequest1 = 0x23
    case offlineDataRequest2 = 0x24
    case deleteOfflineNoteRequest = 0x25
    case deleteOfflinePageRequest = 0x27
    case firmwareFileRequest1 = 0x31
    case firmwareFileRequest2 = 0x32
    case profileRequest = 0x41
    case eventBatteryAlarm = 0x61
    case eventPowerOff = 0x62
    case eventPenUpDown = 0x63
    case eventPenNewId = 0x64
    case eventPenDotCode = 0x65
    case eventPenDotCode2 = 0x66
    case eventPenDotCode3 = 0x67
    case eventDotError = 0x68
    case eventNewPenDown = 0x69
    case eventNewPenUp = 0x6A
    case eventNewPenNewId = 0x6B
    case eventNewPenDot = 0x6C
    case eventNewDotError = 0x6D
    case eventHoverDot = 0x6F
    case soundResponsePds = 0x73
    case soundRequestLogInfo = 0x74
    case soundRequestLogData = 0x75
    case soundResponseOid = 0x76
    case soundResponseStatus = 0x77
    case responseVersionInfo = 0x81
    case responseComparePassword = 0x82
    case responseChangePassword = 0x83
    case responsePenState = 0x84
    case responseSetPenState = 0x85
    case responseSystemChange = 0x86
    case responseSystemInfo = 0x87
    case responseSetNoteList = 0x91
    case responseOfflineNoteList = 0xA1
    case responseOfflinePageList = 0xA2
    case responseOfflineDataInfo = 0xA3
    case responseOfflineData = 0xA4
    case responseDeleteOfflineNote = 0xA5
    case responseDeleteOfflinePage = 0xA7
    case responseFirmwareFile1 = 0xB1
    case responseFirmwareFile2 = 0xB2
    case responseProfile = 0xC1
    case soundResponseLogInfo = 0xF4
    case soundResponseLogData = 0xF5
}
