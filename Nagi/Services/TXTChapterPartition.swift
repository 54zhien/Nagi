import Foundation

/// An owner for chapter-edge coordinates in LF-normalized input. These ranges
/// are not raw-file offsets or persistent positions and cannot bridge to Readium.
struct TXTChapterPartition: Sendable {
    struct Unit: Sendable {
        let chapter: TXTChapter
        let segmentUTF16Range: Range<Int>
        let contentUTF16Range: Range<Int>
    }

    let normalizedText: String
    let units: [Unit]

    init(text: String, fallbackTitle: String) {
        normalizedText = TXTSourceSnapshot.normalizeLineEndings(text)
        units = []
    }
}
