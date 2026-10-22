import Foundation
import NeoCore

/// A version-1 JSON page record this build validated completely.
///
/// The record is read from a target file that is about to be replaced, so the
/// comparison answers one question: does that file hold anything the new export
/// does not? Anything this build cannot read in full — a malformed document, a
/// version it does not know, a field that should not be there, or a page other
/// than the one being written — produces no record at all, and a caller treats
/// "no record" as "keep the prior bytes".
///
/// Validation is deliberately total rather than lenient. A record that is missing
/// a field, names one this build does not know, or repeats one is refused whole,
/// because an unrecognised field might be a stroke field from another build, and
/// comparing a half-read record could discard the only copy of data the library
/// no longer has.
struct ExistingJSONPage: Equatable, Sendable {
    /// The field names one page record has, in the order the renderer writes them.
    private static let pageFields = ["formatVersion", "section", "owner", "book", "page", "strokes"]

    /// The field names one stroke record has.
    private static let strokeFields = ["originTimeReliable", "originTimeMilliseconds", "points"]

    /// The field names one point record has.
    private static let pointFields = ["x", "y", "penTimeOffsetMilliseconds", "pressure"]

    /// The page the record identifies.
    let page: PageIdentity

    /// The record's strokes, one entry per occurrence, in file order.
    let strokes: [Stroke]

    /// Reads an existing JSON target.
    ///
    /// - Parameter bytes: The target file's bytes.
    /// - Returns: The record, or `nil` when the bytes are not one complete,
    ///   recognised version-1 record of a single page.
    static func read(_ bytes: [UInt8]) -> ExistingJSONPage? {
        guard let root = try? StrictJSONReader.parse(bytes),
            let page = members(of: root, expecting: pageFields),
            // An unsupported version is a document whose fields this build cannot
            // promise to understand, whatever they are named.
            let formatVersion = integer(page["formatVersion"]),
            formatVersion == Int64(PageExportDocument.formatVersion),
            let sectionValue = integer(page["section"]),
            let section = UInt8(exactly: sectionValue),
            let ownerValue = integer(page["owner"]),
            let owner = UInt32(exactly: ownerValue),
            let bookValue = integer(page["book"]),
            let book = UInt32(exactly: bookValue),
            let pageValue = integer(page["page"]),
            let pageNumber = UInt32(exactly: pageValue),
            let strokeValues = elements(of: page["strokes"])
        else { return nil }

        let identity = PageIdentity(
            section: section,
            owner: owner,
            book: book,
            page: pageNumber
        )
        var strokes: [Stroke] = []
        strokes.reserveCapacity(strokeValues.count)

        for strokeValue in strokeValues {
            guard let stroke = members(of: strokeValue, expecting: strokeFields),
                let reliable = boolean(stroke["originTimeReliable"]),
                let originTime = originTime(
                    reliable: reliable,
                    milliseconds: stroke["originTimeMilliseconds"]
                ),
                let pointValues = elements(of: stroke["points"])
            else { return nil }

            var points: [PenPoint] = []
            points.reserveCapacity(pointValues.count)
            for pointValue in pointValues {
                guard let point = members(of: pointValue, expecting: pointFields),
                    let xValue = integer(point["x"]),
                    let x = Int32(exactly: xValue),
                    let yValue = integer(point["y"]),
                    let y = Int32(exactly: yValue),
                    let offset = integer(point["penTimeOffsetMilliseconds"]),
                    let pressureValue = integer(point["pressure"]),
                    let pressure = UInt16(exactly: pressureValue)
                else { return nil }

                points.append(
                    PenPoint(
                        x: x,
                        y: y,
                        penTimeOffsetMilliseconds: offset,
                        pressure: pressure
                    )
                )
            }

            strokes.append(
                Stroke(
                    page: identity,
                    originTime: originTime,
                    points: points,
                    // The record carries no source, and the source is not part of a
                    // stroke's canonical content, so it changes no comparison.
                    source: .offline
                )
            )
        }

        return ExistingJSONPage(page: identity, strokes: strokes)
    }

    /// Whether everything this record says is already in `document`.
    ///
    /// `true` means replacing this record's file with `document`'s JSON loses no
    /// stroke occurrence and describes the same page, so the prior bytes need no
    /// backup.
    ///
    /// The comparison counts occurrences rather than distinct strokes: a page may
    /// legitimately hold several strokes with identical canonical content, so a
    /// record with two of them against one in the new export is a loss that set
    /// comparison would not see. Each stroke is compared by its complete content —
    /// its origin time, including whether the pen reported one at all, and its
    /// ordered points — and not by the canonical encoding, which stores an absent
    /// reported time as zero. Order and formatting are not compared, because
    /// neither changes what the record says.
    func isSupersededBy(_ document: PageExportDocument) -> Bool {
        guard page == document.page else { return false }

        var available: [StrokeContent: Int] = [:]
        for stroke in document.strokes {
            available[StrokeContent(stroke), default: 0] += 1
        }

        for stroke in strokes {
            let key = StrokeContent(stroke)
            guard let count = available[key], count > 0 else { return false }
            available[key] = count - 1
        }
        return true
    }

    /// The complete content of one stroke, as the comparison counts it.
    ///
    /// This covers the same content as the canonical stroke encoding, with one
    /// difference: an absent reported origin time stays distinct from a reported
    /// zero, because the encoding stores both as zero and two records that say
    /// different things would otherwise compare as equal. It is not a `Stroke`
    /// because a stroke also carries a source, which the record does not have. The
    /// page is not part of the key, because it is compared once for the record as a
    /// whole.
    private struct StrokeContent: Hashable {
        /// The stroke's origin time, including whether a time was reported.
        let originTime: PenOriginTime

        /// The stroke's ordered points.
        let points: [PenPoint]

        /// The content of one stroke.
        init(_ stroke: Stroke) {
            originTime = stroke.originTime
            points = stroke.points
        }
    }

    // MARK: - Field reading

    /// An object's members, keyed by name, requiring exactly the expected names.
    ///
    /// A missing name, a name this level does not allow, and a name that appears
    /// twice all fail, which is what makes the caller treat the document as one it
    /// cannot compare.
    private static func members(
        of value: StrictJSONValue,
        expecting names: [String]
    ) -> [String: StrictJSONValue]? {
        guard case .object(let members) = value else { return nil }

        var fields: [String: StrictJSONValue] = [:]
        for member in members {
            guard names.contains(member.key),
                fields.updateValue(member.value, forKey: member.key) == nil
            else { return nil }
        }
        guard fields.count == names.count else { return nil }
        return fields
    }

    /// An array's elements, or `nil` for any other value.
    private static func elements(of value: StrictJSONValue?) -> [StrictJSONValue]? {
        guard case .array(let elements) = value else { return nil }
        return elements
    }

    /// An integer, or `nil` for a value written another way.
    ///
    /// A number with a fraction or an exponent is not an integer this exporter
    /// wrote, so it is refused rather than truncated.
    private static func integer(_ value: StrictJSONValue?) -> Int64? {
        guard case .integer(let number) = value else { return nil }
        return number
    }

    /// A boolean, or `nil` for any other value.
    private static func boolean(_ value: StrictJSONValue?) -> Bool? {
        guard case .bool(let flag) = value else { return nil }
        return flag
    }

    /// The origin time two fields describe, or `nil` when they do not describe one.
    ///
    /// A reliable origin without a time cannot be reconstructed, so it fails
    /// validation instead of becoming an unreliable stroke whose reported time the
    /// file never carried.
    private static func originTime(
        reliable: Bool,
        milliseconds: StrictJSONValue?
    ) -> PenOriginTime? {
        switch (reliable, milliseconds) {
        case (true, .some(.integer(let reported))):
            return .reliable(milliseconds: reported)
        case (false, .some(.integer(let reported))):
            return .unreliable(reportedMilliseconds: reported)
        case (false, .some(.null)):
            return .unreliable(reportedMilliseconds: nil)
        default:
            return nil
        }
    }
}
