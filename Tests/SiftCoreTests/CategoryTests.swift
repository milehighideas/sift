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

    func testDirectoriesUseFoldersFallback() {
        // A plain folder (no recognized extension) groups under "Folders".
        XCTAssertEqual(resolver.category(for: "my project", isDirectory: true), "Folders")
        XCTAssertEqual(resolver.category(for: "Zillow_files", isDirectory: true), "Folders")
        // A directory whose extension IS recognized still categorizes by it.
        XCTAssertEqual(resolver.category(for: "photos.zip", isDirectory: true), "Archives")
    }

    func testCategoryFolderNamesIncludeFallbacks() {
        let names = resolver.categoryFolderNames()
        XCTAssertTrue(names.isSuperset(of: ["Images", "Archives", "Folders", "Other"]))
    }
}
