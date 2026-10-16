import Foundation
import XCTest
@testable import Nagi

final class TXTIngestDocumentTests: XCTestCase {
    private let bookID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))

    // Falsifier: omitting the domain/version/revision/count changes these independently framed bytes.
    func testEmptyManifestHasAnExactVersionedPreimageAndDigest() {
        var bytes = Data()
        TXTIngestDocument.encodeManifest(revision: "r1", records: []) { bytes.append($0) }
        XCTAssertEqual(bytes.count, 51)
        XCTAssertEqual(hex(bytes), "00000000000000116e6167692e7478742e6d616e69666573740000000000000001000000000000000272310000000000000000")
        XCTAssertEqual(TXTIngestDocument.fingerprint(revision: "r1", records: []),
                       "308602c66b46079cb80e224967d7f1b7b90f083dcb99c7328fb86aa09c35eed8")
    }

    // Falsifier: UTF-16/Character lengths, little endian, normalization or a different field order.
    func testUnicodeManifestPinsEveryEmittedByteAndItsSHA256() {
        let records: [TXTIngestDocument.ManifestRecord] = [("txt-unit:0", "txt-root", "A中😀e\u{0301}")]
        var bytes = Data()
        TXTIngestDocument.encodeManifest(revision: "r1", records: records) { bytes.append($0) }
        XCTAssertEqual(bytes.count, 104)
        XCTAssertEqual(hex(bytes), "00000000000000116e6167692e7478742e6d616e69666573740000000000000001000000000000000272310000000000000001000000000000000a7478742d756e69743a3000000000000000087478742d726f6f74000000000000000b41e4b8adf09f988065cc81")
        XCTAssertEqual(TXTIngestDocument.fingerprint(revision: "r1", records: records),
                       "54a77f6e002e7bc15ea3e0ed338a9787a0b0522de51cdb3e15399d0bfc0a817f")
    }

    // Characterization: truncating lengths to their low byte corrupts 256 and 257;
    // little endian breaks the complete preimage. Oracles use Python struct >Q + hashlib,
    // independently of the Swift encoder; the literal body byte is ASCII 0x61.
    func testFieldLengthsCarryIntoTheNextByteWithoutTruncation() {
        let fixtures: [(count: Int, lengthHex: String, digest: String)] = [
            (255, "00000000000000ff", "f8746d35130458b8c6dde8007591769da834fe9a5af235c646f50502be52f647"),
            (256, "0000000000000100", "e3474c7edc0f3102fdb4b231a9f551038ad47b9789a66c3d8c18add4fe3311c7"),
            (257, "0000000000000101", "a37cf37ccfa12bf45e268d4b3b26b8f96314e95b3faca51cf48b5e8633bd459e"),
        ]
        let headerHex = "00000000000000116e6167692e7478742e6d616e6966657374000000000000000100000000000000027231000000000000000100000000000000017500000000000000016e"
        for fixture in fixtures {
            let text = String(repeating: "a", count: fixture.count)
            let records: [TXTIngestDocument.ManifestRecord] = [("u", "n", text)]
            var bytes = Data()
            TXTIngestDocument.encodeManifest(revision: "r1", records: records) { bytes.append($0) }
            XCTAssertEqual(hex(bytes), headerHex + fixture.lengthHex + String(repeating: "61", count: fixture.count))
            XCTAssertEqual(TXTIngestDocument.fingerprint(revision: "r1", records: records), fixture.digest)
        }
    }

    // Characterization: counting Characters/UTF-16 instead of UTF-8 would emit 86, not 258.
    func testMultibyteFieldUsesItsWideUTF8ByteLength() {
        let records: [TXTIngestDocument.ManifestRecord] = [("u", "n", String(repeating: "中", count: 86))]
        var bytes = Data()
        TXTIngestDocument.encodeManifest(revision: "r1", records: records) { bytes.append($0) }
        let headerHex = "00000000000000116e6167692e7478742e6d616e6966657374000000000000000100000000000000027231000000000000000100000000000000017500000000000000016e0000000000000102"
        XCTAssertEqual(hex(bytes), headerHex + String(repeating: "e4b8ad", count: 86))
        XCTAssertEqual(TXTIngestDocument.fingerprint(revision: "r1", records: records),
                       "87ede0afd24db5e18cc666084b9fc746bc215b653c1928cd0102c33942bccdef")
    }

    // Characterization: the separate record-count framing must also retain high bytes.
    func testManifestRecordCountCarriesIntoTheNextByte() {
        let records = Array<TXTIngestDocument.ManifestRecord>(repeating: ("u", "n", ""), count: 256)
        var bytes = Data()
        TXTIngestDocument.encodeManifest(revision: "r1", records: records) { bytes.append($0) }
        let headerHex = "00000000000000116e6167692e7478742e6d616e69666573740000000000000001000000000000000272310000000000000100"
        let recordHex = "00000000000000017500000000000000016e0000000000000000"
        XCTAssertEqual(hex(bytes), headerHex + String(repeating: recordHex, count: 256))
        XCTAssertEqual(TXTIngestDocument.fingerprint(revision: "r1", records: records),
                       "ab8df2bec527b567111b463673c9c9d24387c3757e9d5de4acb507678193626c")
    }

    // Falsifier: dropping empty fields conflates an empty record with an absent record.
    func testEmptyFieldsStillCarryTheirThreeLengthPrefixes() {
        var bytes = Data()
        TXTIngestDocument.encodeManifest(revision: "r1", records: [("", "", "")]) { bytes.append($0) }
        XCTAssertEqual(hex(bytes), "00000000000000116e6167692e7478742e6d616e69666573740000000000000001000000000000000272310000000000000001000000000000000000000000000000000000000000000000")
        XCTAssertNotEqual(TXTIngestDocument.fingerprint(revision: "r1", records: [("", "", "")]),
                          TXTIngestDocument.fingerprint(revision: "r1", records: []))
    }

    // Falsifier: ignoring any unit field, record count/order or ingest revision aliases different inputs.
    func testFingerprintDependsOnEveryIdentityTextOrderAndRevisionField() {
        let records: [TXTIngestDocument.ManifestRecord] = [
            ("txt-unit:0", "txt-root", "a"), ("txt-unit:1", "txt-root", "bc"),
        ]
        let original = TXTIngestDocument.fingerprint(revision: "r1", records: records)
        XCTAssertEqual(original, "d26c2e4c981957b511c88d2e4e9dc09eccb9f4e69fa07c5d342ffc4aed9d85bf")
        let variants: [[TXTIngestDocument.ManifestRecord]] = [
            [("other", "txt-root", "a"), records[1]],
            [("txt-unit:0", "other", "a"), records[1]],
            [("txt-unit:0", "txt-root", "b"), records[1]],
            [records[1], records[0]],
            [records[0]],
        ]
        for variant in variants {
            XCTAssertNotEqual(TXTIngestDocument.fingerprint(revision: "r1", records: variant), original)
        }
        XCTAssertNotEqual(TXTIngestDocument.fingerprint(revision: "r2", records: records), original)
    }

    // Falsifier: hashing decoded text, using whole-book text as units or guessing trimmed offsets.
    func testOneCaptureProducesKnownDigestsProvenanceUnitsAndRanges() throws {
        let document = try ingest(" \u{FEFF}前言\r\n\r\n第一章\r\n😀e\u{0301} \r\n")
        XCTAssertEqual(document.sourceDigest, "0556c365e199e675ad5537bad8b893fe1b709d5b04e277424c6000d95ffd06f6")
        XCTAssertEqual(document.manifestDigest, "c4fc0d5b9af1c2b0a11feb1873954b7d4a4836672f6dfe699f1c834aa90508bd")
        XCTAssertEqual(document.decoding.encoding, TXTTextEncoding.utf8)
        XCTAssertEqual(document.decoding.method, TXTDecodingMethod.utf8)
        XCTAssertTrue(document.decoding.didDecode)
        XCTAssertEqual(document.partition.normalizedText, "前言\n\n第一章\n😀e\u{0301}")
        XCTAssertEqual(document.units.map { $0.unitID }, ["txt-unit:0", "txt-unit:1"])
        XCTAssertEqual(document.units.map { $0.nodeID }, ["txt-root", "txt-root"])
        XCTAssertEqual(document.units.map { $0.chapter.content }, ["前言", "第一章\n😀e\u{0301}"])
        XCTAssertEqual(document.units.map { $0.segmentUTF16Range }, [0..<4, 4..<12])
        XCTAssertEqual(document.units.map { $0.contentUTF16Range }, [0..<2, 4..<12])
        let scope = document.scope(for: bookID)
        XCTAssertEqual(scope.bookID, bookID)
        XCTAssertEqual(scope.ingestRevision, "nagi-txt-ingest-v1")
        XCTAssertEqual(scope.sourceDigest, document.sourceDigest)
        XCTAssertEqual(scope.manifestDigest, document.manifestDigest)
    }

    // Falsifier: hashing prepared text silently strips the authoritative source BOM from identity.
    func testBOMChangesSourceScopeEvenWhenTheManifestTextIsIdentical() throws {
        let plain = try ingest("abc")
        let marked = try ingest("\u{FEFF}abc")
        XCTAssertEqual(plain.sourceDigest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(marked.sourceDigest, "1c28dc3f1f804a1ad9c9b4b4cf5e2658d16ad4ed08e3020d04a8d2865018947c")
        XCTAssertEqual(plain.manifestDigest, "d98780eeb55806adcd8a904a63a046c983fee00927bb43a0f5677ee91c9d9a04")
        XCTAssertEqual(marked.manifestDigest, plain.manifestDigest)
        XCTAssertEqual(marked.decoding.method, TXTDecodingMethod.byteOrderMark)
        XCTAssertNotEqual(marked.scope(for: bookID), plain.scope(for: bookID))
    }

    // Falsifier: canonical equivalence is incorrectly treated as identical captured bytes.
    func testNewlineNormalizationDoesNotEraseSourceVersionChanges() throws {
        let lf = try ingest("a\nb")
        let crlf = try ingest("a\r\nb")
        XCTAssertEqual(lf.units.map { $0.chapter.content }, ["a\nb"])
        XCTAssertEqual(crlf.units.map { $0.chapter.content }, ["a\nb"])
        XCTAssertEqual(lf.manifestDigest.count, 64)
        XCTAssertEqual(lf.manifestDigest, crlf.manifestDigest)
        XCTAssertNotEqual(lf.sourceDigest, crlf.sourceDigest)
        XCTAssertNotEqual(lf.scope(for: bookID), crlf.scope(for: bookID))
    }

    // Falsifier: filename/fallback display title leaks into the manifest or source scope.
    func testRenamedSourceFilesKeepTheSameScopeAndDifferentDisplayTitles() throws {
        let directory = try makeDirectory()
        let oldURL = directory.appendingPathComponent("old.txt")
        let newURL = directory.appendingPathComponent("new.text")
        try Data("abc".utf8).write(to: oldURL)
        let before = try TXTIngestDocument.read(at: oldURL)
        try FileManager.default.moveItem(at: oldURL, to: newURL)
        let after = try TXTIngestDocument.read(at: newURL)
        XCTAssertEqual(before.units.map { $0.chapter.title }, ["old"])
        XCTAssertEqual(after.units.map { $0.chapter.title }, ["new"])
        XCTAssertEqual(before.sourceDigest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(before.manifestDigest, "d98780eeb55806adcd8a904a63a046c983fee00927bb43a0f5677ee91c9d9a04")
        XCTAssertEqual(before.scope(for: bookID), after.scope(for: bookID))
    }

    // Falsifier: using only content digests makes separate library records the same input scope.
    func testIdenticalBytesInDifferentBookRecordsHaveDifferentScopes() throws {
        let document = try ingest("abc")
        let otherID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))
        XCTAssertEqual(document.sourceDigest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertNotEqual(document.scope(for: bookID), document.scope(for: otherID))
    }

    // Falsifier: raw concatenation would make both identity-field splits emit "abc".
    func testFieldBoundariesCannotAliasTheSameConcatenatedText() {
        let lhs = TXTIngestDocument.fingerprint(revision: "r1", records: [("a", "bc", "")])
        let rhs = TXTIngestDocument.fingerprint(revision: "r1", records: [("ab", "c", "")])
        XCTAssertEqual(lhs.count, 64)
        XCTAssertNotEqual(lhs, rhs)
    }

    // Falsifier: Swift String canonical equality must not become NFC normalization of digest bytes.
    func testCanonicallyEquivalentStringsKeepTheirExactUTF8Identity() throws {
        let composed = try ingest("\u{00E9}")
        let decomposed = try ingest("e\u{0301}")
        XCTAssertEqual(composed.decoding.text, decomposed.decoding.text)
        XCTAssertEqual(composed.sourceDigest, "4a99557e4033c3539de2eb65472017cad5f9557f7a0625a09f1c3f6e2ba69c4c")
        XCTAssertEqual(decomposed.sourceDigest, "bf12767b0f2a56b2190075bae8169f656e3ce8d6357d4aff184bc6c7ea48f9f6")
        XCTAssertEqual(composed.manifestDigest, "c35d28e70c133bda4e265df6d5457960e1bdd1130a0d7d3dc4cdaacae7eabf93")
        XCTAssertEqual(decomposed.manifestDigest, "d3cb076795afb8980fdaa2aed4e49a250a39f34f06db796207924e4e48768752")
        XCTAssertNotEqual(composed.scope(for: bookID), decomposed.scope(for: bookID))
    }

    // Falsifier: reopening a URL for decode/hash sees beta rather than the captured alpha.
    func testSourceOverwriteCannotChangeTheCapturedDocument() throws {
        let url = try makeDirectory().appendingPathComponent("input.txt")
        try Data("alpha".utf8).write(to: url)
        let snapshot = try TXTSourceSnapshot.read(at: url)
        try Data("beta".utf8).write(to: url)
        let document = try TXTIngestDocument(snapshot: snapshot, fallbackTitle: "书")
        XCTAssertEqual(try Data(contentsOf: url), Data("beta".utf8))
        XCTAssertEqual(document.snapshot.bytes, Data("alpha".utf8))
        XCTAssertEqual(document.decoding.text, "alpha")
        XCTAssertEqual(document.units.map { $0.chapter.content }, ["alpha"])
        XCTAssertEqual(document.sourceDigest, "8ed3f6ad685b959ead7022518e1af76cd816f8e8ec7ccdda1ed4018e8f2223f8")
        XCTAssertEqual(document.manifestDigest, "a13e8a2ac99958cf8fda2bcd7b0ceea257b9f6b0def8cf725c535082175bc62f")
    }

    // Falsifier: identities derived from text/hash collapse two distinct repeated chapters.
    func testRepeatedChapterTextKeepsDistinctOrdinalIdentitiesAndRanges() throws {
        let document = try ingest("第一章\n同文\n第一章\n同文")
        XCTAssertEqual(document.units.map { $0.unitID }, ["txt-unit:0", "txt-unit:1"])
        XCTAssertEqual(document.units.map { $0.chapter.content }, ["第一章\n同文", "第一章\n同文"])
        XCTAssertEqual(document.units.map { $0.contentUTF16Range }, [0..<6, 7..<13])
    }

    // Falsifier: an ingest wrapper must not re-label explicit replacement output as a strict success.
    func testLossyCompatibilityOutputRetainsItsActualDecodeEvidence() throws {
        let document = try TXTIngestDocument(snapshot: TXTSourceSnapshot(copying: Data([0xFF])), fallbackTitle: "书")
        XCTAssertEqual(document.sourceDigest, "a8100ae6aa1940d0b663bb31cd466142ebbdbd5187131b92d93818987832eb89")
        XCTAssertEqual(document.decoding.method, TXTDecodingMethod.lossyUTF8)
        XCTAssertFalse(document.decoding.didDecode)
        XCTAssertTrue(document.decoding.usedLossyUTF8Fallback)
        XCTAssertEqual(document.units.map { $0.chapter.content.unicodeScalars.map { $0.value } }, [[0xFFFD]])
    }

    // Characterization: source preparation's emptyContent precedence remains in the new entry point.
    func testEmptyWhitespaceAndInvalidAuthoritativeBOMStillRejectAsEmptyContent() {
        for bytes in [Data(), Data(" \r\n\t".utf8), Data([0xEF, 0xBB, 0xBF, 0xFF])] {
            do {
                _ = try TXTIngestDocument(snapshot: TXTSourceSnapshot(copying: bytes), fallbackTitle: "书")
                XCTFail("Expected emptyContent")
            } catch ParseError.emptyContent {
                // Existing source-preparation error, not a fallback to another decoder.
            } catch {
                XCTFail("Expected emptyContent, got \(error)")
            }
        }
    }

    // Falsifier: full parsing and metadata must retain their established consumer-visible projection.
    func testRealFileParserAndMetadataKeepTheirLegacyProjection() throws {
        let url = try makeDirectory().appendingPathComponent("书.txt")
        try Data(" \u{FEFF}前言\r\n\r\n第一章\r\n😀e\u{0301} \r\n".utf8).write(to: url)
        let document = try TXTIngestDocument.read(at: url)
        let full = try TXTParser().parse(url: url)
        let metadata = try TXTParser().parseMetadata(url: url)
        XCTAssertEqual(document.units.map { $0.chapter.content }, ["前言", "第一章\n😀e\u{0301}"])
        XCTAssertEqual(full.title, "书")
        XCTAssertEqual(full.chapterCount, 2)
        XCTAssertEqual(full.content, "前言\n\n第一章\n😀e\u{0301}")
        XCTAssertEqual(full.chapters?.map { $0.title }, ["书", "第一章"])
        XCTAssertEqual(full.chapters?.map { $0.content }, ["前言", "第一章\n😀e\u{0301}"])
        XCTAssertEqual(metadata.chapterCount, 2)
        XCTAssertEqual(metadata.content, "")
        XCTAssertNil(metadata.chapters)
    }

    // Characterization: the new file entrance preserves cannotRead instead of inventing empty content.
    func testMissingSourceStillReportsCannotRead() throws {
        let url = try makeDirectory().appendingPathComponent("missing.txt")
        do {
            _ = try TXTIngestDocument.read(at: url)
            XCTFail("Expected cannotRead")
        } catch ParseError.cannotRead(_) {
            // Expected file boundary.
        } catch {
            XCTFail("Expected cannotRead, got \(error)")
        }
    }

    private func ingest(_ text: String) throws -> TXTIngestDocument {
        try TXTIngestDocument(snapshot: TXTSourceSnapshot(copying: Data(text.utf8)), fallbackTitle: "书")
    }

    private func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TXTIngestTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
}
