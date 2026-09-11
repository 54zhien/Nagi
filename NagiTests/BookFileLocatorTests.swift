import XCTest
@testable import Nagi

/// Pins the sandbox path rules used by the library and the reader repository.
final class BookFileLocatorTests: XCTestCase {
    private var documentsURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .standardizedFileURL
    }

    // MARK: - persistedPath

    func testPersistedPathIsRelativeToDocuments() {
        let url = documentsURL.appending(path: "Imports/Books/id/source.epub")
        XCTAssertEqual(BookFileLocator.persistedPath(for: url), "Imports/Books/id/source.epub")
    }

    func testPersistedPathKeepsPathsOutsideDocuments() {
        let outside = URL(fileURLWithPath: "/tmp/example.epub")
        XCTAssertEqual(BookFileLocator.persistedPath(for: outside), "/tmp/example.epub")
    }

    // MARK: - resolve

    func testResolveAcceptsRelativeImportPaths() {
        let resolved = BookFileLocator.resolve("Imports/Books/id/source.epub")
        let expected = documentsURL.appending(path: "Imports/Books/id/source.epub").path
        XCTAssertEqual(resolved?.path, expected)
    }

    func testResolveRejectsPathsOutsideTheImportsDirectory() {
        XCTAssertNil(BookFileLocator.resolve("Library/Preferences/x.plist"))
        XCTAssertNil(BookFileLocator.resolve("../escape.epub"))
        XCTAssertNil(BookFileLocator.resolve("/etc/passwd"))
    }

    func testResolveAcceptsLegacyAbsolutePathsInsideImports() {
        let legacy = documentsURL.appending(path: "Imports/Books/id/source.txt").path
        XCTAssertEqual(BookFileLocator.resolve(legacy)?.path, legacy)
    }

    // MARK: - normalizedPersistedPath

    func testNormalizedPersistedPathConvertsLegacyAbsolutePaths() {
        let legacy = documentsURL.appending(path: "Imports/Books/id/source.txt").path
        XCTAssertEqual(BookFileLocator.normalizedPersistedPath(legacy), "Imports/Books/id/source.txt")
    }

    func testNormalizedPersistedPathLeavesRelativePathsUnchanged() {
        XCTAssertEqual(BookFileLocator.normalizedPersistedPath("Imports/a.epub"), "Imports/a.epub")
    }

    func testNormalizedPersistedPathKeepsUnrelatedAbsolutePaths() {
        XCTAssertEqual(BookFileLocator.normalizedPersistedPath("/tmp/x.epub"), "/tmp/x.epub")
    }
}
