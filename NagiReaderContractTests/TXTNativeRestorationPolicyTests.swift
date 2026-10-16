import Foundation
import NagiEngineCore
import XCTest
@testable import Nagi

final class TXTNativeRestorationPolicyTests: XCTestCase {
    private let bookID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
    private let otherBookID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))

    // Falsifier: rejecting endpoints, clamping, or interpreting offsets as Character indices.
    func testMatchingScopeAcceptsStartInteriorAndEOF() throws {
        let document = try ingest("A😀e\u{0301}")
        for offset in [0, 1, 3, 4, 5] {
            let candidate = position(in: document, offset: offset)
            XCTAssertEqual(validate(candidate, in: document), NativeCoordinateValidation.validCoordinate(candidate))
        }
    }

    // Falsifier: accepting any integer, splitting a surrogate, or overflowing bound arithmetic.
    func testSurrogateInteriorAndOutOfBoundsAreUnavailable() throws {
        let document = try ingest("A😀e\u{0301}")
        for offset in [2, -1, 6, Int.min, Int.max] {
            XCTAssertEqual(validate(position(in: document, offset: offset), in: document),
                           NativeCoordinateValidation.unavailable(.invalidStorageBoundary))
        }
    }

    // Falsifier: a caret/grapheme policy moves the legal boundary before the combining mark.
    func testCombiningBoundaryIsNotCaretSnapping() throws {
        let document = try ingest("A😀e\u{0301}")
        let candidate = position(in: document, offset: 4)
        XCTAssertEqual(validate(candidate, in: document), NativeCoordinateValidation.validCoordinate(candidate))
    }

    // Falsifier: comparing only some of the scope or checking coordinate validity before scope.
    func testEveryScopeComponentMustMatch() throws {
        let document = try ingest("abc")
        let scope = document.scope(for: bookID)
        let variants = [
            TXTInputScope(bookID: otherBookID, sourceDigest: scope.sourceDigest,
                          ingestRevision: scope.ingestRevision, manifestDigest: scope.manifestDigest),
            TXTInputScope(bookID: bookID, sourceDigest: "changed-source",
                          ingestRevision: scope.ingestRevision, manifestDigest: scope.manifestDigest),
            TXTInputScope(bookID: bookID, sourceDigest: scope.sourceDigest,
                          ingestRevision: "changed-rules", manifestDigest: scope.manifestDigest),
            TXTInputScope(bookID: bookID, sourceDigest: scope.sourceDigest,
                          ingestRevision: scope.ingestRevision, manifestDigest: "changed-manifest"),
        ]
        for changed in variants {
            for validCoordinate in [true, false] {
                let original = position(in: document, unit: validCoordinate ? "txt-unit:0" : "gone",
                                        node: validCoordinate ? "txt-root" : "wrong",
                                        offset: validCoordinate ? 1 : Int.max)
                let candidate = ScopedNativePosition(scope: changed, position: original.position)
                XCTAssertEqual(validate(candidate, in: document), NativeCoordinateValidation.unavailable(.scopeMismatch))
            }
        }
    }

    // Falsifier: unknown IDs are normalized or offset validation wins over unit/node failures.
    func testMissingUnitPrecedesNodeAndOffsetChecks() throws {
        let document = try ingest("abc")
        for unit in ["gone", "TXT-UNIT:0", "txt-unit:0 "] {
            let candidate = position(in: document, unit: unit, node: "wrong", offset: Int.max)
            XCTAssertEqual(validate(candidate, in: document), NativeCoordinateValidation.unavailable(.unknownUnit))
        }
        for node in ["wrong", "TXT-ROOT", "txt-root "] {
            for offset in [1, Int.max] {
                let candidate = position(in: document, node: node, offset: offset)
                XCTAssertEqual(validate(candidate, in: document), NativeCoordinateValidation.unavailable(.unknownNode))
            }
        }
    }

    // Falsifier: identical canonical text or ordinal is mistaken for identical captured input.
    func testBOMChangeRejectsIdenticalManifestCoordinates() throws {
        let before = try ingest("abc")
        let after = try ingest("\u{FEFF}abc")
        XCTAssertEqual(before.manifestDigest, after.manifestDigest)
        XCTAssertNotEqual(before.sourceDigest, after.sourceDigest)
        XCTAssertEqual(validate(position(in: before, offset: 1), in: after),
                       NativeCoordinateValidation.unavailable(.scopeMismatch))
    }

    // Falsifier: validating every unit against the first chapter, or using full-book offsets.
    func testRepeatedUnitsUseTheirOwnTextAxis() throws {
        let document = try ingest("第一章\na\n第一章\n😀😀😀")
        XCTAssertEqual(document.units.map { $0.chapter.content }, ["第一章\na", "第一章\n😀😀😀"])
        let offset = "第一章\n😀😀😀".utf16.count
        XCTAssertGreaterThan(offset, "第一章\na".utf16.count)
        let second = position(in: document, unit: "txt-unit:1", offset: offset)
        XCTAssertEqual(validate(second, in: document), NativeCoordinateValidation.validCoordinate(second))
        XCTAssertEqual(validate(position(in: document, offset: offset), in: document),
                       NativeCoordinateValidation.unavailable(.invalidStorageBoundary))
    }

    // Falsifier: deriving the expected book ID from the candidate instead of the caller's record.
    func testDifferentBookRecordIsNotTheSameScope() throws {
        let document = try ingest("abc")
        let candidate = position(in: document, offset: 1)
        XCTAssertEqual(TXTNativeRestorationPolicy.validate(candidate, in: document, bookID: otherBookID),
                       NativeCoordinateValidation.unavailable(.scopeMismatch))
    }

    // Falsifier: reopening a source URL replaces the captured text with a shorter new file.
    func testValidationDoesNotReopenTheSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativeCoordinate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("input.txt")
        try Data("alpha".utf8).write(to: url)
        let snapshot = try TXTSourceSnapshot.read(at: url)
        try Data("b".utf8).write(to: url)
        let document = try TXTIngestDocument(snapshot: snapshot, fallbackTitle: "书")
        XCTAssertEqual(try Data(contentsOf: url), Data("b".utf8))
        let candidate = position(in: document, offset: "alpha".utf16.count)
        XCTAssertEqual(validate(candidate, in: document), NativeCoordinateValidation.validCoordinate(candidate))
    }

    // Falsifier: this narrow coordinate validator starts claiming to be strict native admission.
    func testLossyArtifactValidationIsNotAnAdmissionToken() throws {
        let document = try TXTIngestDocument(snapshot: TXTSourceSnapshot(copying: Data([0xFF])), fallbackTitle: "书")
        XCTAssertTrue(document.decoding.usedLossyUTF8Fallback)
        XCTAssertFalse(document.decoding.didDecode)
        XCTAssertEqual(document.units.map { $0.chapter.content }, ["\u{FFFD}"])
        let candidate = position(in: document, offset: 1)
        XCTAssertEqual(validate(candidate, in: document), NativeCoordinateValidation.validCoordinate(candidate))
    }

    private func ingest(_ text: String) throws -> TXTIngestDocument {
        try TXTIngestDocument(snapshot: TXTSourceSnapshot(copying: Data(text.utf8)), fallbackTitle: "书")
    }

    private func position(in document: TXTIngestDocument, unit: String = "txt-unit:0",
                          node: String = "txt-root", offset: Int) -> ScopedNativePosition {
        ScopedNativePosition(scope: document.scope(for: bookID),
                             position: NativePosition(unitID: DocumentUnitID(rawValue: unit),
                                                      nodeID: NodeID(rawValue: node), utf16Offset: offset))
    }

    private func validate(_ candidate: ScopedNativePosition, in document: TXTIngestDocument) -> NativeCoordinateValidation {
        TXTNativeRestorationPolicy.validate(candidate, in: document, bookID: bookID)
    }
}
