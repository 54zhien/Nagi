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
    let chapters: [TXTChapter]? = nil
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
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw ParseError.cannotRead(error.localizedDescription)
        }

        let text = Self.decode(data).replacingOccurrences(of: "\u{FEFF}", with: "")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ParseError.emptyContent
        }

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

    /// Decode the encodings commonly used by downloaded Chinese plain-text
    /// books. BOMs are authoritative; a conservative NUL-byte heuristic also
    /// covers the common ASCII-heavy UTF-16/32 files exported without a BOM
    /// before trying UTF-8/GB18030.
    static func decode(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }

        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: Data(data.dropFirst(3)), encoding: .utf8) ?? ""
        }
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return String(data: Data(data.dropFirst(4)), encoding: .utf32LittleEndian) ?? ""
        }
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return String(data: Data(data.dropFirst(4)), encoding: .utf32BigEndian) ?? ""
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: Data(data.dropFirst(2)), encoding: .utf16LittleEndian) ?? ""
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: Data(data.dropFirst(2)), encoding: .utf16BigEndian) ?? ""
        }

        if let encoding = detectUTF32Encoding(data),
           let text = String(data: data, encoding: encoding) {
            return text
        }
        if let encoding = detectUTF16Encoding(data),
           let text = String(data: data, encoding: encoding) {
            return text
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        let gbEncoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        if let gb = String(data: data, encoding: String.Encoding(rawValue: gbEncoding)) {
            return gb
        }

        return String(decoding: data, as: UTF8.self)
    }

    private static func detectUTF16Encoding(_ data: Data) -> String.Encoding? {
        let sample = Array(data.prefix(4096))
        guard sample.count >= 8 else { return nil }

        let evenCount = max(sample.count / 2, 1)
        let evenZeros = stride(from: 0, to: sample.count, by: 2)
            .reduce(into: 0) { count, index in count += sample[index] == 0 ? 1 : 0 }
        let oddZeros = stride(from: 1, to: sample.count, by: 2)
            .reduce(into: 0) { count, index in count += sample[index] == 0 ? 1 : 0 }

        if oddZeros * 3 >= evenCount * 2, evenZeros * 10 < evenCount {
            return .utf16LittleEndian
        }
        if evenZeros * 3 >= evenCount * 2, oddZeros * 10 < evenCount {
            return .utf16BigEndian
        }
        return nil
    }

    private static func detectUTF32Encoding(_ data: Data) -> String.Encoding? {
        let sample = Array(data.prefix(4096))
        guard sample.count >= 16 else { return nil }

        let quartetCount = max(sample.count / 4, 1)
        let zeroCounts = (0..<4).map { offset in
            stride(from: offset, to: sample.count, by: 4)
                .reduce(into: 0) { count, index in count += sample[index] == 0 ? 1 : 0 }
        }
        // UTF-32 Chinese characters commonly use two non-zero low bytes, so
        // detect the high-byte pair instead of requiring three zero bytes.
        let littleEndianHighByteZeros = zeroCounts[2] + zeroCounts[3]
        if littleEndianHighByteZeros * 2 >= quartetCount * 3,
           zeroCounts[0] + zeroCounts[1] < quartetCount * 3 {
            return .utf32LittleEndian
        }

        let bigEndianHighByteZeros = zeroCounts[0] + zeroCounts[1]
        if bigEndianHighByteZeros * 2 >= quartetCount * 3,
           zeroCounts[2] + zeroCounts[3] < quartetCount * 3 {
            return .utf32BigEndian
        }
        return nil
    }

    /// 识别章节标题（如「第一章」「第1章」「Chapter 1」等），返回章节数。
    static func detectChapterCount(_ text: String) -> Int {
        splitIntoChapters(text, fallbackTitle: "正文").count
    }

    /// 按章节标题切分 TXT。没有识别到标题时保留为一个完整章节，避免目录为空。
    static func splitIntoChapters(
        _ text: String,
        fallbackTitle: String
    ) -> [TXTChapter] {
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
            return content.isEmpty ? [] : [TXTChapter(title: fallbackTitle, content: content)]
        }

        var chapters: [TXTChapter] = []
        if starts[0].0 > 0 {
            let preface = lines[0 ..< starts[0].0]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !preface.isEmpty {
                chapters.append(TXTChapter(title: fallbackTitle, content: preface))
            }
        }

        chapters.append(contentsOf: starts.enumerated().compactMap { position, start in
            let end = position + 1 < starts.count ? starts[position + 1].0 : lines.count
            guard start.0 < end else { return nil }
            let content = lines[start.0 ..< end]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            return TXTChapter(title: start.1, content: content)
        })
        return chapters
    }

    private static func chapterTitle(from line: String) -> String? {
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
