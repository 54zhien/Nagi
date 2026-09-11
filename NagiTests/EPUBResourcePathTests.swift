import XCTest
@testable import Nagi

/// Pins href normalisation, which decides whether the table of contents, the
/// reading location and the preview agree on the current resource.
final class EPUBResourcePathTests: XCTestCase {

    func testPlainHrefIsUnchanged() {
        XCTAssertEqual(EPUBResourcePath.normalize("chapter.xhtml"), "chapter.xhtml")
        XCTAssertEqual(EPUBResourcePath.normalize("OEBPS/text/chapter-1.xhtml"), "OEBPS/text/chapter-1.xhtml")
    }

    func testFragmentIsDropped() {
        XCTAssertEqual(EPUBResourcePath.normalize("chapter.xhtml#section-2"), "chapter.xhtml")
        XCTAssertEqual(EPUBResourcePath.normalize("chapter.xhtml#"), "chapter.xhtml")
    }

    func testQueryIsDropped() {
        XCTAssertEqual(EPUBResourcePath.normalize("chapter.xhtml?page=3"), "chapter.xhtml")
    }

    func testFragmentBeforeQueryIsDropped() {
        XCTAssertEqual(EPUBResourcePath.normalize("chapter.xhtml#a?b"), "chapter.xhtml")
        XCTAssertEqual(EPUBResourcePath.normalize("chapter.xhtml?x=1#a"), "chapter.xhtml")
    }

    func testLeadingSlashesAreRemoved() {
        XCTAssertEqual(EPUBResourcePath.normalize("/chapter.xhtml"), "chapter.xhtml")
        XCTAssertEqual(EPUBResourcePath.normalize("///chapter.xhtml"), "chapter.xhtml")
    }

    func testPercentEncodingIsDecoded() {
        XCTAssertEqual(EPUBResourcePath.normalize("my%20chapter.xhtml"), "my chapter.xhtml")
        XCTAssertEqual(EPUBResourcePath.normalize("OEBPS/%E7%AC%AC%E4%B8%80%E7%AB%A0.xhtml"), "OEBPS/第一章.xhtml")
    }

    func testMalformedPercentEncodingFallsBackToTheRawValue() {
        XCTAssertEqual(EPUBResourcePath.normalize("bad%zz.xhtml"), "bad%zz.xhtml")
    }

    func testCombinedFormsAreNormalisedToTheSameResource() {
        let expected = "chapter.xhtml"
        XCTAssertEqual(EPUBResourcePath.normalize("chapter.xhtml"), expected)
        XCTAssertEqual(EPUBResourcePath.normalize("/chapter.xhtml#top"), expected)
        XCTAssertEqual(EPUBResourcePath.normalize("chapter.xhtml?a=1"), expected)
    }

    func testEmptyHrefStaysEmpty() {
        XCTAssertEqual(EPUBResourcePath.normalize(""), "")
    }
}
