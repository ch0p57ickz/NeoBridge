/// Battery and onboard storage measurements reported by `0x84`.
public struct PenState: Hashable, Sendable {
    /// Battery charge, from 0 through 100 percent.
    public let batteryLevel: UInt8

    /// Whether the pen reported external charging.
    public let isCharging: Bool

    /// Onboard storage in use, from 0 through 100 percent.
    public let memoryUsed: UInt8

    /// Decodes the 64-byte A1 `0x84` payload after the frame's error code.
    public init?(payload: [UInt8]) {
        guard payload.count == 64 else { return nil }
        let battery = payload[20] & 0x7F
        let used = payload[15]
        guard battery <= 100, used <= 100 else { return nil }
        batteryLevel = battery
        isCharging = payload[20] & 0x80 != 0
        memoryUsed = used
    }
}
