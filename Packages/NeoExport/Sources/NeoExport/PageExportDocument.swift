import Foundation
import NeoCore

/// One page's export, with its strokes in the order every renderer uses.
///
/// The order is the canonical encoding bytes, not database row order or arrival
/// order, so the same stroke multiset renders byte-identically however it was
/// imported. Two strokes with identical canonical bytes are adjacent and render
/// identically, which preserves their multiplicity without an unstable
/// tie-breaker.
public struct PageExportDocument: Hashable, Sendable {
    /// The version of the JSON and Markdown layout this build writes.
    public static let formatVersion = 1

    /// The page being exported.
    public let page: PageIdentity

    /// The page's strokes, sorted by canonical bytes.
    public let strokes: [Stroke]

    public init(page: PageIdentity, strokes: [Stroke]) {
        self.page = page
        self.strokes = strokes
            .map { (key: CanonicalStrokeEncoding.encode($0), stroke: $0) }
            .sorted { $0.key.lexicographicallyPrecedes($1.key) }
            .map(\.stroke)
    }

    /// Dots in the page's strokes.
    public var dotCount: Int {
        strokes.reduce(0) { total, stroke in total + stroke.points.count }
    }

    /// The file name stem that carries all four page components.
    ///
    /// The stem is numeric, so two pages that share a page number but differ in
    /// section, owner, or book cannot collide.
    public var fileBaseName: String {
        "ncode-s\(page.section)-o\(page.owner)-b\(page.book)-p\(page.page)"
    }

    /// A one-line description of the page.
    public var title: String {
        "Ncode page section \(page.section), owner \(page.owner), book \(page.book), page \(page.page)"
    }

    /// The file name for one format.
    public func fileName(for format: PenExportFormat) -> String {
        "\(fileBaseName).\(format.fileExtension)"
    }

    /// The file name of the most recent backup for one format.
    ///
    /// - Parameters:
    ///   - format: The format whose backup is named.
    ///   - depth: The backup's position, where 1 is the most recent.
    public func backupFileName(for format: PenExportFormat, depth: Int) -> String {
        "\(fileName(for: format)).bak\(depth)"
    }
}

extension PenExportFormat {
    /// The file extension this format is published with.
    public var fileExtension: String {
        switch self {
        case .json: return "json"
        case .svg: return "svg"
        case .markdown: return "md"
        }
    }

    /// The media type this format is published as.
    public var mediaType: String {
        switch self {
        case .json: return "application/json"
        case .svg: return "image/svg+xml"
        case .markdown: return "text/markdown"
        }
    }
}

/// Fixed numeric formatting shared by the renderers.
///
/// Every value is an integer in the canonical units, and the text is built with
/// integer arithmetic, so no locale, rounding mode, or floating-point value can
/// change the bytes.
public enum ExportNumberFormat {
    /// Formats a coordinate in hundredths of a pen unit, for example `-123.45`.
    public static func hundredths(_ value: Int32) -> String {
        let magnitude = value.magnitude
        return signed(String(magnitude / 100) + "." + paddedTwoDigits(magnitude % 100), value < 0)
    }

    /// Formats a plain integer.
    public static func integer<T: BinaryInteger>(_ value: T) -> String {
        "\(value)"
    }

    /// Formats a length in hundredths of a pen coordinate unit as millimetres,
    /// with one decimal.
    ///
    /// One pen unit is `6.72 * 25.4 / 72 = 889/375` mm, so a hundredth of a unit
    /// is `889/37500` mm and a tenth of a millimetre is `889/3750` hundredths.
    /// The conversion is integer arithmetic on the magnitude, so a negative
    /// length rounds away from zero exactly as a positive one does, and no
    /// locale or rounding mode can change the text.
    ///
    /// - Parameter hundredths: A length in hundredths of a pen coordinate unit.
    public static func millimetres(_ hundredths: Int32) -> String {
        let magnitude = hundredths.magnitude
        let tenths = (UInt64(magnitude) * 889 + 1_875) / 3_750
        return signed("\(tenths / 10).\(tenths % 10)", hundredths < 0 && tenths > 0)
    }

    /// Formats a fractional part as exactly two digits.
    private static func paddedTwoDigits(_ value: UInt32) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    /// Prefixes a magnitude with a minus sign when the value is negative.
    private static func signed(_ text: String, _ isNegative: Bool) -> String {
        isNegative ? "-\(text)" : text
    }
}

/// Escaping shared by the text formats.
public enum ExportEscaping {
    /// Escapes text for an XML or SVG text node or attribute value.
    public static func xml(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&apos;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    /// Escapes text for a Markdown inline context.
    ///
    /// The characters that would start a link, emphasis, code span, or list item
    /// are backslash-escaped, so a value can never be read as markup.
    public static func markdown(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "\\", "`", "*", "_", "[", "]", "(", ")", "#", "+", "-", "!", "|", ">", "<", "&":
                escaped.append("\\")
                escaped.append(character)
            default:
                escaped.append(character)
            }
        }
        return escaped
    }
}
