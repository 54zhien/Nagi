import Foundation
import XCTest
@testable import Nagi

/// Pins TXT decoding and chapter splitting, which the reader inherits through
/// the generated EPUB used for TXT books.
final class TXTParserTests: XCTestCase {

    // MARK: - 编码识别

    func testDecodesPlainUTF8() {
        XCTAssertEqual(TXTParser.decode(Data("第一章".utf8)), "第一章")
    }

    func testDecodesUTF8WithBOM() {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("正文".utf8))
        XCTAssertEqual(TXTParser.decode(data), "正文")
    }

    func testDecodesUTF16LittleEndianWithBOM() {
        var data = Data([0xFF, 0xFE])
        data.append(Data([0x41, 0x00, 0x42, 0x00]))
        XCTAssertEqual(TXTParser.decode(data), "AB")
    }

    func testDecodesGB18030() throws {
        let encoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        let original = "第一章 测试正文"
        let data = try XCTUnwrap(original.data(using: encoding))
        XCTAssertEqual(TXTParser.decode(data), original)
    }

    func testEmptyDataDecodesToEmptyString() {
        XCTAssertEqual(TXTParser.decode(Data()), "")
    }

    func testSupportedExtensionsMatchTheDocumentPicker() {
        XCTAssertEqual(TXTParser.supportedExtensions, ["txt", "text"])
    }

    // MARK: - 章节切分

    func testSplitsOnChineseChapterHeadings() {
        let text = "第一章 开始\n正文甲\n第二章 继续\n正文乙"
        let chapters = TXTParser.splitIntoChapters(text, fallbackTitle: "书")
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].title, "第一章 开始")
        XCTAssertEqual(chapters[0].content, "第一章 开始\n正文甲")
        XCTAssertEqual(chapters[1].title, "第二章 继续")
        XCTAssertEqual(chapters[1].content, "第二章 继续\n正文乙")
    }

    func testLeadingContentBecomesAPrefaceChapter() {
        let text = "这是序言\n\n第一章 开始\n正文"
        let chapters = TXTParser.splitIntoChapters(text, fallbackTitle: "书名")
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].title, "书名")
        XCTAssertEqual(chapters[0].content, "这是序言")
        XCTAssertEqual(chapters[1].title, "第一章 开始")
    }

    func testTextWithoutHeadingsStaysASingleChapter() {
        let chapters = TXTParser.splitIntoChapters("普通段落\n还有一段", fallbackTitle: "书名")
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].title, "书名")
        XCTAssertEqual(chapters[0].content, "普通段落\n还有一段")
    }

    func testRecognisesCommonChapterHeadingVariants() {
        let headings = ["第1章 开始", "第 12 章", "Chapter 3", "楔子", "第一百二十三回"]
        for heading in headings {
            let chapters = TXTParser.splitIntoChapters("\(heading)\n正文", fallbackTitle: "书")
            XCTAssertEqual(chapters.first?.title, heading, "应识别章节标题：\(heading)")
        }
    }

    func testChapterHeadingsAreSplitIntoOneChapterEach() {
        // Headings must produce exactly one chapter each, with no duplication.
        let text = "第1章\n甲\n第2章\n乙\n第3章\n丙"
        let chapters = TXTParser.splitIntoChapters(text, fallbackTitle: "书")
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters.map(\.title), ["第1章", "第2章", "第3章"])
    }
}
