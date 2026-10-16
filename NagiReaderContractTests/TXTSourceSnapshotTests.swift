import Foundation
import XCTest
@testable import Nagi

final class TXTSourceSnapshotTests: XCTestCase {
    // Catches confusing empty input with a selected decoder or a failed decode.
    func testEmptyInputHasNoSelectedEncoding() {
        let result = TXTSourceSnapshot(copying: Data()).decoded
        XCTAssertEqual(result.text, "")
        XCTAssertNil(result.encoding)
        XCTAssertEqual(result.method, TXTDecodingMethod.empty)
        XCTAssertTrue(result.didDecode)
        XCTAssertFalse(result.usedLossyUTF8Fallback)
    }

    // Catches decoding provenance changing Unicode or pretending an interior FEFF is a BOM.
    func testStrictUTF8PreservesRawScalarsBeforePreparation() {
        let result = TXTSourceSnapshot(copying: Data("中😀e\u{0301}\u{FEFF}\r\n".utf8)).decoded
        XCTAssertEqual(result.text.unicodeScalars.map(\.value), [0x4E2D, 0x1F600, 0x65, 0x301, 0xFEFF, 0xD, 0xA])
        XCTAssertEqual(result.encoding, TXTTextEncoding.utf8)
        XCTAssertEqual(result.method, TXTDecodingMethod.utf8)
        XCTAssertTrue(result.didDecode)
        XCTAssertFalse(result.usedLossyUTF8Fallback)
    }

    // Catches BOM precedence (especially UTF32LE vs UTF16LE) or reporting a fallback as BOM.
    func testEveryAuthoritativeBOMReportsItsActualDecoder() {
        let cases: [(bytes: [UInt8], encoding: TXTTextEncoding)] = [
            ([0xEF, 0xBB, 0xBF, 0x41], .utf8),
            ([0xFF, 0xFE, 0x41, 0x00], .utf16LittleEndian),
            ([0xFE, 0xFF, 0x00, 0x41], .utf16BigEndian),
            ([0xFF, 0xFE, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00], .utf32LittleEndian),
            ([0x00, 0x00, 0xFE, 0xFF, 0x00, 0x00, 0x00, 0x41], .utf32BigEndian),
        ]
        for item in cases {
            let result = TXTSourceSnapshot(copying: Data(item.bytes)).decoded
            XCTAssertEqual(result.text, "A")
            XCTAssertEqual(result.encoding, item.encoding)
            XCTAssertEqual(result.method, TXTDecodingMethod.byteOrderMark)
            XCTAssertTrue(result.didDecode)
            XCTAssertFalse(result.usedLossyUTF8Fallback)
        }
    }

    // Catches falling through after a malformed authoritative BOM or claiming success for it.
    func testMalformedUTF8BOMIsRecordedAsFailedWithoutLossyFallback() {
        let result = TXTSourceSnapshot(copying: Data([0xEF, 0xBB, 0xBF, 0xFF])).decoded
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.encoding, TXTTextEncoding.utf8)
        XCTAssertEqual(result.method, TXTDecodingMethod.byteOrderMark)
        XCTAssertFalse(result.didDecode)
        XCTAssertFalse(result.usedLossyUTF8Fallback)
    }

    // Catches inferring decode failure from an empty result instead of the strict initializer.
    func testBOMOnlyInputIsSuccessfulEmptyDecoding() {
        let result = TXTSourceSnapshot(copying: Data([0xEF, 0xBB, 0xBF])).decoded
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.encoding, TXTTextEncoding.utf8)
        XCTAssertEqual(result.method, TXTDecodingMethod.byteOrderMark)
        XCTAssertTrue(result.didDecode)
        XCTAssertFalse(result.usedLossyUTF8Fallback)
    }

    // Catches losing endianness or labeling a heuristic result as BOM/UTF8.
    func testUTF16NULHeuristicsReportTheirSelectedEndianness() {
        let cases: [(bytes: [UInt8], encoding: TXTTextEncoding)] = [
            ([0x41, 0, 0x42, 0, 0x43, 0, 0x44, 0, 0x2D, 0x4E], .utf16LittleEndian),
            ([0, 0x41, 0, 0x42, 0, 0x43, 0, 0x44, 0x4E, 0x2D], .utf16BigEndian),
        ]
        for item in cases {
            let result = TXTSourceSnapshot(copying: Data(item.bytes)).decoded
            XCTAssertEqual(result.text, "ABCD中")
            XCTAssertEqual(result.encoding, item.encoding)
            XCTAssertEqual(result.method, TXTDecodingMethod.nulHeuristic)
            XCTAssertTrue(result.didDecode)
            XCTAssertFalse(result.usedLossyUTF8Fallback)
        }
    }

    // Catches detecting UTF16 before UTF32, or losing non-BMP text in the selected route.
    func testUTF32NULHeuristicsReportTheirSelectedEndianness() {
        let cases: [(bytes: [UInt8], encoding: TXTTextEncoding)] = [
            ([0x41, 0, 0, 0, 0x2D, 0x4E, 0, 0, 0, 0xF6, 1, 0, 0xA, 0, 0, 0], .utf32LittleEndian),
            ([0, 0, 0, 0x41, 0, 0, 0x4E, 0x2D, 0, 1, 0xF6, 0, 0, 0, 0, 0xA], .utf32BigEndian),
        ]
        for item in cases {
            let result = TXTSourceSnapshot(copying: Data(item.bytes)).decoded
            XCTAssertEqual(result.text.unicodeScalars.map(\.value), [0x41, 0x4E2D, 0x1F600, 0xA])
            XCTAssertEqual(result.encoding, item.encoding)
            XCTAssertEqual(result.method, TXTDecodingMethod.nulHeuristic)
            XCTAssertTrue(result.didDecode)
        }
    }

    // Catches recording an attempted heuristic that failed, rather than the decoder actually used.
    func testRejectedUTF32CandidateFallsThroughToActualUTF8Result() {
        let bytes: [UInt8] = [0, 0, 0x11, 0, 0x41, 0, 0, 0, 0x42, 0, 0, 0, 0x43, 0, 0, 0]
        let result = TXTSourceSnapshot(copying: Data(bytes)).decoded
        XCTAssertEqual(result.text, "\u{0}\u{0}\u{11}\u{0}A\u{0}\u{0}\u{0}B\u{0}\u{0}\u{0}C\u{0}\u{0}\u{0}")
        XCTAssertEqual(result.encoding, TXTTextEncoding.utf8)
        XCTAssertEqual(result.method, TXTDecodingMethod.utf8)
        XCTAssertTrue(result.didDecode)
        XCTAssertFalse(result.usedLossyUTF8Fallback)
    }

    // Catches dropping legacy GB18030 or mislabeling its four-byte result as lossy UTF8.
    func testGB18030TwoAndFourByteMappingsAreNotLossyUTF8Fallback() {
        let cases: [(bytes: [UInt8], scalars: [UInt32])] = [
            ([0xD6, 0xD0, 0xCE, 0xC4], [0x4E2D, 0x6587]),
            ([0x81, 0x30, 0x81, 0x30], [0x80]),
        ]
        for item in cases {
            let result = TXTSourceSnapshot(copying: Data(item.bytes)).decoded
            XCTAssertEqual(result.text.unicodeScalars.map(\.value), item.scalars)
            XCTAssertEqual(result.encoding, TXTTextEncoding.gb18030)
            XCTAssertEqual(result.method, TXTDecodingMethod.gb18030)
            XCTAssertTrue(result.didDecode)
            XCTAssertFalse(result.usedLossyUTF8Fallback)
        }
    }

    // Catches hiding replacement decoding behind a strict UTF8/GB18030 success label.
    func testFinalReplacementFallbackIsExplicit() {
        let result = TXTSourceSnapshot(copying: Data([0xFF])).decoded
        XCTAssertEqual(result.text.unicodeScalars.map(\.value), [0xFFFD])
        XCTAssertEqual(result.encoding, TXTTextEncoding.utf8)
        XCTAssertEqual(result.method, TXTDecodingMethod.lossyUTF8)
        XCTAssertTrue(result.didDecode)
        XCTAssertTrue(result.usedLossyUTF8Fallback)
    }

    // Catches ordinary Data COW being mistaken for ownership of externally backed bytes.
    func testSnapshotCopiesExternallyOwnedMutableBytes() {
        let count = 256 // Larger than Data's small inline representation.
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 1)
        buffer.initializeMemory(as: UInt8.self, repeating: 0x61, count: count)
        defer { buffer.deallocate() }
        let borrowed = Data(bytesNoCopy: buffer, count: count, deallocator: .none)
        let snapshot = TXTSourceSnapshot(copying: borrowed)
        buffer.storeBytes(of: UInt8(0x62), as: UInt8.self)
        XCTAssertEqual(borrowed.first, UInt8(0x62), "Fixture must really retain the external buffer")
        XCTAssertEqual(snapshot.bytes, Data(repeating: 0x61, count: count))
        XCTAssertEqual(snapshot.decoded.text, String(repeating: "a", count: count))
    }

    // Catches retaining a path/mapped file and reopening it instead of decoding captured bytes.
    func testFileSnapshotSurvivesSourceReplacementAndDeletion() throws {
        let url = try temporaryFile(Data("原文😀e\u{301}".utf8))
        let snapshot = try TXTSourceSnapshot.read(at: url)
        try Data("改写后的内容".utf8).write(to: url)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(snapshot.bytes, Data("原文😀e\u{301}".utf8))
        XCTAssertEqual(snapshot.decoded.text.unicodeScalars.map(\.value), [0x539F, 0x6587, 0x1F600, 0x65, 0x301])
    }

    // Catches diverging preparation rules or accidental canonical Unicode/XML normalization.
    func testPreparationUsesExistingRulesWithoutMutatingRawDecode() throws {
        let input = " \t\u{FEFF}甲<&>😀e\u{301}\r\n\r乙\u{FEFF}\u{2028}\u{2029}丙\u{85}丁 \n"
        let snapshot = TXTSourceSnapshot(copying: Data(input.utf8))
        let prepared = try snapshot.preparedText()
        let expected = "甲<&>😀e\u{301}\n\n乙\n\n丙\n丁"
        XCTAssertEqual(prepared.unicodeScalars.map(\.value), expected.unicodeScalars.map(\.value))
        XCTAssertEqual(snapshot.decoded.text.unicodeScalars.map(\.value), input.unicodeScalars.map(\.value))
        XCTAssertEqual(snapshot.bytes, Data(input.utf8))
    }

    // Catches replacing the existing emptyContent/cannotRead error contract with a new error layer.
    func testPreparationAndReadPreserveExistingErrorCases() throws {
        for data in [Data(), Data(" \t\r\n\u{FEFF}".utf8), Data([0xEF, 0xBB, 0xBF, 0xFF])] {
            XCTAssertThrowsError(try TXTSourceSnapshot(copying: data).preparedText()) { error in
                guard case ParseError.emptyContent = error else {
                    return XCTFail("Expected emptyContent, got \(error)")
                }
            }
        }
        let missing = try temporaryFile(Data())
        try FileManager.default.removeItem(at: missing)
        XCTAssertThrowsError(try TXTSourceSnapshot.read(at: missing)) { error in
            guard case ParseError.cannotRead = error else {
                return XCTFail("Expected cannotRead, got \(error)")
            }
        }
    }

    private func temporaryFile(_ data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TXTSourceSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.txt")
        try data.write(to: url)
        return url
    }
}
