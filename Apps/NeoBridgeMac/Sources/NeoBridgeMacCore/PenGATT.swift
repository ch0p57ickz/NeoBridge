/// The GATT facts the pen adapter relies on.
///
/// Every value comes from official SDK evidence, so the adapter does not guess a
/// channel: the Neo iOS SDK 3.0 declares the service and both characteristics in
/// `NISDK3/Classes/Common/Global.swift` at commit `a53a01e`, and
/// `NISDK3/Classes/PenController/PenController.swift` writes frames to the write
/// characteristic with `CBCharacteristicWriteType.withResponse`, slicing
/// payloads to a 20-byte maximum transmission unit.
///
/// The SDK declares a 16-bit and a 128-bit form of each identifier, so the scan
/// and the discovery accept either. The 128-bit form is a vendor UUID the SDK
/// registers independently; it is not the standard Bluetooth Base UUID expansion
/// of the 16-bit value, so a match on one form is not a match on the other.
public enum PenGATT {
    /// The 16-bit service identifier the SDK calls `PEN_SERVICE_UUID`.
    public static let serviceShortUUID = "19F1"

    /// The 128-bit service identifier the SDK calls `PEN_SERVICE_UUID_128`.
    public static let serviceUUID = "4F99F138-9D53-5BFA-9E50-B147491AFE68"

    /// The 16-bit write identifier the SDK calls `PEN_CHARACTERISTICS_WRITE_UUID`.
    public static let writeCharacteristicShortUUID = "2BA0"

    /// The 128-bit write identifier the SDK calls
    /// `PEN_CHARACTERISTICS_WRITE_UUID_128`.
    public static let writeCharacteristicUUID = "8bc8cc7d-88ca-56b0-af9a-9bf514d0d61a"

    /// The 16-bit notify identifier the SDK calls
    /// `PEN_CHARACTERISTICS_NOTIFICATION_UUID`.
    public static let notifyCharacteristicShortUUID = "2BA1"

    /// The 128-bit notify identifier the SDK calls
    /// `PEN_CHARACTERISTICS_NOTIFICATION_UUID_128`.
    ///
    /// The SDK calls the channel a notification, and this build enables it as a
    /// notification rather than an indication.
    public static let notifyCharacteristicUUID = "64cd86b1-2256-5aeb-9f04-2caf6c60ae57"

    /// The largest payload the SDK writes to the pen in one call.
    public static let maximumTransmissionUnit = 20
}
