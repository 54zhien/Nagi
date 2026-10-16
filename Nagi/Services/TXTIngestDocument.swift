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
        partition = TXTChapterPartition(text: try snapshot.preparedText(), fallbackTitle: fallbackTitle)
        units = []
        sourceDigest = ""
        manifestDigest = ""
    }

    static func read(at url: URL) throws -> Self {
        try Self(snapshot: TXTSourceSnapshot.read(at: url), fallbackTitle: url.deletingPathExtension().lastPathComponent)
    }

    func scope(for bookID: UUID) -> TXTInputScope {
        TXTInputScope(bookID: bookID, sourceDigest: sourceDigest,
                      ingestRevision: Self.ingestRevision, manifestDigest: manifestDigest)
    }

    static func encodeManifest(revision: String, records: [ManifestRecord], consume: (Data) -> Void) {}

    static func fingerprint(revision: String, records: [ManifestRecord]) -> String { "" }
}
