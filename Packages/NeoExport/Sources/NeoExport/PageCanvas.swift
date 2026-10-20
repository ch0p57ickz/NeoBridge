import Foundation
import NeoCore

/// The fixed canvas every SVG page is drawn on.
///
/// A page used to be drawn at the size of its own ink, so every page came out at
/// a different scale and origin, and the drawing was as small as the writing on
/// it. Every page now shares one canvas, so the pages of a note are directly
/// comparable and overlay, and the ink is drawn at a real pen width.
///
/// The canvas is the A1 notebook's sheet. Its extent in pen coordinate units
/// follows from the sheet's size in millimetres and the pen's coordinate unit.
/// The Neo iOS SDK 3.0 fixes that unit at 6.72 NCode project points
/// (`ScaleHelper.nprojToDot`), and a point is `25.4 / 72` mm, so one unit is
/// `6.72 * 25.4 / 72 = 2.3707` mm.
///
/// The sheet size belongs to the notebook rather than to the pen, because Neo
/// sells NCode paper in several sizes. These constants are the A1's own notebook,
/// 130 x 210 mm. Another notebook would need its own constants; the owner's ink
/// and the SDK agree on this one, which is recorded in `PenUnits`.
///
/// The canvas is a constant, so the same page always renders at the same scale.
/// The one thing that can change it is ink that falls outside the sheet, which
/// grows the canvas rather than clipping the stroke. The origin never moves, so
/// two pages of the same note still line up.
public enum PageCanvas {
    /// The sheet's width in hundredths of a pen coordinate unit.
    ///
    /// `130 mm / (6.72 * 25.4 / 72) = 5483.7`, rounded to a whole hundredth.
    public static let widthHundredths: Int32 = 5484

    /// The sheet's height in hundredths of a pen coordinate unit.
    ///
    /// `210 mm / (6.72 * 25.4 / 72) = 8858.3`, rounded to a whole hundredth.
    public static let heightHundredths: Int32 = 8858

    /// The stroke width in hundredths of a pen coordinate unit.
    ///
    /// The SDK's own stroke renderer draws a one-point line (`lineWidth = 1` in
    /// `PageStrokeView` and `RenderStrokeView`). A point is 0.353 mm, which is
    /// 0.149 units, so the width is 15 hundredths of a unit.
    public static let strokeWidthHundredths: Int32 = 15

    /// A canvas size in hundredths of a pen coordinate unit.
    ///
    /// The origin is always the sheet's own origin, so only the size varies.
    public struct Extent: Hashable, Sendable {
        /// The canvas width.
        public let width: Int32

        /// The canvas height.
        public let height: Int32

        /// The width in millimetres, to one decimal.
        public var widthMillimetres: String { ExportNumberFormat.millimetres(width) }

        /// The height in millimetres, to one decimal.
        public var heightMillimetres: String { ExportNumberFormat.millimetres(height) }
    }

    /// The canvas a page with these points needs.
    ///
    /// This is the sheet unless a point falls past its right or bottom edge. A
    /// stroke is drawn centred on its path, so half the stroke width is added: a
    /// point on the sheet's right or bottom edge must not lose half its line.
    ///
    /// Only the size can grow, and only rightwards and downwards, because the
    /// origin is fixed at `0 0` so that two pages of a note line up. A point left
    /// of or above the origin therefore falls outside the canvas. That cannot
    /// happen in a real read: the wire format carries a `UInt16` integer part, so
    /// a normalized coordinate is never negative, and the SDK's own filter
    /// rejects a value below 1.
    ///
    /// - Parameter points: Every point the page will draw.
    /// - Returns: The canvas size, in hundredths of a pen coordinate unit.
    public static func extent(forPoints points: [PenPoint]) -> Extent {
        var width = widthHundredths
        var height = heightHundredths
        let reach = (strokeWidthHundredths + 1) / 2

        for point in points {
            width = max(width, reached(point.x, by: reach))
            height = max(height, reached(point.y, by: reach))
        }

        return Extent(width: width, height: height)
    }

    /// A coordinate grown by the stroke's half-width.
    ///
    /// A coordinate at or below zero does not grow the canvas, and a coordinate
    /// near `Int32.max` saturates rather than overflowing, so a malformed record
    /// cannot trap the renderer.
    ///
    /// - Parameters:
    ///   - coordinate: The coordinate, in hundredths of a pen coordinate unit.
    ///   - reach: The stroke's half-width.
    /// - Returns: The coordinate plus `reach`, or zero when the coordinate is not
    ///   positive.
    private static func reached(_ coordinate: Int32, by reach: Int32) -> Int32 {
        guard coordinate > 0 else { return 0 }
        let sum = Int64(coordinate) + Int64(reach)
        return sum > Int64(Int32.max) ? Int32.max : Int32(sum)
    }
}
