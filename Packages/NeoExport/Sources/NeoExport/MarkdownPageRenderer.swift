import Foundation
import NeoCore

/// Renders a page as a Markdown page.
///
/// The page carries stable metadata, the stroke and dot counts, and relative
/// links to the matching JSON and SVG files, so a reader who opens the folder can
/// move between the three representations. No host timestamp, device identifier,
/// or source is written.
public enum MarkdownPageRenderer {
    /// Renders a document as UTF-8 Markdown bytes.
    public static func render(_ document: PageExportDocument) -> [UInt8] {
        var lines: [String] = []
        lines.append("# \(ExportEscaping.markdown(document.title))")
        lines.append("")
        lines.append("| Field | Value |")
        lines.append("| --- | --- |")
        lines.append("| Section | \(document.page.section) |")
        lines.append("| Owner | \(document.page.owner) |")
        lines.append("| Book | \(document.page.book) |")
        lines.append("| Page | \(document.page.page) |")
        lines.append("| Format version | \(PageExportDocument.formatVersion) |")
        lines.append("| Strokes | \(document.strokes.count) |")
        lines.append("| Dots | \(document.dotCount) |")
        lines.append("")
        lines.append("## Files")
        lines.append("")
        lines.append("- [JSON](\(document.fileName(for: .json)))")
        lines.append("- [SVG](\(document.fileName(for: .svg)))")
        lines.append("")

        return Array(lines.joined(separator: "\n").utf8)
    }
}
