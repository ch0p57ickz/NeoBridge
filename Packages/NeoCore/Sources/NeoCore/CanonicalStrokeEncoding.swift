/// The versioned canonical byte representation of a stroke.
///
/// The encoding is fixed-width and unambiguous, so two different strokes can
/// never share bytes. It contains only replay-relevant data:
///
/// - the complete page tuple,
/// - the pen-origin stroke start time and whether it is reliable,
/// - the ordered point count,
/// - and each point's integer coordinates, pen-time offset, and pressure.
///
/// Host arrival time, live/offline source, and transport chunking are excluded
/// on purpose. All integers are big-endian, and every field has a fixed width.
///
/// Layout for encoding version 1 (`NeoCoreCanonicalStroke.v1`):
///
/// | Offset | Size | Field                                   |
/// | ------ | ---- | --------------------------------------- |
/// | 0      | 4    | Magic `4E 43 53 01` (`NCS` + version 1) |
/// | 4      | 1    | Section                                 |
/// | 5      | 4    | Owner                                   |
/// | 9      | 4    | Book                                    |
/// | 13     | 4    | Page                                    |
/// | 17     | 1    | Origin reliability (0 reliable, 1 not)  |
/// | 18     | 8    | Origin milliseconds                     |
/// | 26     | 4    | Point count                             |
/// | 30     | 18n  | Points                                  |
///
/// Each point is `x` (4, signed), `y` (4, signed), pen-time offset (8, signed),
/// and pressure (2, unsigned).
public enum CanonicalStrokeEncoding {
    /// The current canonical encoding version.
    public static let version: UInt8 = 1

    /// Magic prefix shared by every encoded stroke.
    public static let magic: [UInt8] = [0x4E, 0x43, 0x53, version]

    /// Fixed size of the header that precedes the point list.
    public static let headerByteCount = 30

    /// Fixed size of one encoded point.
    public static let pointByteCount = 18

    /// Encodes a stroke into its canonical byte form.
    ///
    /// - Parameter stroke: The stroke to encode. Its `source` is ignored.
    /// - Returns: The canonical bytes for the stroke.
    public static func encode(_ stroke: Stroke) -> [UInt8] {
        var bytes = magic
        bytes.reserveCapacity(headerByteCount + pointByteCount * stroke.points.count)

        bytes.append(stroke.page.section)
        appendUInt32(&bytes, stroke.page.owner)
        appendUInt32(&bytes, stroke.page.book)
        appendUInt32(&bytes, stroke.page.page)

        switch stroke.originTime {
        case .reliable(let milliseconds):
            bytes.append(0)
            appendInt64(&bytes, milliseconds)
        case .unreliable(let reportedMilliseconds):
            bytes.append(1)
            appendInt64(&bytes, reportedMilliseconds ?? 0)
        }

        appendUInt32(&bytes, UInt32(stroke.points.count))
        for point in stroke.points {
            appendInt32(&bytes, point.x)
            appendInt32(&bytes, point.y)
            appendInt64(&bytes, point.penTimeOffsetMilliseconds)
            appendUInt16(&bytes, point.pressure)
        }

        return bytes
    }

    private static func appendUInt16(_ bytes: inout [UInt8], _ value: UInt16) {
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }

    private static func appendUInt32(_ bytes: inout [UInt8], _ value: UInt32) {
        bytes.append(UInt8((value >> 24) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }

    private static func appendInt32(_ bytes: inout [UInt8], _ value: Int32) {
        appendUInt32(&bytes, UInt32(bitPattern: value))
    }

    private static func appendInt64(_ bytes: inout [UInt8], _ value: Int64) {
        let pattern = UInt64(bitPattern: value)
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((pattern >> UInt64(shift)) & 0xFF))
        }
    }
}
