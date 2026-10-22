import Foundation

/// A JSON value a strict parse produced.
///
/// Object members keep their file order and are never collapsed, so a document
/// that names one key twice stays visible instead of silently losing whichever
/// value the reader happened to keep. `JSONSerialization` cannot report that, and
/// it also accepts shapes this reader would have to guess about, so the reader
/// parses by hand: an existing export target is the one file in the folder the
/// library cannot regenerate, and a field this build cannot read has to count as
/// data it cannot compare rather than as data that is not there.
enum StrictJSONValue: Equatable, Sendable {
    /// An object, with its members in file order.
    case object([Member])

    /// An array, with its elements in file order.
    case array([StrictJSONValue])

    /// A string, with its escape sequences decoded.
    case string(String)

    /// A number written as an integer literal, such as `-12`.
    case integer(Int64)

    /// A number with a fraction or an exponent, or an integer literal too large
    /// for `Int64`.
    ///
    /// The literal is kept so a caller can say what it saw.
    case nonIntegerNumber(String)

    /// A boolean.
    case bool(Bool)

    /// A null.
    case null

    /// One object member.
    struct Member: Equatable, Sendable {
        /// The member's key, with its escape sequences decoded.
        let key: String

        /// The member's value.
        let value: StrictJSONValue
    }
}

/// A reason a strict parse refused a document.
enum StrictJSONError: Error, Hashable {
    /// The input held no value at all.
    case emptyInput

    /// The input ended inside a value.
    case unexpectedEndOfInput

    /// A byte that cannot appear where it was found.
    case unexpectedByte(UInt8, offset: Int)

    /// A number that does not follow the JSON grammar.
    case malformedNumber(String)

    /// A string with an unterminated escape, an unpaired surrogate, or invalid
    /// UTF-8.
    case malformedString

    /// A control character that was not escaped.
    case unescapedControlCharacter

    /// An object or array nested deeper than the reader accepts.
    case nestingTooDeep

    /// Something other than whitespace followed the top-level value.
    case trailingContent(offset: Int)
}

/// The bytes the JSON grammar is written in.
private enum JSONByte {
    static let quotation = UInt8(ascii: "\"")
    static let colon = UInt8(ascii: ":")
    static let comma = UInt8(ascii: ",")
    static let openBrace = UInt8(ascii: "{")
    static let closeBrace = UInt8(ascii: "}")
    static let openBracket = UInt8(ascii: "[")
    static let closeBracket = UInt8(ascii: "]")
    static let backslash = UInt8(ascii: "\\")
    static let minus = UInt8(ascii: "-")
    static let plus = UInt8(ascii: "+")
    static let dot = UInt8(ascii: ".")
    static let zero = UInt8(ascii: "0")
    static let nine = UInt8(ascii: "9")
    static let lowerE = UInt8(ascii: "e")
    static let upperE = UInt8(ascii: "E")
    static let lowerU = UInt8(ascii: "u")

    /// Whether a byte is an ASCII digit.
    static func isDigit(_ byte: UInt8) -> Bool { byte >= zero && byte <= nine }
}

/// A strict JSON reader for one document.
///
/// The grammar is the one in RFC 8259, with two deliberate strictness choices.
/// A value other than whitespace after the top-level value is refused, so a JSON
/// file someone appended text to cannot be mistaken for a complete record, and
/// nesting is capped so a hostile file cannot exhaust the stack.
struct StrictJSONReader {
    /// The deepest object or array nesting the reader accepts.
    static let maximumDepth = 64

    /// The document's bytes.
    private let bytes: [UInt8]

    /// How far into the document the reader has parsed.
    private var offset = 0

    /// How many objects and arrays enclose the current position.
    private var depth = 0

    private init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Parses exactly one JSON document.
    ///
    /// - Parameter bytes: The document's bytes.
    /// - Returns: The document's top-level value.
    /// - Throws: A ``StrictJSONError`` when the bytes are not one complete,
    ///   well-formed JSON document.
    static func parse(_ bytes: [UInt8]) throws -> StrictJSONValue {
        var reader = StrictJSONReader(bytes)
        reader.skipWhitespace()
        guard reader.offset < reader.bytes.count else {
            throw StrictJSONError.emptyInput
        }
        let value = try reader.parseValue()
        reader.skipWhitespace()
        guard reader.offset == reader.bytes.count else {
            throw StrictJSONError.trailingContent(offset: reader.offset)
        }
        return value
    }

    // MARK: - Values

    /// Parses one value at the current position.
    private mutating func parseValue() throws -> StrictJSONValue {
        guard offset < bytes.count else { throw StrictJSONError.unexpectedEndOfInput }
        switch bytes[offset] {
        case JSONByte.openBrace:
            return .object(try parseObject())
        case JSONByte.openBracket:
            return .array(try parseArray())
        case JSONByte.quotation:
            return .string(try parseString())
        case UInt8(ascii: "t"):
            try expectLiteral("true")
            return .bool(true)
        case UInt8(ascii: "f"):
            try expectLiteral("false")
            return .bool(false)
        case UInt8(ascii: "n"):
            try expectLiteral("null")
            return .null
        case JSONByte.minus, JSONByte.zero...JSONByte.nine:
            return try parseNumber()
        default:
            throw StrictJSONError.unexpectedByte(bytes[offset], offset: offset)
        }
    }

    /// Parses an object's members.
    private mutating func parseObject() throws -> [StrictJSONValue.Member] {
        try enter()
        defer { depth -= 1 }
        offset += 1

        var members: [StrictJSONValue.Member] = []
        skipWhitespace()
        if consume(JSONByte.closeBrace) { return members }

        while true {
            skipWhitespace()
            let key = try parseString()
            skipWhitespace()
            guard consume(JSONByte.colon) else { throw unexpectedByte() }
            skipWhitespace()
            members.append(StrictJSONValue.Member(key: key, value: try parseValue()))
            skipWhitespace()

            if consume(JSONByte.comma) { continue }
            guard consume(JSONByte.closeBrace) else { throw unexpectedByte() }
            return members
        }
    }

    /// Parses an array's elements.
    private mutating func parseArray() throws -> [StrictJSONValue] {
        try enter()
        defer { depth -= 1 }
        offset += 1

        var elements: [StrictJSONValue] = []
        skipWhitespace()
        if consume(JSONByte.closeBracket) { return elements }

        while true {
            skipWhitespace()
            elements.append(try parseValue())
            skipWhitespace()

            if consume(JSONByte.comma) { continue }
            guard consume(JSONByte.closeBracket) else { throw unexpectedByte() }
            return elements
        }
    }

    /// Parses a string literal at the current position.
    ///
    /// The content is collected as UTF-8 bytes and validated once at the end.
    /// UTF-8 validation is self-synchronizing, so a document with a truncated or
    /// overlong sequence anywhere in one string fails as a whole.
    private mutating func parseString() throws -> String {
        guard consume(JSONByte.quotation) else { throw unexpectedByte() }

        var content: [UInt8] = []
        while true {
            guard offset < bytes.count else { throw StrictJSONError.unexpectedEndOfInput }
            let byte = bytes[offset]
            offset += 1

            if byte == JSONByte.quotation { break }
            if byte < 0x20 { throw StrictJSONError.unescapedControlCharacter }
            if byte != JSONByte.backslash {
                content.append(byte)
                continue
            }

            guard offset < bytes.count else { throw StrictJSONError.unexpectedEndOfInput }
            let escape = bytes[offset]
            offset += 1
            switch escape {
            case UInt8(ascii: "\""), JSONByte.backslash, UInt8(ascii: "/"):
                content.append(escape)
            case UInt8(ascii: "b"): content.append(0x08)
            case UInt8(ascii: "f"): content.append(0x0C)
            case UInt8(ascii: "n"): content.append(0x0A)
            case UInt8(ascii: "r"): content.append(0x0D)
            case UInt8(ascii: "t"): content.append(0x09)
            case JSONByte.lowerU:
                content.append(contentsOf: utf8Bytes(of: try parseUnicodeEscape()))
            default:
                throw StrictJSONError.malformedString
            }
        }

        guard let text = String(bytes: content, encoding: .utf8) else {
            throw StrictJSONError.malformedString
        }
        return text
    }

    /// Parses a number at the current position.
    ///
    /// A literal with a fraction or an exponent, or an integer too large for
    /// `Int64`, is reported as ``StrictJSONValue/nonIntegerNumber(_:)`` rather than
    /// rounded: every number this exporter writes is an exact integer, so a
    /// rounded value would compare as data that means something the file does not.
    private mutating func parseNumber() throws -> StrictJSONValue {
        let start = offset
        consume(JSONByte.minus)

        if consume(JSONByte.zero) {
            // A leading zero may not be followed by another digit.
            guard !(peek().map(JSONByte.isDigit) ?? false) else {
                throw StrictJSONError.malformedNumber(literal(from: start))
            }
        } else if peek().map(JSONByte.isDigit) ?? false {
            advanceThroughDigits()
        } else {
            throw StrictJSONError.malformedNumber(literal(from: start))
        }

        var isIntegerLiteral = true
        if consume(JSONByte.dot) {
            isIntegerLiteral = false
            guard peek().map(JSONByte.isDigit) ?? false else {
                throw StrictJSONError.malformedNumber(literal(from: start))
            }
            advanceThroughDigits()
        }

        if let exponent = peek(), exponent == JSONByte.lowerE || exponent == JSONByte.upperE {
            isIntegerLiteral = false
            offset += 1
            if let sign = peek(), sign == JSONByte.plus || sign == JSONByte.minus { offset += 1 }
            guard peek().map(JSONByte.isDigit) ?? false else {
                throw StrictJSONError.malformedNumber(literal(from: start))
            }
            advanceThroughDigits()
        }

        let text = literal(from: start)
        if isIntegerLiteral, let value = Int64(text) { return .integer(value) }
        return .nonIntegerNumber(text)
    }

    // MARK: - Escapes

    /// Parses the four hexadecimal digits of a `\u` escape and combines a
    /// surrogate pair into one code point.
    private mutating func parseUnicodeEscape() throws -> UInt32 {
        let leading = try parseHexQuad()
        if (0xD800...0xDBFF).contains(leading) {
            // A leading surrogate only names a code point when a trailing
            // surrogate follows it.
            guard consume(JSONByte.backslash), consume(JSONByte.lowerU) else {
                throw StrictJSONError.malformedString
            }
            let trailing = try parseHexQuad()
            guard (0xDC00...0xDFFF).contains(trailing) else {
                throw StrictJSONError.malformedString
            }
            return 0x10000 + ((leading - 0xD800) << 10) + (trailing - 0xDC00)
        }
        guard !(0xDC00...0xDFFF).contains(leading) else {
            throw StrictJSONError.malformedString
        }
        return leading
    }

    /// Parses four hexadecimal digits.
    private mutating func parseHexQuad() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard offset < bytes.count else { throw StrictJSONError.unexpectedEndOfInput }
            guard let digit = hexDigit(of: bytes[offset]) else {
                throw StrictJSONError.malformedString
            }
            offset += 1
            value = value << 4 | UInt32(digit)
        }
        return value
    }

    /// The value of one hexadecimal digit, or `nil`.
    private func hexDigit(of byte: UInt8) -> UInt8? {
        switch byte {
        case JSONByte.zero...JSONByte.nine: return byte - JSONByte.zero
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// The UTF-8 bytes of a code point the reader has already range-checked.
    private func utf8Bytes(of scalar: UInt32) -> [UInt8] {
        guard let value = UnicodeScalar(scalar) else { return [] }
        return Array(String(value).utf8)
    }

    // MARK: - Scanning

    /// Skips the whitespace the grammar allows.
    private mutating func skipWhitespace() {
        while offset < bytes.count {
            switch bytes[offset] {
            case 0x20, 0x09, 0x0A, 0x0D: offset += 1
            default: return
            }
        }
    }

    /// Consumes one specific byte when it is next, reporting whether it was.
    @discardableResult
    private mutating func consume(_ byte: UInt8) -> Bool {
        guard offset < bytes.count, bytes[offset] == byte else { return false }
        offset += 1
        return true
    }

    /// Consumes an exact literal such as `true`.
    private mutating func expectLiteral(_ text: String) throws {
        for byte in text.utf8 {
            guard offset < bytes.count else { throw StrictJSONError.unexpectedEndOfInput }
            guard bytes[offset] == byte else { throw unexpectedByte() }
            offset += 1
        }
    }

    /// Consumes digits.
    private mutating func advanceThroughDigits() {
        while let byte = peek(), JSONByte.isDigit(byte) { offset += 1 }
    }

    /// The next byte, or `nil` at the end of the input.
    private func peek() -> UInt8? {
        offset < bytes.count ? bytes[offset] : nil
    }

    /// The text between two offsets of the input.
    private func literal(from start: Int) -> String {
        String(decoding: bytes[start..<offset], as: UTF8.self)
    }

    /// Enters a nested object or array, refusing one nested too deeply.
    private mutating func enter() throws {
        depth += 1
        guard depth <= Self.maximumDepth else { throw StrictJSONError.nestingTooDeep }
    }

    /// A rejection of whatever byte is next.
    ///
    /// The byte is read rather than assumed, so the error names what was actually
    /// found; at the end of the input it reports that instead.
    private func unexpectedByte() -> StrictJSONError {
        guard offset < bytes.count else { return .unexpectedEndOfInput }
        return .unexpectedByte(bytes[offset], offset: offset)
    }
}
