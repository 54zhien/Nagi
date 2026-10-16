import Foundation

struct ParsedBook: Sendable {
    let title: String
    let author: String?
    let chapterCount: Int
    let content: String
    let chapters: [TXTChapter]?
    let coverData: Data?

    init(
        title: String,
        author: String?,
        chapterCount: Int,
        content: String,
        chapters: [TXTChapter]? = nil,
        coverData: Data? = nil
    ) {
        self.title = title
        self.author = author
        self.chapterCount = chapterCount
        self.content = content
        self.chapters = chapters
        self.coverData = coverData
    }
}

struct TXTChapter: Sendable {
    let title: String
    let content: String
}

enum ParseError: LocalizedError {
    case cannotRead(String)
    case emptyContent
    case invalidArchive

    var errorDescription: String? {
        switch self {
        case .cannotRead(let message): return "读取文件失败：\(message)"
        case .emptyContent: return "文件内容为空"
        case .invalidArchive: return "EPUB 文件损坏或格式无效"
        }
    }
}

struct TXTParser: Sendable {
    /// Plain-text extensions accepted by both the document picker and the
    /// import parser.  `public.plain-text` also covers `.text` files, so the
    /// extension check must not be narrower than the picker.
    static let supportedExtensions: Set<String> = ["txt", "text"]

    func parse(url: URL) throws -> ParsedBook {
        let trimmed = try TXTSourceSnapshot.read(at: url).preparedText()
        let title = url.deletingPathExtension().lastPathComponent
        let chapters = Self.splitIntoChapters(trimmed, fallbackTitle: title)

        return ParsedBook(
            title: title,
            author: nil,
            chapterCount: chapters.count,
            content: trimmed,
            chapters: chapters
        )
    }

    /// Reads only the metadata needed by a library card and avoids materializing
    /// a second complete set of chapter strings during import.
    func parseMetadata(url: URL) throws -> ParsedBook {
        let trimmed = try TXTSourceSnapshot.read(at: url).preparedText()
        var detectedChapterCount = 0
        var hasContentBeforeFirstChapter = false
        for line in trimmed.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineText = String(line)
            if Self.chapterTitle(from: lineText) != nil {
                detectedChapterCount += 1
            } else if detectedChapterCount == 0,
                      !lineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hasContentBeforeFirstChapter = true
            }
        }
        if detectedChapterCount > 0, hasContentBeforeFirstChapter {
            detectedChapterCount += 1
        }

        return ParsedBook(
            title: url.deletingPathExtension().lastPathComponent,
            author: nil,
            chapterCount: max(detectedChapterCount, 1),
            content: ""
        )
    }

    /// Compatibility projection of the shared decoder; no second decision chain.
    static func decode(_ data: Data) -> String {
        TXTSourceSnapshot.decode(data).text
    }

    /// 按章节标题切分 TXT。没有识别到标题时保留为一个完整章节，避免目录为空。
    static func splitIntoChapters(
        _ text: String,
        fallbackTitle: String
    ) -> [TXTChapter] {
        TXTChapterPartition(text: text, fallbackTitle: fallbackTitle).units.map { $0.chapter }
    }

    /// Shared recognizer for allocation-light metadata counting and partitioning.
    static func chapterTitle(from line: String) -> String? {
        let title = line
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 80 else { return nil }

        let patterns = [
            #"^第\s*[0-9零一二三四五六七八九十百千万两]+\s*[章节回卷集部篇]"#,
            #"^Chapter\s+[0-9]+(?:\b|[:：.．\s])"#,
            #"^(?:序章|楔子|引子|尾声|终章|番外(?:篇)?|外传)(?:$|[:：.．\s])"#,
            #"^[0-9]+[、.．]\s*\S+"#,
            #"^[零一二三四五六七八九十百千万两]+[、.．]\s*\S+"#,
        ]
        guard patterns.contains(where: {
            title.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }) else {
            return nil
        }
        return title
    }
}
