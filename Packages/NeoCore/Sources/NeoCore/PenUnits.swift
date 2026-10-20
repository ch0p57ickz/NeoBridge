/// Canonical units for portable pen data.
///
/// Live and offline input must be converted into these units before a
/// `PenPoint` is constructed. Because both ingestion paths produce the same
/// integers, the canonical stroke encoding and fingerprint are identical for the
/// same physical stroke.
public enum PenUnits {
    /// Point coordinates are integer hundredths of a pen coordinate unit.
    ///
    /// The A1 reports a coordinate as a 16-bit integer part plus a two-digit
    /// fractional part. Normalizing to hundredths keeps that precision as an
    /// integer, so no rounding is required when encoding.
    ///
    /// One unit is 6.72 NCode project points (`ScaleHelper.nprojToDot` in the Neo
    /// iOS SDK 3.0), which is 2.3707 mm. The sheet size belongs to the notebook,
    /// not to the pen: Neo sells NCode paper from 148 x 83 mm pocket notebooks up
    /// to A4, and the A1's own notebook is 130 x 210 mm, so a page spans
    /// 54.84 x 88.58 units.
    ///
    /// The owner's ink is consistent with that. It reaches 54.39 units on the x
    /// axis, so a unit larger than `130 / 54.39 = 2.390` mm would put that ink
    /// past the edge of the 130 mm sheet, assuming the writing stayed on the
    /// paper. The SDK's 2.3707 mm fits with 0.8% to spare; the 2.54 mm an earlier
    /// guess assumed would run about 8 mm over.
    public static let coordinateHundredthsPerUnit = 100

    /// Pen-time offsets and pen-origin stroke times are integer milliseconds.
    public static let penTimeUnit = "milliseconds"

    /// Pressure is the pen's raw integer pressure reading.
    ///
    /// The reading is kept unscaled so the fingerprint never depends on a
    /// per-device maximum-pressure calibration value.
    public static let pressureUnit = "rawPenPressure"
}

/// A pen sample as a transport delivers it, before normalization.
///
/// The coordinate split matches the A1 wire format: a 16-bit integer part and a
/// fractional part in hundredths.
public struct RawPenSample: Hashable, Sendable {
    /// Integer part of the x coordinate.
    public let integerX: UInt16

    /// Fractional part of the x coordinate, in hundredths. Valid range is 0...99.
    public let hundredthsX: UInt8

    /// Integer part of the y coordinate.
    public let integerY: UInt16

    /// Fractional part of the y coordinate, in hundredths. Valid range is 0...99.
    public let hundredthsY: UInt8

    /// Milliseconds from the pen-origin stroke start time to this sample.
    public let penTimeOffsetMilliseconds: Int64

    /// Raw pen pressure reading.
    public let pressure: UInt16

    public init(
        integerX: UInt16,
        hundredthsX: UInt8,
        integerY: UInt16,
        hundredthsY: UInt8,
        penTimeOffsetMilliseconds: Int64,
        pressure: UInt16
    ) {
        self.integerX = integerX
        self.hundredthsX = hundredthsX
        self.integerY = integerY
        self.hundredthsY = hundredthsY
        self.penTimeOffsetMilliseconds = penTimeOffsetMilliseconds
        self.pressure = pressure
    }
}

/// Converts transport samples into canonical `PenPoint` values.
public enum PenSampleNormalizer {
    /// Converts a raw sample into canonical integer units.
    ///
    /// - Parameter raw: The sample to normalize.
    /// - Returns: A point in canonical units, or `nil` when the fractional
    ///   hundredths digits are out of range and the sample is malformed.
    public static func normalize(_ raw: RawPenSample) -> PenPoint? {
        guard raw.hundredthsX < 100, raw.hundredthsY < 100 else {
            return nil
        }
        return PenPoint(
            x: Int32(raw.integerX) * Int32(PenUnits.coordinateHundredthsPerUnit) + Int32(raw.hundredthsX),
            y: Int32(raw.integerY) * Int32(PenUnits.coordinateHundredthsPerUnit) + Int32(raw.hundredthsY),
            penTimeOffsetMilliseconds: raw.penTimeOffsetMilliseconds,
            pressure: raw.pressure
        )
    }
}

/// A single normalized pen point.
public struct PenPoint: Hashable, Sendable, Codable {
    /// X coordinate in hundredths of a pen coordinate unit.
    public let x: Int32

    /// Y coordinate in hundredths of a pen coordinate unit.
    public let y: Int32

    /// Milliseconds from the pen-origin stroke start time to this point.
    public let penTimeOffsetMilliseconds: Int64

    /// Raw pen pressure reading.
    public let pressure: UInt16

    public init(x: Int32, y: Int32, penTimeOffsetMilliseconds: Int64, pressure: UInt16) {
        self.x = x
        self.y = y
        self.penTimeOffsetMilliseconds = penTimeOffsetMilliseconds
        self.pressure = pressure
    }
}
