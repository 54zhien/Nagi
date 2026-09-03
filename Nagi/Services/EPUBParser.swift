
import Foundation
import CoreGraphics
import ImageIO
import SwiftSoup
import UniformTypeIdentifiers

struct EPUBParser: Sendable {
    func parse(url: URL) throws -> ParsedBook {
        let archive = try openArchive(url)
        let (opfXml, opfDir) = try opfDocument(archive)

        let title = extractTag(opfXml, tag: "title") ?? url.deletingPathExtension().lastPathComponent
        let author = extractTag(opfXml, tag: "creator")
        let chapters = try chapters(from: archive, opfXml: opfXml, opfDir: opfDir)
        let coverData: Data?
        do {
            coverData = try extractCoverData(from: archive, opfXml: opfXml, opfDir: opfDir)
        } catch {
            coverData = nil
        }

        return ParsedBook(
            title: title,
            author: author,
            chapterCount: chapters.count,
            content: "",
            coverData: coverData
        )
    }

    func loadCoverData(url: URL) throws -> Data? {
        let archive = try openArchive(url)
        let (opfXml, opfDir) = try opfDocument(archive)
        return try extractCoverData(from: archive, opfXml: opfXml, opfDir: opfDir)
    }

    func loadChapters(url: URL) throws -> [BookChapter] {
        let archive = try openArchive(url)
        let (opfXml, opfDir) = try opfDocument(archive)
        return try chapters(from: archive, opfXml: opfXml, opfDir: opfDir)
    }

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


    private func openArchive(_ url: URL) throws -> Archive {
        do {
            return try Archive(url: url, accessMode: .read)
        } catch {
            throw ParseError.cannotRead("无法打开 EPUB：\(error.localizedDescription)")
        }
    }

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

    private func chapters(from archive: Archive, opfXml: String, opfDir: String) throws -> [BookChapter] {
        let manifest = parseManifest(opfXml)
        let spine = parseSpine(opfXml)
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

    private struct ManifestItem {
        let id: String
        let href: String
        let mediaType: String?
        let properties: String?
    }

    private func parseManifest(_ opfXml: String) -> [String: String] {
        parseManifestItems(opfXml).reduce(into: [:]) { result, item in
            result[item.id] = item.href
        }
    }

    private func parseManifestItems(_ opfXml: String) -> [ManifestItem] {
        var result: [ManifestItem] = []
        for element in matches(of: #"<(?:[A-Za-z_][\w.-]*:)?item\b[^>]*>"#, in: opfXml) {
            if let id = extractAttr(element, name: "id"),
               let href = extractAttr(element, name: "href") {
                result.append(ManifestItem(
                    id: id,
                    href: href,
                    mediaType: extractAttr(element, name: "media-type"),
                    properties: extractAttr(element, name: "properties")
                ))
            }
        }
        return result
    }

    private func extractCoverData(
        from archive: Archive,
        opfXml: String,
        opfDir: String
    ) throws -> Data? {
        let manifest = parseManifestItems(opfXml)
        guard !manifest.isEmpty else { return nil }

        let metaElements = matches(
            of: #"<(?:[A-Za-z_][\w.-]*:)?meta\b[^>]*>"#,
            in: opfXml
        )
        let coverID = metaElements
            .first(where: { extractAttr($0, name: "name")?.lowercased() == "cover" })
            .flatMap { extractAttr($0, name: "content") }

        var candidates: [ManifestItem] = []
        var seenIDs = Set<String>()

        func append(_ item: ManifestItem?) {
            guard let item, seenIDs.insert(item.id).inserted else { return }
            candidates.append(item)
        }

        if let coverID {
            append(manifest.first(where: { $0.id == coverID }))
            append(manifest.first(where: {
                $0.id.caseInsensitiveCompare(coverID) == .orderedSame
            }))
        }

        let imageItems = manifest.filter {
            $0.mediaType?.lowercased().hasPrefix("image/") == true
        }
        imageItems
            .filter {
                let id = $0.id.lowercased()
                let href = $0.href.lowercased()
                let properties = ($0.properties?.lowercased() ?? "")
                    .split(whereSeparator: \.isWhitespace)
                    .map(String.init)
                return properties.contains("cover-image")
                    || id.contains("cover")
                    || href.contains("cover")
            }
            .forEach { append($0) }
        imageItems.forEach { append($0) }

        for item in candidates {
            let path = resolve(href: item.href, relativeTo: opfDir)
            guard let entry = entry(in: archive, path: path) else { continue }

            var data = Data()
            _ = try archive.extract(entry, consumer: { data.append($0) })
            if let thumbnail = Self.makeCoverThumbnail(from: data) {
                return thumbnail
            }
        }

        return nil
    }

    private static func makeCoverThumbnail(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 768,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }

        let croppedImage = centerCrop(image, toAspectRatio: 3.0 / 4.0) ?? image

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.85,
        ]
        CGImageDestinationAddImage(destination, croppedImage, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    private static func centerCrop(_ image: CGImage, toAspectRatio aspectRatio: CGFloat) -> CGImage? {
        guard image.width > 0, image.height > 0, aspectRatio > 0 else { return nil }

        let sourceRatio = CGFloat(image.width) / CGFloat(image.height)
        let cropWidth: Int
        let cropHeight: Int

        if sourceRatio > aspectRatio {
            cropHeight = image.height
            cropWidth = max(
                1,
                min(image.width, Int((CGFloat(cropHeight) * aspectRatio).rounded(.down)))
            )
        } else {
            cropWidth = image.width
            cropHeight = max(
                1,
                min(image.height, Int((CGFloat(cropWidth) / aspectRatio).rounded(.down)))
            )
        }

        let originX = (image.width - cropWidth) / 2
        let originY = (image.height - cropHeight) / 2
        let cropRect = CGRect(
            x: originX,
            y: originY,
            width: cropWidth,
            height: cropHeight
        )
        return image.cropping(to: cropRect)
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

    static func htmlToText(_ html: String) -> String {
        guard let doc = try? SwiftSoup.parse(html),
              let body = try? doc.body() else {
            return Self.legacyHtmlToText(html)
        }

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
