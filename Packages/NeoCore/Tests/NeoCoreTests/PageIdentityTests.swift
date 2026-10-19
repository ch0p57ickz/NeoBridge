import XCTest

@testable import NeoCore

final class PageIdentityTests: XCTestCase {
    private let base = PageIdentity(section: 3, owner: 0x000ABC, book: 7, page: 12)

    func testIdenticalTuplesAreEqual() {
        let other = PageIdentity(section: 3, owner: 0x000ABC, book: 7, page: 12)
        XCTAssertEqual(base, other)
        XCTAssertEqual(Set([base, other]).count, 1)
    }

    func testEveryComponentChangesIdentity() {
        let variants: [PageIdentity] = [
            PageIdentity(section: 4, owner: 0x000ABC, book: 7, page: 12),
            PageIdentity(section: 3, owner: 0x000ABD, book: 7, page: 12),
            PageIdentity(section: 3, owner: 0x000ABC, book: 8, page: 12),
            PageIdentity(section: 3, owner: 0x000ABC, book: 7, page: 13)
        ]

        for variant in variants {
            XCTAssertNotEqual(base, variant, "\(variant) must differ from \(base)")
            XCTAssertFalse(Set([base, variant]).count == 1)
        }
        XCTAssertEqual(Set([base] + variants).count, 5)
    }

    func testComponentsArePreservedWithoutFormatting() {
        let identity = PageIdentity(section: 0, owner: 0, book: 0, page: 0)
        XCTAssertEqual(identity.section, 0)
        XCTAssertEqual(identity.owner, 0)
        XCTAssertEqual(identity.book, 0)
        XCTAssertEqual(identity.page, 0)

        let wide = PageIdentity(section: 255, owner: 0x00FF_FFFF, book: 0xFFFF_FFFF, page: 0xFFFF_FFFF)
        XCTAssertEqual(wide.section, 255)
        XCTAssertEqual(wide.owner, 0x00FF_FFFF)
        XCTAssertEqual(wide.book, 0xFFFF_FFFF)
        XCTAssertEqual(wide.page, 0xFFFF_FFFF)
    }

    func testDescriptionIsDiagnosticOnly() {
        XCTAssertEqual(base.description, "Ncode(section: 3, owner: 2748, book: 7, page: 12)")
    }
}
