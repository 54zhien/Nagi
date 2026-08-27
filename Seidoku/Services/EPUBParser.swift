//
//  EPUBParser.swift
//  Seidoku
//
//  EPUB 解析：用 ZIPFoundation 解压 → 定位 OPF → 提取元数据 + 章节列表 + 章节正文。
//

import Foundation
import SwiftSoup

struct EPUBParser {
    func parse(url: URL) throws -> ParsedBook {
        let archive = try openArchive(url)
        let (opfXml, opfDir) = try opfDocument(archive)

        let title = extractTag(opfXml, tag: "title") ?? url.deletingPathExtension().lastPathComponent
        let author = extractTag(opfXml, tag: "creator")
        let chapters = try chapters(from: archive, opfXml: opfXml, opfDir: opfDir)

        return ParsedBook(title: title, author: author, chapterCount: chapters.count, content: "")
    }

    /// 章节列表（spine 阅读顺序）。
    func loadChapters(url: URL) throws -> [BookChapter] {
        let archive = try openArchive(url)
        let (opfXml, opfDir) = try opfDocument(archive)
        return try chapters(from: archive, opfXml: opfXml, opfDir: opfDir)
    }

    /// 加载某章正文（XHTML → 纯文本）。
    func loadChapterContent(url: URL, href: String) throws -> String {
        let archive = try openArchive(url)
        guard let entry = entry(in: archive, path: href) else {
            throw ParseError.invalidArchive
        }
        var data = Data()
        _ = try archive.extract(entry, consumer: { data.append($0) })
        guard let html = Self.decodeText(data) else {
            throw ParseError.invalidArchive
        }
        return Self.htmlToText(html)
    }

    // MARK: - 内部

    private func openArchive(_ url: URL) throws -> Archive {
        do {
            return try Archive(url: url, accessMode: .read)
        } catch {
            throw ParseError.cannotRead("无法打开 EPUB：\(error.localizedDescription)")
        }
    }

    /// 返回 (OPF XML 文本, OPF 所在目录)。
    private func opfDocument(_ archive: Archive) throws -> (String, String) {
        guard
            let containerXml = try extractString(archive, path: "META-INF/container.xml"),
            let opfPath = extractOPFPath(from: containerXml),
            let opfXml = try extractString(archive, path: opfPath)
        else {
            throw ParseError.invalidArchive
        }
        let opfDir = (opfPath as NSString).deletingLastPathComponent
        return (opfXml, opfDir)
    }

    /// 从 OPF 提取章节列表（manifest + spine）。
    private func chapters(from archive: Archive, opfXml: String, opfDir: String) throws -> [BookChapter] {
        let manifest = parseManifest(opfXml)      // id -> href
        let spine = parseSpine(opfXml)            // [idref]
        guard !spine.isEmpty else {
            throw ParseError.invalidArchive
        }

        var chapters: [BookChapter] = []
        for idref in spine {
            guard let href = manifest[idref] else { continue }
            let fullPath = resolve(href: href, relativeTo: opfDir)
            guard entry(in: archive, path: fullPath) != nil else { continue }
            let index = chapters.count
            chapters.append(BookChapter(
                id: fullPath,
                title: "第 \(index + 1) 章",
                href: fullPath,
                index: index
            ))
        }
        guard !chapters.isEmpty else {
            throw ParseError.invalidArchive
        }
        return chapters
    }

    private func parseManifest(_ opfXml: String) -> [String: String] {
        var result: [String: String] = [:]
        for element in matches(of: #"<(?:[A-Za-z_][\w.-]*:)?item\b[^>]*>"#, in: opfXml) {
            if let id = extractAttr(element, name: "id"),
               let href = extractAttr(element, name: "href") {
                result[id] = href
            }
        }
        return result
    }

    private func parseSpine(_ opfXml: String) -> [String] {
        var result: [String] = []
        for element in matches(of: #"<(?:[A-Za-z_][\w.-]*:)?itemref\b[^>]*>"#, in: opfXml) {
            if let idref = extractAttr(element, name: "idref") {
                result.append(idref)
            }
        }
        return result
    }

    private func resolve(href: String, relativeTo dir: String) -> String {
        let decodedHref = decodeXMLEntities(href)
            .components(separatedBy: "#")[0]
            .components(separatedBy: "?")[0]
            .removingPercentEncoding ?? href
        let joined = dir.isEmpty ? decodedHref : "\(dir)/\(decodedHref)"
        return normalizeArchivePath(joined)
    }

    private func extractString(_ archive: Archive, path: String) throws -> String? {
        guard let entry = entry(in: archive, path: normalizeArchivePath(path)) else { return nil }
        var data = Data()
        _ = try archive.extract(entry, consumer: { data.append($0) })
        return Self.decodeText(data)
    }

    private func extractOPFPath(from xml: String) -> String? {
        guard let rootfile = matches(
            of: #"<(?:[A-Za-z_][\w.-]*:)?rootfile\b[^>]*>"#,
            in: xml
        ).first,
        let path = extractAttr(rootfile, name: "full-path") else { return nil }
        return normalizeArchivePath(decodeXMLEntities(path).removingPercentEncoding ?? path)
    }

    private func extractTag(_ xml: String, tag: String) -> String? {
        let pattern = "<(?:[A-Za-z_][\\w.-]*:)?" + tag + "\\b[^>]*>([\\s\\S]*?)</(?:[A-Za-z_][\\w.-]*:)?" + tag + ">"
        guard let range = xml.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let content = decodeXMLEntities(String(xml[range]))
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : content
    }

    private func extractAttr(_ element: String, name: String) -> String? {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*(['"])(.*?)\1"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: element, range: NSRange(element.startIndex..., in: element)),
              let valueRange = Range(match.range(at: 2), in: element) else { return nil }
        return decodeXMLEntities(String(element[valueRange]))
    }

    private func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private func entry(in archive: Archive, path: String) -> Entry? {
        let normalized = normalizeArchivePath(path)
        if let exact = archive[normalized] { return exact }
        return archive.first {
            normalizeArchivePath($0.path).compare(normalized, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    private func normalizeArchivePath(_ path: String) -> String {
        var components: [String] = []
        for component in path.replacingOccurrences(of: "\\", with: "/").split(separator: "/") {
            switch component {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(String(component))
            }
        }
        return components.joined(separator: "/")
    }

    private func decodeXMLEntities(_ text: String) -> String {
        (try? SwiftSoup.parseBodyFragment(text).text()) ?? text
    }

    private static func decodeText(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let utf16 = String(data: data, encoding: .utf16) { return utf16 }

        let declaration = String(data: data.prefix(512), encoding: .isoLatin1) ?? ""
        guard let regex = try? NSRegularExpression(
            pattern: #"encoding\s*=\s*['\"]([^'\"]+)['\"]"#,
            options: [.caseInsensitive]
        ), let match = regex.firstMatch(in: declaration, range: NSRange(declaration.startIndex..., in: declaration)),
        let range = Range(match.range(at: 1), in: declaration) else { return nil }

        let name = String(declaration[range]) as CFString
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding(name))
        guard encoding != UInt(kCFStringEncodingInvalidId) else { return nil }
        return String(data: data, encoding: String.Encoding(rawValue: encoding))
    }

    /// XHTML → 纯文本（SwiftSoup 解析，保留段落，忽略 style/script）。
    static func htmlToText(_ html: String) -> String {
        guard let doc = try? SwiftSoup.parse(html),
              let body = try? doc.body() else {
            return Self.legacyHtmlToText(html)
        }

        // 提取块级文本元素，保留段落结构
        let selector = "p, li, h1, h2, h3, h4, h5, h6, blockquote, pre, td, th"
        guard let elements = try? body.select(selector) else {
            return Self.legacyHtmlToText(html)
        }

        var paragraphs: [String] = []
        for element in elements {
            let text = (try? element.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty {
                paragraphs.append(text)
            }
        }

        if paragraphs.isEmpty {
            return ((try? body.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return paragraphs.joined(separator: "\n\n")
    }

    /// 正则 fallback（SwiftSoup 不可用时）。
    static func legacyHtmlToText(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: #"<style[^>]*>.*?</style>"#, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<script[^>]*>.*?</script>"#, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<!--.*?-->"#, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"</(p|div|h[1-6]|li|blockquote|tr)>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<(br|hr)\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&apos;", with: "'")
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&#160;", with: " ")
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
