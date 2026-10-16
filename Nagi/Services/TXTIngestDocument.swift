import CryptoKit
import Foundation

/// In-memory input identity, not a saved-position wire schema or admission token.
struct TXTInputScope: Equatable, Sendable {
    let bookID: UUID
    let sourceDigest: String
    let ingestRevision: String
    let manifestDigest: String
}

struct TXTIngestDocument: Sendable {
    struct Unit: Sendable {
        let unitID: String
        let nodeID: String
        let chapter: TXTChapter
        let segmentUTF16Range: Range<Int>
        let contentUTF16Range: Range<Int>
    }

    typealias ManifestRecord = (unitID: String, nodeID: String, text: String)
    static let ingestRevision = "nagi-txt-ingest-v1"

    let snapshot: TXTSourceSnapshot
    let decoding: TXTDecodingResult
    let partition: TXTChapterPartition
    let units: [Unit]
    let sourceDigest: String
    let manifestDigest: String

    init(snapshot: TXTSourceSnapshot, fallbackTitle: String) throws {
        self.snapshot = snapshot
        decoding = snapshot.decoded
        partition = TXTChapterPartition(text: try TXTSourceSnapshot.prepare(decoding.text), fallbackTitle: fallbackTitle)
        units = partition.units.enumerated().map { ordinal, unit in
            Unit(unitID: "txt-unit:\(ordinal)", nodeID: "txt-root", chapter: unit.chapter,
                 segmentUTF16Range: unit.segmentUTF16Range, contentUTF16Range: unit.contentUTF16Range)
        }
        sourceDigest = Self.hex(SHA256.hash(data: snapshot.bytes))
        manifestDigest = Self.fingerprint(revision: Self.ingestRevision, records: units.map {
            (unitID: $0.unitID, nodeID: $0.nodeID, text: $0.chapter.content)
        })
    }

    static func read(at url: URL) throws -> Self {
        try Self(snapshot: TXTSourceSnapshot.read(at: url), fallbackTitle: url.deletingPathExtension().lastPathComponent)
    }

    func scope(for bookID: UUID) -> TXTInputScope {
        TXTInputScope(bookID: bookID, sourceDigest: sourceDigest,
                      ingestRevision: Self.ingestRevision, manifestDigest: manifestDigest)
    }

    /// Format 1: length-framed exact UTF-8, with unsigned 64-bit big-endian counts.
    /// The production sink hashes each chunk; it does not concatenate the book again.
    static func encodeManifest(revision: String, records: [ManifestRecord], consume: (Data) -> Void) {
        func count(_ value: UInt64) {
            consume(Data((0..<8).reversed().map { byte in
                UInt8(truncatingIfNeeded: value >> (byte * 8))
            }))
        }
        func field(_ value: String) {
            count(UInt64(value.utf8.count))
            consume(Data(value.utf8))
        }
        field("nagi.txt.manifest")
        count(1)
        field(revision)
        count(UInt64(records.count))
        for record in records {
            field(record.unitID)
            field(record.nodeID)
            field(record.text)
        }
    }

    static func fingerprint(revision: String, records: [ManifestRecord]) -> String {
        var hash = SHA256()
        encodeManifest(revision: revision, records: records) { hash.update(data: $0) }
        return hex(hash.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
