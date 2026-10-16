import Foundation
import XCTest
@testable import Nagi

final class TXTChapterPartitionTests: XCTestCase {
    // Falsifier: storing the whole segment as content loses the discarded edges.
    func testFallbackRecordsTrimmedContentInsideItsWholeSegment() throws {
        let partition = TXTChapterPartition(text: " \t正文😀 \n", fallbackTitle: "书")
        let unit = try XCTUnwrap(partition.units.first)
        XCTAssertEqual(partition.units.count, 1)
        XCTAssertEqual(unit.chapter.title, "书")
        XCTAssertEqual(unit.chapter.content, "正文😀")
        XCTAssertEqual(unit.segmentUTF16Range, 0..<8)
        XCTAssertEqual(unit.contentUTF16Range, 2..<6)
        assertExactSlices(partition)
    }

    // Falsifier: creating a fallback unconditionally invents an empty chapter.
    func testEmptyAndWhitespaceOnlyInputsHaveNoUnits() {
        for text in ["", " \t\r\n\u{2028}"] {
            XCTAssertTrue(TXTChapterPartition(text: text, fallbackTitle: "书").units.isEmpty)
        }
    }

    // Falsifier: accumulating trimmed chapter lengths puts the heading inside the gap.
    func testPrefaceAndHeadingKeepTheDiscardedGapInSourceCoordinates() throws {
        let partition = TXTChapterPartition(text: " 前言 \n\n第一章\n正文 \n", fallbackTitle: "序")
        XCTAssertEqual(partition.units.count, 2)
        let preface = try XCTUnwrap(partition.units.first)
        let chapter = try XCTUnwrap(partition.units.dropFirst().first)
        XCTAssertEqual(preface.chapter.content, "前言")
        XCTAssertEqual(preface.segmentUTF16Range, 0..<6)
        XCTAssertEqual(preface.contentUTF16Range, 1..<3)
        XCTAssertEqual(chapter.segmentUTF16Range, 6..<14)
        XCTAssertEqual(chapter.contentUTF16Range, 6..<12)
        XCTAssertEqual(chapter.chapter.content, "第一章\n正文")
        XCTAssertNotEqual(chapter.contentUTF16Range.lowerBound, preface.chapter.content.utf16.count)
        assertExactSlices(partition)
    }

    // Falsifier: range(of: content) maps the second identical chapter to the first.
    func testRepeatedIdenticalChaptersKeepDistinctRanges() {
        let partition = TXTChapterPartition(text: "第一章\n同文\n第一章\n同文", fallbackTitle: "书")
        XCTAssertEqual(partition.units.map { $0.chapter.content }, ["第一章\n同文", "第一章\n同文"])
        XCTAssertEqual(partition.units.map { $0.segmentUTF16Range }, [0..<7, 7..<13])
        XCTAssertEqual(partition.units.map { $0.contentUTF16Range }, [0..<6, 7..<13])
        assertExactSlices(partition)
    }

    // Falsifier: Character/UTF-8 offsets shift the second heading after an emoji.
    func testNonBMPPrefaceUsesUTF16RatherThanCharactersOrBytes() {
        let partition = TXTChapterPartition(text: "😀\n第一章\n中", fallbackTitle: "序")
        XCTAssertEqual(partition.units.map { $0.contentUTF16Range }, [0..<2, 3..<8])
        XCTAssertEqual(partition.units.map { $0.chapter.content }, ["😀", "第一章\n中"])
        assertExactSlices(partition)
    }

    // Falsifier: normalization or grapheme-count offsets erase the decomposed mark.
    func testDecomposedScalarsAndWhitespaceBeforeCombiningMarksArePreserved() throws {
        let partition = TXTChapterPartition(text: " \u{0301}e\u{0301}\n第一章", fallbackTitle: "序")
        let preface = try XCTUnwrap(partition.units.first)
        XCTAssertEqual(preface.chapter.content.unicodeScalars.map { $0.value }, [0x301, 0x65, 0x301])
        XCTAssertEqual(partition.units.map { $0.contentUTF16Range }, [1..<4, 5..<8])
        assertExactSlices(partition)
    }

    // Falsifier: storing offsets into the original CRLF input reports the wrong stream.
    func testRangesBelongToTheOwnedLFNormalizedText() {
        let partition = TXTChapterPartition(text: "前\r\n第一章\u{2028}甲\r第二章\u{0085}乙\u{2029}", fallbackTitle: "序")
        XCTAssertEqual(partition.normalizedText, "前\n第一章\n甲\n第二章\n乙\n")
        XCTAssertEqual(partition.units.map { $0.contentUTF16Range }, [0..<1, 2..<7, 8..<13])
        assertExactSlices(partition)
    }

    // Falsifier: excluding title lines or dropping empty bodies loses heading-only units.
    func testConsecutiveAndFinalHeadingOnlyUnitsKeepOneTitleLine() {
        let partition = TXTChapterPartition(text: "第一章\n第二章\n第三章", fallbackTitle: "书")
        XCTAssertEqual(partition.units.map { $0.chapter.content }, ["第一章", "第二章", "第三章"])
        XCTAssertEqual(partition.units.map { $0.contentUTF16Range }, [0..<3, 4..<7, 8..<11])
        assertExactSlices(partition)
    }

    // Falsifier: treating direct compatibility input as prepared source deletes body FEFF.
    func testDirectPartitionKeepsBodyFEFFWhilePreparedSourceRemovesIt() throws {
        let input = "\u{FEFF}第一章\n内\u{FEFF}文"
        let direct = TXTChapterPartition(text: input, fallbackTitle: "书")
        XCTAssertEqual(direct.units.map { $0.chapter.title }, ["第一章"])
        XCTAssertEqual(direct.units.map { $0.chapter.content }, [input])
        XCTAssertEqual(direct.units.map { $0.contentUTF16Range }, [0..<8])
        let prepared = try TXTSourceSnapshot(copying: Data(input.utf8)).preparedText()
        let source = TXTChapterPartition(text: prepared, fallbackTitle: "书")
        XCTAssertEqual(source.units.map { $0.chapter.content }, ["第一章\n内文"])
        XCTAssertEqual(source.units.map { $0.contentUTF16Range }, [0..<6])
        assertExactSlices(direct)
        assertExactSlices(source)
    }

    // Falsifier: replacing the heading's Character limit with utf16.count rejects a valid title.
    func testHeadingLimitCountsCharactersNotUTF16Units() {
        let accepted = "Chapter 1 " + String(repeating: "😀", count: 70)
        let rejected = "Chapter 2 " + String(repeating: "e\u{0301}", count: 71)
        let text = accepted + "\n正文\n" + rejected
        let partition = TXTChapterPartition(text: text, fallbackTitle: "书")
        XCTAssertEqual(accepted.count, 80)
        XCTAssertEqual(rejected.count, 81)
        XCTAssertEqual(partition.units.map { $0.chapter.title }, [accepted])
        XCTAssertEqual(partition.units.map { $0.chapter.content }, [text])
        assertExactSlices(partition)
    }

    // Falsifier: including whitespace-only preface invents a spurious unit.
    func testWhitespaceOnlyPrefaceIsDiscardedWithoutRebasingTheFirstHeading() {
        let partition = TXTChapterPartition(text: " \n\t\n第一章\n正文", fallbackTitle: "书")
        XCTAssertEqual(partition.units.map { $0.chapter.title }, ["第一章"])
        XCTAssertEqual(partition.units.map { $0.segmentUTF16Range }, [4..<10])
        XCTAssertEqual(partition.units.map { $0.contentUTF16Range }, [4..<10])
        assertExactSlices(partition)
    }

    // Falsifier: a separate splitter drifts from the unit content consumed by the EPUB path.
    func testLegacyProjectionMatchesExplicitChapterContents() {
        let text = "序言\n1、开篇\n甲\n二．继续\n乙"
        let partition = TXTChapterPartition(text: text, fallbackTitle: "书")
        let legacy = TXTParser.splitIntoChapters(text, fallbackTitle: "书")
        let titles = ["书", "1、开篇", "二．继续"]
        let contents = ["序言", "1、开篇\n甲", "二．继续\n乙"]
        XCTAssertEqual(partition.units.map { $0.chapter.title }, titles)
        XCTAssertEqual(partition.units.map { $0.chapter.content }, contents)
        XCTAssertEqual(legacy.map { $0.title }, titles)
        XCTAssertEqual(legacy.map { $0.content }, contents)
        assertExactSlices(partition)
    }

    private func assertExactSlices(
        _ partition: TXTChapterPartition,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let codeUnits = Array(partition.normalizedText.utf16)
        var previousEnd = 0
        for unit in partition.units {
            let segment = unit.segmentUTF16Range
            let content = unit.contentUTF16Range
            XCTAssertGreaterThanOrEqual(segment.lowerBound, previousEnd, file: file, line: line)
            XCTAssertLessThanOrEqual(segment.upperBound, codeUnits.count, file: file, line: line)
            XCTAssertGreaterThanOrEqual(content.lowerBound, segment.lowerBound, file: file, line: line)
            XCTAssertLessThanOrEqual(content.upperBound, segment.upperBound, file: file, line: line)
            guard content.lowerBound >= 0, content.upperBound <= codeUnits.count else { continue }
            XCTAssertEqual(
                String(decoding: codeUnits[content], as: UTF16.self).unicodeScalars.map { $0.value },
                unit.chapter.content.unicodeScalars.map { $0.value }, file: file, line: line
            )
            previousEnd = segment.upperBound
        }
    }
}
