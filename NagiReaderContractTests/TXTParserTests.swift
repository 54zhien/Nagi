import Foundation
import XCTest
@testable import Nagi

final class TXTParserTests: XCTestCase {
    private let parser = TXTParser()

    // Regression: empty files must not acquire text from an encoding fallback.
    func testDecodeEmptyDataAsEmptyString() {
        XCTAssertEqual(TXTParser.decode(Data()), "")
    }

    // Regression: valid UTF-8 must preserve non-BMP text and decomposed scalars.
    func testDecodeBOMlessUTF8PreservesChineseEmojiAndDecomposedMark() {
        let decoded = TXTParser.decode(Data("中文😀e\u{0301}".utf8))

        XCTAssertEqual(
            decoded.unicodeScalars.map { $0.value },
            [0x4E2D, 0x6587, 0x1F600, 0x0065, 0x0301]
        )
    }

    // Regression: UTF-32 LE shares the UTF-16 LE prefix, so BOM precedence must retain the emoji.
    func testDecodeAllAuthoritativeBOMVariants() {
        let variants: [(name: String, bytes: [UInt8], expected: String)] = [
            (
                "UTF-8",
                [0xEF, 0xBB, 0xBF, 0x41, 0xE4, 0xB8, 0xAD, 0xF0, 0x9F, 0x98, 0x80, 0x0A],
                "A中😀\n"
            ),
            (
                "UTF-16 LE",
                [0xFF, 0xFE, 0x41, 0x00, 0x2D, 0x4E, 0x3D, 0xD8, 0x00, 0xDE, 0x0A, 0x00],
                "A中😀\n"
            ),
            (
                "UTF-16 BE",
                [0xFE, 0xFF, 0x00, 0x41, 0x4E, 0x2D, 0xD8, 0x3D, 0xDE, 0x00, 0x00, 0x0A],
                "A中😀\n"
            ),
            (
                "UTF-32 LE",
                [0xFF, 0xFE, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00, 0x2D, 0x4E, 0x00, 0x00, 0x00, 0xF6, 0x01, 0x00, 0x0A, 0x00, 0x00, 0x00],
                "A中😀\n"
            ),
            (
                "UTF-32 BE",
                [0x00, 0x00, 0xFE, 0xFF, 0x00, 0x00, 0x00, 0x41, 0x00, 0x00, 0x4E, 0x2D, 0x00, 0x01, 0xF6, 0x00, 0x00, 0x00, 0x00, 0x0A],
                "A中😀\n"
            ),
        ]

        for variant in variants {
            XCTAssertEqual(TXTParser.decode(Data(variant.bytes)), variant.expected, variant.name)
        }
    }

    // Regression: NUL-byte sampling must distinguish BOM-less UTF-16 endianness.
    func testDetectBOMlessUTF16EndiannessFromASCIIHeavySample() {
        let variants: [(name: String, bytes: [UInt8])] = [
            ("UTF-16 LE", [0x41, 0x00, 0x42, 0x00, 0x43, 0x00, 0x44, 0x00, 0x2D, 0x4E]),
            ("UTF-16 BE", [0x00, 0x41, 0x00, 0x42, 0x00, 0x43, 0x00, 0x44, 0x4E, 0x2D]),
        ]

        for variant in variants {
            XCTAssertEqual(TXTParser.decode(Data(variant.bytes)), "ABCD中", variant.name)
        }
    }

    // Regression: UTF-32 detection needs its full 16-byte sample and must keep non-BMP scalars.
    func testDetectBOMlessUTF32EndiannessWithNonBMPSample() {
        let variants: [(name: String, bytes: [UInt8])] = [
            (
                "UTF-32 LE",
                [0x41, 0x00, 0x00, 0x00, 0x2D, 0x4E, 0x00, 0x00, 0x00, 0xF6, 0x01, 0x00, 0x0A, 0x00, 0x00, 0x00]
            ),
            (
                "UTF-32 BE",
                [0x00, 0x00, 0x00, 0x41, 0x00, 0x00, 0x4E, 0x2D, 0x00, 0x01, 0xF6, 0x00, 0x00, 0x00, 0x00, 0x0A]
            ),
        ]

        for variant in variants {
            XCTAssertEqual(TXTParser.decode(Data(variant.bytes)), "A中😀\n", variant.name)
        }
    }

    // Regression: Chinese GB18030 fallback must handle both two-byte and four-byte mappings.
    func testDecodeGB18030TwoByteAndFourByteSequences() {
        let variants: [(bytes: [UInt8], expectedScalars: [UInt32])] = [
            ([0xD6, 0xD0, 0xCE, 0xC4], [0x4E2D, 0x6587]),
            ([0x81, 0x30, 0x81, 0x30], [0x0080]),
        ]

        for variant in variants {
            let decoded = TXTParser.decode(Data(variant.bytes))
            XCTAssertEqual(decoded.unicodeScalars.map { $0.value }, variant.expectedScalars)
        }
    }

    // Regression: an invalid authoritative UTF-8 BOM must not fall through to GB18030.
    func testMalformedUTF8BOMIsAuthoritativeButUnmarkedInputUsesLossyFallback() {
        XCTAssertEqual(TXTParser.decode(Data([0xEF, 0xBB, 0xBF, 0xFF])), "")

        let lossy = TXTParser.decode(Data([0xFF]))
        XCTAssertEqual(lossy.unicodeScalars.map { $0.value }, [0xFFFD])
    }

    // Regression: fallback chapter creation must retain interior blank paragraphs and indentation.
    func testNoHeadingFallbackPreservesInteriorBlankAndIndentedLines() {
        let content = "首段\n\n    缩进段\n\n\t末段"
        let chapters = TXTParser.splitIntoChapters(content, fallbackTitle: "整本书")

        XCTAssertEqual(chapters.map { $0.title }, ["整本书"])
        XCTAssertEqual(chapters.map { $0.content }, ["首段\n\n    缩进段\n\n\t末段"])
    }

    // Regression: whitespace-only input must not create an empty fallback chapter.
    func testWhitespaceOnlyTextProducesNoChapters() {
        XCTAssertTrue(TXTParser.splitIntoChapters("\n \t\r\n", fallbackTitle: "空书").isEmpty)
    }

    // Regression: every supported Unicode newline must normalize while adjacent separators stay distinct.
    func testMixedNewlineSeparatorsNormalizeToLFAndPreserveConsecutiveBoundaries() {
        let content = "甲\r\n\r乙\u{2028}\u{2029}丙\u{0085}丁"
        let chapters = TXTParser.splitIntoChapters(content, fallbackTitle: "分隔符")

        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].content, "甲\n\n乙\n\n丙\n丁")
    }

    // Regression: preface and Chinese headings must keep their exact heading and body text.
    func testPrefaceAndTwoChineseChaptersKeepExactTitlesAndContents() {
        let chapters = TXTParser.splitIntoChapters(
            "前言\n前言第二行\n\n第一章 开始\n正文一\n\n第二章 继续\n正文二",
            fallbackTitle: "书名"
        )

        XCTAssertEqual(chapters.map { $0.title }, ["书名", "第一章 开始", "第二章 继续"])
        XCTAssertEqual(
            chapters.map { $0.content },
            ["前言\n前言第二行", "第一章 开始\n正文一", "第二章 继续\n正文二"]
        )
    }

    // Regression: consecutive headings and a final heading-only chapter must not disappear.
    func testConsecutiveAndLastHeadingOnlyChaptersSurvive() {
        let chapters = TXTParser.splitIntoChapters("第一章\n第二章\n第三章", fallbackTitle: "书名")

        XCTAssertEqual(chapters.map { $0.title }, ["第一章", "第二章", "第三章"])
        XCTAssertEqual(chapters.map { $0.content }, ["第一章", "第二章", "第三章"])
    }

    // Regression: title recognition trims spaces and ignores FEFF, while chapter content trims only its edges.
    func testChapterTitlesTrimSpacesAndIgnoreBOMWhileContentTrimsOnlyEdges() {
        let chapters = TXTParser.splitIntoChapters(
            "  第1章 标题  \n  正文段  \n\n\u{FEFF}第2章 结束\t\n\t正文二\t",
            fallbackTitle: "书名"
        )

        XCTAssertEqual(chapters.map { $0.title }, ["第1章 标题", "第2章 结束"])
        XCTAssertEqual(
            chapters.map { $0.content },
            ["第1章 标题  \n  正文段", "\u{FEFF}第2章 结束\t\n\t正文二"]
        )
    }

    // Regression: the 80-character title limit must be inclusive and longer heading-like prose must remain content.
    func testEightyCharacterHeadingIsAcceptedAndEightyOneCharactersRemainProse() {
        let acceptedHeading = "Chapter 1 " + String(repeating: "a", count: 70)
        let rejectedHeading = "Chapter 1 " + String(repeating: "b", count: 71)
        let expectedContent = acceptedHeading + "\n正文\n" + rejectedHeading + "\n仍是正文"
        let chapters = TXTParser.splitIntoChapters(expectedContent, fallbackTitle: "书名")

        XCTAssertEqual(acceptedHeading.count, 80)
        XCTAssertEqual(rejectedHeading.count, 81)
        XCTAssertEqual(chapters.map { $0.title }, [acceptedHeading])
        XCTAssertEqual(chapters.map { $0.content }, [expectedContent])
    }

    // Regression: English heading matching is case-insensitive but must not accept a digit prefix of a word.
    func testEnglishChapterHeadingIsCaseInsensitiveAndChapterNumberPrefixIsBounded() {
        let chapters = TXTParser.splitIntoChapters(
            "cHaPtEr 1: Start\n第一段\nChapter 1abc remains prose\n后续",
            fallbackTitle: "书名"
        )

        XCTAssertEqual(chapters.map { $0.title }, ["cHaPtEr 1: Start"])
        XCTAssertEqual(
            chapters.map { $0.content },
            ["cHaPtEr 1: Start\n第一段\nChapter 1abc remains prose\n后续"]
        )
    }

    // Regression: Arabic and Chinese numbered headings must split, while ordinary prose stays in its chapter.
    func testArabicAndChineseNumberedHeadingsRetainOrdinaryProse() {
        let chapters = TXTParser.splitIntoChapters(
            "开头说明\n1、开篇\n正文甲\n普通叙述\n二．继续\n正文乙",
            fallbackTitle: "书名"
        )

        XCTAssertEqual(chapters.map { $0.title }, ["书名", "1、开篇", "二．继续"])
        XCTAssertEqual(
            chapters.map { $0.content },
            ["开头说明", "1、开篇\n正文甲\n普通叙述", "二．继续\n正文乙"]
        )
    }

    // Regression: real-file parsing must normalize newlines and FEFF without altering XML characters or Unicode scalars.
    func testParseNormalizesMixedNewlinesAndFEFFButPreservesContentAndMetadata() throws {
        let fileURL = try makeTemporaryFile(
            named: "fixture.title.txt",
            contents: Data(" \t\u{FEFF}标题 <>&\"' e\u{0301}\r\n\r\n 内嵌\u{FEFF}字符\u{2028}尾端 \n".utf8)
        )

        let parsed = try parser.parse(url: fileURL)
        let expectedContent = "标题 <>&\"' e\u{0301}\n\n 内嵌字符\n尾端"
        let chapterContent = try XCTUnwrap(parsed.chapters?.first?.content)

        XCTAssertEqual(parsed.title, "fixture.title")
        XCTAssertNil(parsed.author)
        XCTAssertNil(parsed.coverData)
        XCTAssertEqual(parsed.chapterCount, 1)
        XCTAssertEqual(parsed.content, expectedContent)
        XCTAssertEqual(
            parsed.content.unicodeScalars.map { $0.value },
            expectedContent.unicodeScalars.map { $0.value }
        )
        XCTAssertEqual(
            chapterContent.unicodeScalars.map { $0.value },
            expectedContent.unicodeScalars.map { $0.value }
        )
        XCTAssertEqual(parsed.chapters?.map { $0.title }, ["fixture.title"])
        XCTAssertEqual(parsed.chapters?.map { $0.content }, [expectedContent])
    }

    // Regression: metadata counts must match full parsing while omitting body and chapter materialization.
    func testMetadataMatchesFullParseForPrefaceAndHeadingFreeFiles() throws {
        let prefaceURL = try makeTemporaryFile(
            named: "with-preface.txt",
            contents: Data("序言\n第一章 开始\n正文一\n第二章 结束\n正文二".utf8)
        )
        let plainURL = try makeTemporaryFile(
            named: "without-headings.txt",
            contents: Data(" 普通内容\n\n尾行 ".utf8)
        )

        let prefaceMetadata = try parser.parseMetadata(url: prefaceURL)
        let prefaceFull = try parser.parse(url: prefaceURL)
        XCTAssertEqual(prefaceMetadata.title, "with-preface")
        XCTAssertEqual(prefaceMetadata.chapterCount, 3)
        XCTAssertEqual(prefaceMetadata.content, "")
        XCTAssertNil(prefaceMetadata.chapters)
        XCTAssertEqual(prefaceFull.chapterCount, 3)
        XCTAssertEqual(prefaceFull.content, "序言\n第一章 开始\n正文一\n第二章 结束\n正文二")
        XCTAssertEqual(prefaceFull.chapters?.map { $0.title }, ["with-preface", "第一章 开始", "第二章 结束"])
        XCTAssertEqual(
            prefaceFull.chapters?.map { $0.content },
            ["序言", "第一章 开始\n正文一", "第二章 结束\n正文二"]
        )

        let plainMetadata = try parser.parseMetadata(url: plainURL)
        let plainFull = try parser.parse(url: plainURL)
        XCTAssertEqual(plainMetadata.title, "without-headings")
        XCTAssertEqual(plainMetadata.chapterCount, 1)
        XCTAssertEqual(plainMetadata.content, "")
        XCTAssertNil(plainMetadata.chapters)
        XCTAssertEqual(plainFull.chapterCount, 1)
        XCTAssertEqual(plainFull.content, "普通内容\n\n尾行")
        XCTAssertEqual(plainFull.chapters?.map { $0.title }, ["without-headings"])
        XCTAssertEqual(plainFull.chapters?.map { $0.content }, ["普通内容\n\n尾行"])
    }

    // Regression: empty and whitespace-only files must report the specific empty-content parser error.
    func testParseAndMetadataRejectEmptyAndWhitespaceOnlyFiles() throws {
        let fixtures: [(name: String, contents: Data)] = [
            ("empty.txt", Data()),
            ("whitespace.txt", Data("\n \t\r\n".utf8)),
        ]

        for fixture in fixtures {
            let fileURL = try makeTemporaryFile(named: fixture.name, contents: fixture.contents)
            assertEmptyContent { _ = try parser.parse(url: fileURL) }
            assertEmptyContent { _ = try parser.parseMetadata(url: fileURL) }
        }
    }

    // Regression: missing files must report cannotRead instead of emptyContent or an unrelated error.
    func testParseAndMetadataRejectMissingFilesWithCannotRead() throws {
        let directoryURL = try makeTemporaryDirectory()
        let missingURL = directoryURL.appendingPathComponent("does-not-exist.txt")

        assertCannotRead { _ = try parser.parse(url: missingURL) }
        assertCannotRead { _ = try parser.parseMetadata(url: missingURL) }
    }

    private func makeTemporaryFile(named name: String, contents: Data) throws -> URL {
        let directoryURL = try makeTemporaryDirectory()
        let fileURL = directoryURL.appendingPathComponent(name)
        try contents.write(to: fileURL)
        return fileURL
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TXTParserTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false,
            attributes: nil
        )
        addTeardownBlock {
            try FileManager.default.removeItem(at: directoryURL)
        }
        return directoryURL
    }

    private func assertEmptyContent(
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            XCTFail("Expected ParseError.emptyContent", file: file, line: line)
        } catch ParseError.emptyContent {
            // Expected parser boundary.
        } catch {
            XCTFail("Expected ParseError.emptyContent, got \(error)", file: file, line: line)
        }
    }

    private func assertCannotRead(
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            XCTFail("Expected ParseError.cannotRead", file: file, line: line)
        } catch ParseError.cannotRead(_) {
            // Expected parser boundary.
        } catch {
            XCTFail("Expected ParseError.cannotRead, got \(error)", file: file, line: line)
        }
    }
}
