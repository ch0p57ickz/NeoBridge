import Foundation
import NeoCore

/// Renders a page as a versioned JSON record.
///
/// The record is built by hand rather than by `JSONEncoder`, because the field
/// order has to be fixed: a `Codable` round trip may order keys differently
/// between builds, which would break byte-for-byte reproducibility. The layout is
/// documented in `Packages/NeoExport/README.md`.
public enum JSONPageRenderer {
    /// Renders a document as UTF-8 JSON bytes.
    ///
    /// The bytes carry only replay-relevant data: the four page components, each
    /// stroke's origin reliability and reported milliseconds, and each ordered
    /// point's integer coordinates, time offset, and pressure. Source, host
    /// timestamps, storage identifiers, batch identifiers, and device
    /// identifiers are omitted, so two hosts produce the same file.
    public static func render(_ document: PageExportDocument) -> [UInt8] {
        var lines: [String] = []
        lines.append("{")
        lines.append("  \"formatVersion\": \(PageExportDocument.formatVersion),")
        lines.append("  \"section\": \(document.page.section),")
        lines.append("  \"owner\": \(document.page.owner),")
        lines.append("  \"book\": \(document.page.book),")
        lines.append("  \"page\": \(document.page.page),")
        lines.append("  \"strokes\": [")

        for (index, stroke) in document.strokes.enumerated() {
            let comma = index == document.strokes.count - 1 ? "" : ","
            lines.append("    {")
            lines.append("      \"originTimeReliable\": \(stroke.originTime.isReliable),")
            lines.append(
                "      \"originTimeMilliseconds\": \(milliseconds(stroke.originTime)),"
            )
            lines.append("      \"points\": [")
            for (pointIndex, point) in stroke.points.enumerated() {
                let pointComma = pointIndex == stroke.points.count - 1 ? "" : ","
                lines.append(
                    "        { \"x\": \(point.x), \"y\": \(point.y), "
                        + "\"penTimeOffsetMilliseconds\": \(point.penTimeOffsetMilliseconds), "
                        + "\"pressure\": \(point.pressure) }\(pointComma)"
                )
            }
            lines.append("      ]")
            lines.append("    }\(comma)")
        }

        lines.append("  ]")
        lines.append("}")
        return bytes(lines.joined(separator: "\n") + "\n")
    }

    /// The reported origin time, or `null` when the pen reported none.
    private static func milliseconds(_ origin: PenOriginTime) -> String {
        guard let reported = origin.reportedMilliseconds else { return "null" }
        return "\(reported)"
    }

    /// Converts a text block to UTF-8 bytes with Unix newlines.
    private static func bytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }
}
