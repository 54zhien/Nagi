
import Foundation

enum TXTReaderAssetError: LocalizedError {
    case cannotLocateDocumentsDirectory
    case destinationAlreadyExists
    case archiveCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotLocateDocumentsDirectory:
            return "无法定位阅读资源目录"
        case .destinationAlreadyExists:
            return "阅读资源文件已存在"
        case .archiveCreationFailed(let message):
            return "生成 TXT 阅读资源失败：\(message)"
        }
    }
}

enum TXTReaderAssetStore {
    static func makeAssetURL(fileManager: FileManager = .default) throws -> URL {
        guard let documentsURL = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw TXTReaderAssetError.cannotLocateDocumentsDirectory
        }

        let directoryURL = documentsURL
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent("ReaderAssets", isDirectory: true)

        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw TXTReaderAssetError.archiveCreationFailed(error.localizedDescription)
        }

        return directoryURL
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension("epub")
    }

    static func removeAsset(atPath path: String?, fileManager: FileManager = .default) {
        guard let path, !path.isEmpty else { return }
        try? fileManager.removeItem(at: URL(fileURLWithPath: path))
    }
}

private struct TXTReaderDocument: Sendable {
    let title: String
    let text: String
    let chapters: [TXTChapter]
}

enum TXTReaderAssetBuilder {
    static func build(
        sourceURL: URL,
        destinationURL: URL
    ) throws {
        let parsed = try TXTParser().parse(url: sourceURL)
        try build(parsed: parsed, destinationURL: destinationURL)
    }

    static func build(
        parsed: ParsedBook,
        destinationURL: URL
    ) throws {
        let chapters = parsed.chapters ?? TXTParser.splitIntoChapters(
            parsed.content,
            fallbackTitle: parsed.title
        )
        try build(
            document: TXTReaderDocument(
                title: parsed.title,
                text: parsed.content,
                chapters: chapters
            ),
            destinationURL: destinationURL
        )
    }

    private static func build(
        document: TXTReaderDocument,
        destinationURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard !document.text.isEmpty else {
            throw ParseError.emptyContent
        }
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw TXTReaderAssetError.destinationAlreadyExists
        }

        let directoryURL = destinationURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw TXTReaderAssetError.archiveCreationFailed(error.localizedDescription)
        }

        let temporaryURL = directoryURL
            .appendingPathComponent(".\(UUID().uuidString).tmp", isDirectory: false)
            .appendingPathExtension("epub")
        defer { try? fileManager.removeItem(at: temporaryURL) }

        do {
            try writeArchive(document: document, to: temporaryURL)
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        } catch let error as TXTReaderAssetError {
            throw error
        } catch {
            throw TXTReaderAssetError.archiveCreationFailed(error.localizedDescription)
        }
    }

    private static func writeArchive(document: TXTReaderDocument, to url: URL) throws {
        let archive = try Archive(url: url, accessMode: .create)
        let chapterFiles = document.chapters.enumerated().map { index, _ in
            "chapter-\(index + 1).xhtml"
        }

        try add(
            Data("application/epub+zip".utf8),
            path: "mimetype",
            compression: .none,
            to: archive
        )
        try add(
            Data(containerXML.utf8),
            path: "META-INF/container.xml",
            compression: .deflate,
            to: archive
        )
        try add(
            Data(stylesheet.utf8),
            path: "OEBPS/styles.css",
            compression: .deflate,
            to: archive
        )

        for (index, chapter) in document.chapters.enumerated() {
            let chapterHTML = chapterHTML(
                document: document,
                chapter: chapter,
                index: index
            )
            try add(
                Data(chapterHTML.utf8),
                path: "OEBPS/\(chapterFiles[index])",
                compression: .deflate,
                to: archive
            )
        }

        try add(
            Data(navigationHTML(document: document, chapterFiles: chapterFiles).utf8),
            path: "OEBPS/nav.xhtml",
            compression: .deflate,
            to: archive
        )
        try add(
            Data(packageOPF(document: document, chapterFiles: chapterFiles).utf8),
            path: "OEBPS/content.opf",
            compression: .deflate,
            to: archive
        )
    }

    private static func add(
        _ data: Data,
        path: String,
        compression: CompressionMethod,
        to archive: Archive
    ) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: compression
        ) { position, size in
            guard position >= 0, position <= Int64(data.count), size > 0 else {
                return Data()
            }

            let start = Int(position)
            let length = min(size, data.count - start)
            guard length > 0 else { return Data() }
            return data.subdata(in: start ..< start + length)
        }
    }

    private static func chapterHTML(
        document: TXTReaderDocument,
        chapter: TXTChapter,
        index: Int
    ) -> String {
        let title = xmlEscaped(chapter.title)
        let includesHeading = document.chapters.count > 1 || chapter.title != "正文"
        let body = bodyMarkup(
            text: chapter.content,
            chapterTitle: includesHeading ? chapter.title : nil
        )
        let heading = includesHeading ? "<h1>\(title)</h1>" : ""

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN" xml:lang="zh-CN">
          <head>
            <meta charset="utf-8" />
            <title>\(title)</title>
            <link rel="stylesheet" type="text/css" href="styles.css" />
          </head>
          <body>
            <main id="chapter-\(index + 1)">
              \(heading)
              \(body)
            </main>
          </body>
        </html>
        """
    }

    private static func bodyMarkup(text: String, chapterTitle: String?) -> String {
        var lines = text.components(separatedBy: "\n")
        if let chapterTitle,
           let firstContentIndex = lines.firstIndex(where: {
               !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
           }),
           lines[firstContentIndex].trimmingCharacters(in: .whitespacesAndNewlines) == chapterTitle {
            lines.remove(at: firstContentIndex)
        }

        var blocks: [[String]] = []
        var currentBlock: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !currentBlock.isEmpty {
                    blocks.append(currentBlock)
                    currentBlock.removeAll(keepingCapacity: true)
                }
            } else {
                currentBlock.append(line)
            }
        }
        if !currentBlock.isEmpty {
            blocks.append(currentBlock)
        }

        return blocks.map { block in
            let content = xmlEscaped(block.joined(separator: "\n"))
                .replacingOccurrences(of: "\n", with: "<br />\n")
            return "<p>\(content)</p>"
        }.joined(separator: "\n")
    }

    private static func navigationHTML(
        document: TXTReaderDocument,
        chapterFiles: [String]
    ) -> String {
        let items = zip(document.chapters, chapterFiles).map { chapter, file in
            "<li><a href=\"\(file)\">\(xmlEscaped(chapter.title))</a></li>"
        }.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN" xml:lang="zh-CN">
          <head><meta charset="utf-8" /><title>目录</title></head>
          <body>
            <nav epub:type="toc" xmlns:epub="http://www.idpf.org/2007/ops" id="toc">
              <h1>目录</h1>
              <ol>
                \(items)
              </ol>
            </nav>
          </body>
        </html>
        """
    }

    private static func packageOPF(
        document: TXTReaderDocument,
        chapterFiles: [String]
    ) -> String {
        let identifier = "urn:uuid:\(UUID().uuidString.lowercased())"
        let modified = ISO8601DateFormatter().string(from: .now)
        let manifestChapters = chapterFiles.enumerated().map { index, file in
            "<item id=\"chapter-\(index + 1)\" href=\"\(file)\" media-type=\"application/xhtml+xml\" />"
        }.joined(separator: "\n    ")
        let spineChapters = chapterFiles.enumerated().map { index, _ in
            "<itemref idref=\"chapter-\(index + 1)\" />"
        }.joined(separator: "\n    ")

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id" prefix="dcterms: http://purl.org/dc/terms/">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="book-id">\(identifier)</dc:identifier>
            <dc:title>\(xmlEscaped(document.title))</dc:title>
            <dc:language>zh</dc:language>
            <meta property="dcterms:modified">\(modified)</meta>
          </metadata>
          <manifest>
            <item id="nav" properties="nav" href="nav.xhtml" media-type="application/xhtml+xml" />
            <item id="style" href="styles.css" media-type="text/css" />
            \(manifestChapters)
          </manifest>
          <spine>
            \(spineChapters)
          </spine>
        </package>
        """
    }

    private static let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml" />
      </rootfiles>
    </container>
    """

    private static let stylesheet = """
    html, body, main {
      box-sizing: border-box;
      max-width: 100%;
    }

    html, body {
      margin: 0;
      padding: 0;
    }

    body {
      overflow-wrap: anywhere;
      word-break: break-word;
    }

    *, *::before, *::after {
      box-sizing: inherit;
    }

    main {
      margin: 0;
      padding: 0;
    }

    h1 {
      max-width: 100%;
      margin: 0 0 1.25em;
      overflow-wrap: anywhere;
      word-break: break-word;
    }

    p {
      max-width: 100%;
      margin: 0 0 0.85em;
      overflow-wrap: anywhere;
      word-break: break-word;
    }
    """

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

@MainActor
enum ReaderAssetResolver {
    static func resolve(book: Book) async throws -> URL {
        let sourceURL = URL(fileURLWithPath: book.sourceURL)
        guard book.format == .txt else { return sourceURL }

        if let assetPath = book.readerAssetURL,
           FileManager.default.fileExists(atPath: assetPath) {
            return URL(fileURLWithPath: assetPath)
        }

        let assetURL = try TXTReaderAssetStore.makeAssetURL()
        do {
            try await Task.detached(priority: .userInitiated) {
                try TXTReaderAssetBuilder.build(
                    sourceURL: sourceURL,
                    destinationURL: assetURL
                )
            }.value
        } catch {
            TXTReaderAssetStore.removeAsset(atPath: assetURL.path)
            throw error
        }

        do {
            try Task.checkCancellation()
        } catch {
            TXTReaderAssetStore.removeAsset(atPath: assetURL.path)
            throw error
        }
        book.readerAssetURL = assetURL.path
        return assetURL
    }
}
