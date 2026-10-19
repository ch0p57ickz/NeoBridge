/// Canonical Ncode page identity.
///
/// A page is identified by the complete Ncode tuple: section, owner, book, and
/// page. Each component stays an integer, so no component is lost to string
/// formatting, padding, or truncation. Two page references are the same page only
/// when all four components match.
public struct PageIdentity: Hashable, Sendable, Codable {
    /// Ncode section index.
    public let section: UInt8

    /// Ncode owner identifier.
    ///
    /// The A1 transmits 24 bits for this field. The value is stored exactly as
    /// given so that a non-wire caller is not silently truncated.
    public let owner: UInt32

    /// Ncode book (note) identifier.
    public let book: UInt32

    /// Ncode page identifier.
    public let page: UInt32

    public init(section: UInt8, owner: UInt32, book: UInt32, page: UInt32) {
        self.section = section
        self.owner = owner
        self.book = book
        self.page = page
    }
}

extension PageIdentity: CustomStringConvertible {
    /// Human-readable form for logs and diagnostics only.
    ///
    /// This string is not part of page identity. Never derive identity or
    /// comparison from it.
    public var description: String {
        "Ncode(section: \(section), owner: \(owner), book: \(book), page: \(page))"
    }
}
