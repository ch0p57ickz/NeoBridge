import Foundation
import NeoCore

/// Renders a page as an SVG drawing.
///
/// The drawing carries the same sorted strokes as the JSON record, with a
/// viewBox derived from the page's own coordinates, fixed two-decimal
/// formatting, and XML escaping on every text and attribute. No host timestamp,
/// device identifier, or source is written.
public enum SVGPageRenderer {
    /// The stroke width in pen units, which is fixed rather than derived from
    /// pressure, so the same strokes always produce the same bytes.
    public static let strokeWidth = 1.0

    /// Renders a document as UTF-8 SVG bytes.
    public static func render(_ document: PageExportDocument) -> [UInt8] {
        let bounds = Bounds(points: document.strokes.flatMap(\.points))

        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" version=\"1.1\" "
                + "viewBox=\"\(bounds.viewBox)\" width=\"\(bounds.widthText)\" "
                + "height=\"\(bounds.heightText)\">"
        )
        lines.append("  <title>\(ExportEscaping.xml(document.title))</title>")
        lines.append(
            "  <desc>\(document.strokes.count) stroke(s), \(document.dotCount) dot(s)</desc>"
        )
        lines.append("  <g fill=\"none\" stroke=\"#000000\" stroke-width=\"1\" "
            + "stroke-linecap=\"round\" stroke-linejoin=\"round\">")

        for stroke in document.strokes where !stroke.points.isEmpty {
            lines.append("    <path d=\"\(path(for: stroke))\"/>")
        }

        lines.append("  </g>")
        lines.append("</svg>")
        return Array((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// The `d` attribute of one stroke's path.
    private static func path(for stroke: Stroke) -> String {
        var commands: [String] = []
        commands.reserveCapacity(stroke.points.count)
        for (index, point) in stroke.points.enumerated() {
            let command = index == 0 ? "M" : "L"
            commands.append(
                "\(command) \(ExportNumberFormat.hundredths(point.x)),"
                    + "\(ExportNumberFormat.hundredths(point.y))"
            )
        }
        return commands.joined(separator: " ")
    }

    /// The drawing's bounding box, derived from the page's own points.
    ///
    /// A page with one point, or with none, has no extent, so each dimension is
    /// at least one unit. The value is derived only from the strokes, so the same
    /// strokes always produce the same viewBox.
    private struct Bounds {
        private let minX: Int32
        private let minY: Int32
        private let maxX: Int32
        private let maxY: Int32

        init(points: [PenPoint]) {
            guard let first = points.first else {
                minX = 0
                minY = 0
                maxX = 1
                maxY = 1
                return
            }

            var minimumX = first.x
            var minimumY = first.y
            var maximumX = first.x
            var maximumY = first.y
            for point in points.dropFirst() {
                minimumX = min(minimumX, point.x)
                minimumY = min(minimumY, point.y)
                maximumX = max(maximumX, point.x)
                maximumY = max(maximumY, point.y)
            }

            minX = minimumX
            minY = minimumY
            maxX = maximumX
            maxY = maximumY
        }

        /// The viewBox attribute.
        var viewBox: String {
            [
                ExportNumberFormat.hundredths(minX),
                ExportNumberFormat.hundredths(minY),
                ExportNumberFormat.hundredths(width),
                ExportNumberFormat.hundredths(height),
            ].joined(separator: " ")
        }

        /// The width attribute, in pen units.
        var widthText: String { ExportNumberFormat.hundredths(width) }

        /// The height attribute, in pen units.
        var heightText: String { ExportNumberFormat.hundredths(height) }

        /// The box width in hundredths, at least one hundredth.
        private var width: Int32 {
            let extent = maxX &- minX
            return extent > 0 ? extent : 1
        }

        /// The box height in hundredths, at least one hundredth.
        private var height: Int32 {
            let extent = maxY &- minY
            return extent > 0 ? extent : 1
        }
    }
}
