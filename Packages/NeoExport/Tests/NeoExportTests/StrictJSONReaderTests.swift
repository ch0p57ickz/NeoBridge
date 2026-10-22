import Foundation
import XCTest

@testable import NeoExport

/// Tests for the strict JSON reader the export record is validated with.
///
/// The reader is the boundary between a file this build wrote and a file someone
/// else edited, so the tests pin the two places it is deliberately stricter than
/// a general-purpose parser: a duplicate key stays visible instead of collapsing,
/// and nothing may follow the top-level value.
final class StrictJSONReaderTests: XCTestCase {
    private func bytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    private func parse(_ text: String) throws -> StrictJSONValue {
        try StrictJSONReader.parse(bytes(text))
    }

    func testAnObjectKeepsEveryMemberSoADuplicateStaysVisible() throws {
        let value = try parse("{\"a\":1,\"a\":2}")

        guard case .object(let members) = value else {
            return XCTFail("expected an object, got \(value)")
        }
        XCTAssertEqual(members.map(\.key), ["a", "a"])
        XCTAssertEqual(members.map(\.value), [.integer(1), .integer(2)])
    }

    func testTheMembersOfAnObjectKeepTheirFileOrder() throws {
        let value = try parse("{\"b\":1,\"a\":2}")

        guard case .object(let members) = value else {
            return XCTFail("expected an object, got \(value)")
        }
        XCTAssertEqual(members.map(\.key), ["b", "a"])
    }

    func testTrailingContentIsRefusedRatherThanIgnored() {
        XCTAssertThrowsError(try parse("1 2")) { error in
            XCTAssertEqual(error as? StrictJSONError, .trailingContent(offset: 2))
        }
        XCTAssertThrowsError(try parse("{\"a\":1}{\"b\":2}"))
        XCTAssertThrowsError(try parse("null text"))
    }

    func testWhitespaceAroundAValueIsAccepted() throws {
        XCTAssertEqual(try parse(" \t\r\n [ 1 , 2 ] \n "), .array([.integer(1), .integer(2)]))
    }

    func testAnIntegerLiteralIsSeparatedFromAnotherNumber() throws {
        let value = try parse("[1, -0, 1.0, 1e3, 1E+3, -2.5, 9223372036854775808]")

        XCTAssertEqual(
            value,
            .array([
                .integer(1),
                .integer(0),
                .nonIntegerNumber("1.0"),
                .nonIntegerNumber("1e3"),
                .nonIntegerNumber("1E+3"),
                .nonIntegerNumber("-2.5"),
                .nonIntegerNumber("9223372036854775808"),
            ])
        )
    }

    func testANumberThatDoesNotFollowTheGrammarIsRefused() {
        for literal in ["01", "1.", ".5", "+1", "1e", "1e+", "-", "0x10", "NaN"] {
            XCTAssertThrowsError(try parse("[\(literal)]"), "must be refused: \(literal)")
        }
    }

    func testEscapesAndSurrogatePairsAreDecoded() throws {
        let value = try parse("[\"a\\u0041\\uD83D\\uDE00\\n\\\"\\\\/\"]")

        XCTAssertEqual(value, .array([.string("aA\u{1F600}\n\"\\/")]))
    }

    func testAnUnpairedSurrogateIsRefused() {
        XCTAssertThrowsError(try parse("[\"\\uD83D\"]"))
        XCTAssertThrowsError(try parse("[\"\\uDE00\"]"))
        XCTAssertThrowsError(try parse("[\"\\uD83D\\u0041\"]"))
        XCTAssertThrowsError(try parse("[\"\\uD83\"]"))
        XCTAssertThrowsError(try parse("[\"\\q\"]"))
    }

    func testAnUnescapedControlCharacterIsRefused() {
        XCTAssertThrowsError(try parse("[\"a\u{01}b\"]"))
    }

    func testAStringThatIsNotUTF8IsRefused() {
        let invalid = Array("[\"".utf8) + [0xFF, 0xFE] + Array("\"]".utf8)

        XCTAssertThrowsError(try StrictJSONReader.parse(invalid))
    }

    func testNestingDeeperThanTheLimitIsRefused() {
        let overLimit = StrictJSONReader.maximumDepth + 1
        let deep = String(repeating: "[", count: overLimit) + String(repeating: "]", count: overLimit)
        let atLimit = StrictJSONReader.maximumDepth
        let exact = String(repeating: "[", count: atLimit) + String(repeating: "]", count: atLimit)

        XCTAssertThrowsError(try parse(deep)) { error in
            XCTAssertEqual(error as? StrictJSONError, .nestingTooDeep)
        }
        XCTAssertNoThrow(try parse(exact))
    }

    func testAnEmptyInputIsRefused() {
        XCTAssertThrowsError(try parse("")) { error in
            XCTAssertEqual(error as? StrictJSONError, .emptyInput)
        }
        XCTAssertThrowsError(try parse("  \n ")) { error in
            XCTAssertEqual(error as? StrictJSONError, .emptyInput)
        }
    }

    func testTruncatedStructureIsRefused() {
        for text in ["{", "[", "{\"a\"", "{\"a\":", "[1,", "[,1]", "{\"a\" 1}", "tru"] {
            XCTAssertThrowsError(try parse(text), "must be refused: \(text)")
        }
    }

    func testTheLiteralsAreExact() throws {
        XCTAssertEqual(try parse("[true, false, null]"), .array([.bool(true), .bool(false), .null]))
        for text in ["[True]", "[TRUE]", "[nul]", "[undefined]"] {
            XCTAssertThrowsError(try parse(text), "must be refused: \(text)")
        }
    }
}
