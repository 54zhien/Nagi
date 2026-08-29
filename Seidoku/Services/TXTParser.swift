//
//  TXTParser.swift
//  Seidoku
//
//  TXT 文档解析：编码识别、换行规范化和章节范围索引。
//

import CoreFoundation
import Foundation

struct ParsedBook {
    let title: String
    let author: String?
    let chapterCount: Int
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

/// TXT 的稳定章节索引。范围使用 UTF-16 offset，和 TextKit / NSString 保持一致。
struct TXTChapter: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let startUTF16: Int
    let endUTF16: Int

    var range: NSRange {
        NSRange(location: startUTF16, length: max(0, endUTF16 - startUTF16))
    }
}

/// 解析后的 TXT 文档。正文只保留一份，章节通过范围切片，避免重复存储。
struct TXTDocument: Sendable {
    let title: String
    let author: String?
    let text: String
    let chapters: [TXTChapter]

    func text(for chapter: TXTChapter) -> String {
        (text as NSString).substring(with: chapter.range)
    }
}

struct TXTParser {
    func parse(url: URL) throws -> ParsedBook {
        let document = try parseDocument(url: url)
        return ParsedBook(
            title: document.title,
            author: document.author,
            chapterCount: document.chapters.count,
            content: document.text
        )
    }

    func parseDocument(url: URL) throws -> TXTDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw ParseError.cannotRead(error.localizedDescription)
        }

        let decoded = try Self.decode(data)
        let normalized = Self.normalize(decoded)
        guard !normalized.isEmpty else {
            throw ParseError.emptyContent
        }

        let title = url.deletingPathExtension().lastPathComponent
        return TXTDocument(
            title: title,
            author: nil,
            text: normalized,
            chapters: Self.detectChapters(in: normalized)
        )
    }

    /// 依次处理 BOM、UTF-8、UTF-16、GB18030、Big5 和 Shift-JIS。
    /// 不使用 ISO-8859-1 兜底，避免把损坏的中文文件伪解码成乱码。
    static func decode(_ data: Data) throws -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        if data.starts(with: [0xFF, 0xFE]),
           let text = String(data: data, encoding: .utf16LittleEndian) {
            return text
        }
        if data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16BigEndian) {
            return text
        }

        if let text = Self.decodeLikelyUTF16(data) {
            return text
        }

        let optionalEncodings: [String.Encoding?] = [
            .utf8,
            Self.encoding(named: "GB18030"),
            Self.encoding(named: "Big5"),
            Self.encoding(named: "Shift_JIS"),
            .utf16LittleEndian,
            .utf16BigEndian,
            .utf16,
            .unicode,
        ]
        let encodings = optionalEncodings.compactMap { $0 }

        for encoding in encodings {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }

        throw ParseError.cannotRead("无法识别文本编码")
    }

    /// 统一 CRLF / CR，移除 BOM 和 NUL，并只删除首尾空白行。
    /// 正文行内部的空格和空行会保留，避免改变原书语义。
    static func normalize(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\0", with: "")
            .precomposedStringWithCanonicalMapping

        if result.hasPrefix("\u{FEFF}") {
            result.removeFirst()
        }

        var lines = result
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        while let first = lines.first,
              first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeFirst()
        }
        while let last = lines.last,
              last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeLast()
        }

        return lines.joined(separator: "\n")
    }

    /// 识别章节标题并返回真实范围，而不是只返回章节数量。
    static func detectChapters(in text: String) -> [TXTChapter] {
        let nsText = text as NSString
        var headings: [(start: Int, title: String)] = []
        var cursor = 0

        while cursor < nsText.length {
            let lineRange = nsText.lineRange(for: NSRange(location: cursor, length: 0))
            let rawLine = nsText.substring(with: lineRange)
            let title = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if let chapterTitle = Self.chapterTitle(from: title) {
                headings.append((lineRange.location, chapterTitle))
            }

            let nextCursor = NSMaxRange(lineRange)
            guard nextCursor > cursor else { break }
            cursor = nextCursor
        }

        guard !headings.isEmpty else {
            return [TXTChapter(id: "chapter-0", title: "正文", startUTF16: 0, endUTF16: nsText.length)]
        }

        var chapters: [TXTChapter] = []
        let firstHeadingStart = headings[0].start
        let preface = nsText.substring(with: NSRange(location: 0, length: firstHeadingStart))
        if !preface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chapters.append(TXTChapter(
                id: "preface",
                title: "前言",
                startUTF16: 0,
                endUTF16: firstHeadingStart
            ))
        }

        for (index, heading) in headings.enumerated() {
            let end = index + 1 < headings.count ? headings[index + 1].start : nsText.length
            guard end > heading.start else { continue }
            chapters.append(TXTChapter(
                id: "chapter-\(index)",
                title: heading.title,
                startUTF16: heading.start,
                endUTF16: end
            ))
        }

        return chapters.isEmpty
            ? [TXTChapter(id: "chapter-0", title: "正文", startUTF16: 0, endUTF16: nsText.length)]
            : chapters
    }

    private static func chapterTitle(from line: String) -> String? {
        guard !line.isEmpty, line.count <= 80 else { return nil }

        let patterns = [
            #"^(序章|楔子|引子|尾声|终章|番外(?:篇)?|后记)$"#,
            #"^第\s*[0-9零一二三四五六七八九十百千万两〇○]+\s*[章节回卷集部篇](?:\s*[-—:：.．]?\s*.*)?$"#,
            #"^Chapter\s+\d+(?:\s*[-—:：.．]?\s*.*)?$"#,
        ]

        for pattern in patterns {
            if line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return line
            }
        }
        return nil
    }

    private static func encoding(named name: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    private static func decodeLikelyUTF16(_ data: Data) -> String? {
        let bytes = Array(data.prefix(4_096))
        guard bytes.count >= 4 else { return nil }

        let evenZeroCount = stride(from: 0, to: bytes.count, by: 2)
            .reduce(into: 0) { count, index in count += bytes[index] == 0 ? 1 : 0 }
        let oddZeroCount = stride(from: 1, to: bytes.count, by: 2)
            .reduce(into: 0) { count, index in count += bytes[index] == 0 ? 1 : 0 }
        let threshold = max(2, bytes.count / 10)

        if oddZeroCount >= threshold, oddZeroCount > evenZeroCount * 2 {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        if evenZeroCount >= threshold, evenZeroCount > oddZeroCount * 2 {
            return String(data: data, encoding: .utf16BigEndian)
        }
        return nil
    }
}
