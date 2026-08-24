//
//  TXTParser.swift
//  Seidoku
//
//  TXT 解析：编码检测 + 章节识别。
//

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

    var errorDescription: String? {
        switch self {
        case .cannotRead(let message): return "读取文件失败：\(message)"
        case .emptyContent: return "文件内容为空"
        }
    }
}

struct TXTParser {
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
        let chapterCount = Self.detectChapterCount(trimmed)

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
        let patterns = [
            #"^第[0-9零一二三四五六七八九十百千万两]+[章节回卷集部篇]"#,
            #"^第\s*[0-9]+\s*[章节回卷集部篇]"#,
            #"^Chapter\s+\d+"#,
        ]
        var count = 0
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for pattern in patterns {
                if trimmed.range(of: pattern, options: .regularExpression) != nil {
                    count += 1
                    break
                }
            }
        }
        return count
    }
}
