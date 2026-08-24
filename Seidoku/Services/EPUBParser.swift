//
//  EPUBParser.swift
//  Seidoku
//
//  EPUB 解析：用 ZIPFoundation 解压 → 定位 OPF → 提取元数据（书名/作者）+ 章节数。
//

import Foundation
import ZIPFoundation

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

struct EPUBParser {
    func parse(url: URL) throws -> ParsedBook {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw ParseError.cannotRead("无法打开 EPUB：\(error.localizedDescription)")
        }

        // 1. 定位 OPF（container.xml）
        guard
            let containerXml = try extractString(archive, path: "META-INF/container.xml"),
            let opfPath = extractOPFPath(from: containerXml),
            let opfXml = try extractString(archive, path: opfPath)
        else {
            throw ParseError.invalidArchive
        }

        // 2. 解析 OPF 元数据
        let title = extractTag(opfXml, tag: "title") ?? url.deletingPathExtension().lastPathComponent
        let author = extractTag(opfXml, tag: "creator")

        // 3. 章节数（spine itemref 数量）
        let chapterCount = countSpineItems(opfXml)

        return ParsedBook(title: title, author: author, chapterCount: chapterCount, content: "")
    }

    // MARK: - ZIPFoundation 辅助

    /// 从 archive 按路径提取并转为字符串。
    private func extractString(_ archive: Archive, path: String) throws -> String? {
        guard let entry = archive[path] else { return nil }
        var data = Data()
        _ = try archive.extract(entry, consumer: { chunk in
            data.append(chunk)
        })
        return String(data: data, encoding: .utf8)
    }

    // MARK: - XML 正则解析

    /// 从 container.xml 提取第一个 rootfile 的 full-path。
    private func extractOPFPath(from xml: String) -> String? {
        guard let range = xml.range(of: #"full-path\s*=\s*"([^"]+)""#, options: .regularExpression) else {
            return nil
        }
        let match = xml[range]
        let parts = match.split(separator: "\"")
        return parts.count >= 2 ? String(parts[1]) : nil
    }

    /// 提取 <dc:title> / <dc:creator> 等标签内容（兼容 namespace 前缀）。
    private func extractTag(_ xml: String, tag: String) -> String? {
        let pattern = "<[^>]*:" + tag + "[^>]*>(.*?)</[^>]*:" + tag + ">"
        guard let range = xml.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let content = xml[range]
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : content
    }

    /// 统计 spine 里的 itemref 数量（章节数）。
    private func countSpineItems(_ xml: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: #"<itemref\b"#, options: .caseInsensitive) else {
            return 0
        }
        return regex.numberOfMatches(in: xml, range: NSRange(xml.startIndex..., in: xml))
    }
}
