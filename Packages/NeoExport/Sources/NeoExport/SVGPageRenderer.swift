import Foundation
import NeoCore

/// Renders a page as an SVG drawing.
///
/// The drawing carries the same sorted strokes as the JSON record, on the shared
/// page canvas (see `PageCanvas`), with fixed two-decimal formatting and XML
/// escaping on every text and attribute. No host timestamp, device identifier, or
/// source is written.
public enum SVGPageRenderer {
    /// Renders a document as UTF-8 SVG bytes.
    public static func render(_ document: PageExportDocument) -> [UInt8] {
        let canvas = PageCanvas.extent(forPoints: document.strokes.flatMap(\.points))

        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" version=\"1.1\" "
                + "viewBox=\"0 0 \(ExportNumberFormat.hundredths(canvas.width)) "
                + "\(ExportNumberFormat.hundredths(canvas.height))\" "
                + "width=\"\(canvas.widthMillimetres)mm\" "
                + "height=\"\(canvas.heightMillimetres)mm\">"
        )
        lines.append("  <title>\(ExportEscaping.xml(document.title))</title>")
        lines.append(
            "  <desc>\(document.strokes.count) stroke(s), \(document.dotCount) dot(s)</desc>"
        )
        lines.append(
            "  <g fill=\"none\" stroke=\"#000000\" stroke-width=\""
                + "\(ExportNumberFormat.hundredths(PageCanvas.strokeWidthHundredths))\" "
                + "stroke-linecap=\"round\" stroke-linejoin=\"round\">"
        )

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
}
