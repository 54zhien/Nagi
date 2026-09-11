import XCTest
@testable import Nagi

/// Pins how a chapter body becomes the short excerpt shown in the settings
/// preview.
final class EPUBPreviewExcerptTests: XCTestCase {

    func testShortTextIsReturnedUnchanged() {
        XCTAssertEqual(EPUBPreviewProvider.excerpt(from: "第一段"), "第一段")
    }

    func testParagraphsAreJoinedWithABlankLine() {
        XCTAssertEqual(EPUBPreviewProvider.excerpt(from: "第一段\n第二段"), "第一段\n\n第二段")
    }

    func testBlankLinesAreCollapsed() {
        XCTAssertEqual(EPUBPreviewProvider.excerpt(from: "第一段\n\n\n第二段"), "第一段\n\n第二段")
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(EPUBPreviewProvider.excerpt(from: "\n  第一段  \n"), "第一段")
    }

    func testTextAtTheLimitIsNotTruncated() {
        let text = String(repeating: "字", count: 280)
        XCTAssertEqual(EPUBPreviewProvider.excerpt(from: text), text)
    }

    func testLongTextIsTruncatedWithAnEllipsis() {
        let excerpt = EPUBPreviewProvider.excerpt(from: String(repeating: "字", count: 400))
        XCTAssertEqual(excerpt.count, 281)
        XCTAssertTrue(excerpt.hasSuffix("…"))
    }

    func testWhitespaceOnlyTextCollapsesToEmpty() {
        XCTAssertEqual(EPUBPreviewProvider.excerpt(from: "   \n  \n "), "")
    }
}
