//
//  TXTParser.swift
//  Nagi
//
//  TXT 解析：编码检测 + 章节识别。
//

import Foundation

struct ParsedBook: Sendable {
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

struct TXTParser: Sendable {
    func parse(url: URL) throws -> ParsedBook {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ParseError.cannotRead(error.localizedDescription)
        }

        let text = Self.decode(data)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ParseError.emptyContent
        }

        let title = url.deletingPathExtension().lastPathComponent
        let chapterCount = Self.splitIntoChapters(trimmed, fallbackTitle: title).count

        return ParsedBook(title: title, author: nil, chapterCount: chapterCount, content: trimmed)
    }

    /// 编码检测：优先 UTF-8，失败回退 GB18030（中文 TXT 常见）。
    static func decode(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        let gbEncoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        if let gb = String(data: data, encoding: String.Encoding(rawValue: gbEncoding)) {
            return gb
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 识别章节标题（如「第一章」「第1章」「Chapter 1」等），返回章节数。
    static func detectChapterCount(_ text: String) -> Int {
        splitIntoChapters(text, fallbackTitle: "正文").count
    }

    /// 按章节标题切分 TXT。没有识别到标题时保留为一个完整章节，避免目录为空。
    static func splitIntoChapters(
        _ text: String,
        fallbackTitle: String
    ) -> [(title: String, content: String)] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        let starts = lines.enumerated().compactMap { index, line -> (Int, String)? in
            guard let title = chapterTitle(from: line) else { return nil }
            return (index, title)
        }

        guard !starts.isEmpty else {
            let content = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            return content.isEmpty ? [] : [(fallbackTitle, content)]
        }

        var chapters: [(title: String, content: String)] = []
        if starts[0].0 > 0 {
            let preface = lines[0 ..< starts[0].0]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !preface.isEmpty {
                chapters.append((fallbackTitle, preface))
            }
        }

        chapters.append(contentsOf: starts.enumerated().compactMap { position, start in
            let end = position + 1 < starts.count ? starts[position + 1].0 : lines.count
            guard start.0 < end else { return nil }
            let content = lines[start.0 ..< end]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            return (start.1, content)
        })
        return chapters
    }

    private static func chapterTitle(from line: String) -> String? {
        let title = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 80 else { return nil }

        let patterns = [
            #"^第\s*[0-9零一二三四五六七八九十百千万两]+\s*[章节回卷集部篇]"#,
            #"^Chapter\s+[0-9]+(?:\b|[:：.．\s])"#,
        ]
        guard patterns.contains(where: {
            title.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }) else {
            return nil
        }
        return title
    }
}
