import Foundation

/// An owner for chapter-edge coordinates in LF-normalized input. These ranges
/// are not raw-file offsets or persistent positions and cannot bridge to Readium.
struct TXTChapterPartition: Sendable {
    struct Unit: Sendable {
        let chapter: TXTChapter
        /// Heading-line start (or preface/fallback start) to next heading/EOF.
        /// Includes the separating newline and discarded edge whitespace.
        let segmentUTF16Range: Range<Int>
        /// Exact chapter text within this owner's normalizedText, after trimming.
        let contentUTF16Range: Range<Int>
    }

    let normalizedText: String
    let units: [Unit]

    init(text: String, fallbackTitle: String) {
        let normalized = TXTSourceSnapshot.normalizeLineEndings(text)
        var starts: [(index: String.Index, offset: Int, title: String)] = []
        var offset = 0
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if let title = TXTParser.chapterTitle(from: String(line)) {
                starts.append((line.startIndex, offset, title))
            }
            offset += line.utf16.count
            if line.endIndex < normalized.endIndex {
                offset += 1 // LF is one UTF-16 code unit, including empty lines.
            }
        }

        var result: [Unit] = []
        func appendUnit(
            title: String,
            start: String.Index,
            end: String.Index,
            startOffset: Int,
            endOffset: Int
        ) {
            let segment = normalized[start..<end]
            let content = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return }

            // Count the actual trimmed prefix, not a search for content: repeated
            // identical chapters must never be resolved to an earlier occurrence.
            let leadingTrim = segment.unicodeScalars
                .prefix { CharacterSet.whitespacesAndNewlines.contains($0) }
                .reduce(0) { $0 + ($1.value > 0xFFFF ? 2 : 1) }
            let contentStart = startOffset + leadingTrim
            result.append(Unit(
                chapter: TXTChapter(title: title, content: content),
                segmentUTF16Range: startOffset..<endOffset,
                contentUTF16Range: contentStart..<(contentStart + content.utf16.count)
            ))
        }

        if let first = starts.first {
            if first.index > normalized.startIndex {
                appendUnit(
                    title: fallbackTitle, start: normalized.startIndex, end: first.index,
                    startOffset: 0, endOffset: first.offset
                )
            }
            for (index, start) in starts.enumerated() {
                let next = index + 1 < starts.count ? starts[index + 1] : nil
                appendUnit(
                    title: start.title, start: start.index, end: next?.index ?? normalized.endIndex,
                    startOffset: start.offset, endOffset: next?.offset ?? offset
                )
            }
        } else {
            appendUnit(
                title: fallbackTitle, start: normalized.startIndex, end: normalized.endIndex,
                startOffset: 0, endOffset: offset
            )
        }

        normalizedText = normalized
        units = result
    }
}
