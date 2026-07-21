import XCTest
@testable import SiftCore

final class CategoryTests: XCTestCase {
    let resolver = CategoryResolver(map: [
        "images": ["jpg", "png"],
        "archives": ["zip", "gz"],
    ])

    func testMatchesCapitalized() {
        XCTAssertEqual(resolver.category(for: "photo.JPG"), "Images")
        XCTAssertEqual(resolver.category(for: "bundle.tar.gz"), "Archives")
    }

    func testFallbackOther() {
        XCTAssertEqual(resolver.category(for: "notes.xyz"), "Other")
        XCTAssertEqual(resolver.category(for: "Makefile"), "Other")
    }
}
