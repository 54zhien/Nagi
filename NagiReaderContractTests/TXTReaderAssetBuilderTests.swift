import Foundation
import XCTest
@testable import Nagi

/// Reads real generated ZIP entries and XML, rather than testing private string builders.
final class TXTReaderAssetBuilderTests: XCTestCase {
    // Catches missing, extra or misrouted resources even when creating a ZIP succeeds.
    func testArchiveInventoryAndContainerPointToReadablePackage() throws {
        let entries = try build(chapters: threeChapters())
        XCTAssertEqual(Set(entries.keys), Set([
            "mimetype", "META-INF/container.xml", "OEBPS/styles.css",
            "OEBPS/content.opf", "OEBPS/nav.xhtml",
            "OEBPS/chapter-1.xhtml", "OEBPS/chapter-2.xhtml", "OEBPS/chapter-3.xhtml",
        ]))
        XCTAssertEqual(try text(entries, "mimetype"), "application/epub+zip")
        let container = try xml(entries, "META-INF/container.xml")
        XCTAssertEqual(container.named("rootfile").map { $0.attributes["full-path"] }, ["OEBPS/content.opf"])
        XCTAssertEqual(container.named("rootfile").map { $0.attributes["media-type"] }, ["application/oebps-package+xml"])
    }

    // Catches malformed consumer XML; the separate control-character attachment is diagnostic, not support evidence.
    func testArchiveXMLIsWellFormedForSupportedText() throws {
        let entries = try build(chapters: threeChapters())
        for path in ["META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml",
                     "OEBPS/chapter-1.xhtml", "OEBPS/chapter-2.xhtml", "OEBPS/chapter-3.xhtml"] {
            let parsed = try xml(entries, path)
            XCTAssertFalse(parsed.elements.isEmpty, path)
        }
        XCTAssertEqual(try xml(entries, "OEBPS/chapter-2.xhtml").named("p").map(\.text), ["甲"])
        try attachIllegalControlDiagnostic()
    }

    // Catches deleting every repeated heading, or leaving the leading heading duplicated in the body.
    func testOnlyMatchingFirstNonblankHeadingIsRemoved() throws {
        let entries = try build(chapters: [
            TXTChapter(title: "第一章 开始", content: "\n \t\n  第一章 开始  \n\n第一章 开始\n甲"),
        ])
        let chapter = try xml(entries, "OEBPS/chapter-1.xhtml")
        XCTAssertEqual(chapter.named("h1").map(\.text), ["第一章 开始"])
        XCTAssertEqual(chapter.named("p").map(\.text), ["第一章 开始\n甲"])
        XCTAssertEqual(chapter.named("br").count, 1)
    }

    // Catches removing a matching title from somewhere other than the first content line.
    func testUnmatchedFirstLineAndLaterTitleRemainBodyText() throws {
        let chapter = try xml(try build(chapters: [
            TXTChapter(title: "章节", content: "起点\n章节\n终点"),
        ]), "OEBPS/chapter-1.xhtml")
        XCTAssertEqual(chapter.named("h1").map(\.text), ["章节"])
        XCTAssertEqual(chapter.named("p").map(\.text), ["起点\n章节\n终点"])
    }

    // Catches treating the special single-chapter 正文 case like an injected heading.
    func testHeadingInjectionDependsOnChapterCountAndTitle() throws {
        let singleBody = try xml(try build(chapters: [
            TXTChapter(title: "正文", content: "正文\n甲"),
        ]), "OEBPS/chapter-1.xhtml")
        XCTAssertEqual(singleBody.named("h1").map(\.text), [])
        XCTAssertEqual(singleBody.named("p").map(\.text), ["正文\n甲"])

        let titled = try xml(try build(chapters: [
            TXTChapter(title: "章节", content: "章节\n甲"),
        ]), "OEBPS/chapter-1.xhtml")
        XCTAssertEqual(titled.named("h1").map(\.text), ["章节"])
        XCTAssertEqual(titled.named("p").map(\.text), ["甲"])

        let multiBody = try xml(try build(chapters: [
            TXTChapter(title: "正文", content: "正文\n甲"),
            TXTChapter(title: "尾声", content: "尾声\n乙"),
        ]), "OEBPS/chapter-1.xhtml")
        XCTAssertEqual(multiBody.named("h1").map(\.text), ["正文"])
        XCTAssertEqual(multiBody.named("p").map(\.text), ["甲"])
    }

    // Catches collapsed indentation, dropped intra-paragraph line breaks, or spurious empty paragraphs.
    func testBlankLinesSeparateParagraphsButInlineWhitespaceSurvives() throws {
        let entries = try build(chapters: [
            TXTChapter(title: "正文", content: "\n  first  \nnext\n \t\n\n third\tend \n\n"),
        ])
        let chapter = try xml(entries, "OEBPS/chapter-1.xhtml")
        XCTAssertEqual(chapter.named("p").map(\.text), ["  first  \nnext", " third\tend "])
        XCTAssertEqual(chapter.named("br").count, 1)
        XCTAssertTrue(try text(entries, "OEBPS/chapter-1.xhtml").contains("<p>  first  <br />\nnext</p>"))
    }

    // Catches missing escaping or interpreting literal entity-like source text as pre-escaped markup.
    func testFiveXMLMetacharactersRoundTripAcrossMetadataTOCAndBody() throws {
        let entries = try build(title: "书<>&\"' &amp;", chapters: [
            TXTChapter(title: "章<>&\"' &amp;", content: "文<>&\"' &amp;"),
        ])
        let chapter = try xml(entries, "OEBPS/chapter-1.xhtml")
        XCTAssertEqual(chapter.named("h1").map(\.text), ["章<>&\"' &amp;"])
        XCTAssertEqual(chapter.named("p").map(\.text), ["文<>&\"' &amp;"])
        XCTAssertEqual(try xml(entries, "OEBPS/nav.xhtml").named("a").map(\.text), ["章<>&\"' &amp;"])
        XCTAssertEqual(try xml(entries, "OEBPS/content.opf").named("title").map(\.text), ["书<>&\"' &amp;"])
        XCTAssertTrue(try text(entries, "OEBPS/chapter-1.xhtml").contains("文&lt;&gt;&amp;&quot;&apos; &amp;amp;"))
        XCTAssertTrue(try text(entries, "OEBPS/nav.xhtml").contains("章&lt;&gt;&amp;&quot;&apos; &amp;amp;"))
        XCTAssertTrue(try text(entries, "OEBPS/content.opf").contains("书&lt;&gt;&amp;&quot;&apos; &amp;amp;"))
    }

    // Swift String equality alone would miss NFC normalization that changes the UTF-16 axis.
    func testNonBMPAndDecomposedScalarsSurviveArchiveAndXMLConsumers() throws {
        let chapter = try xml(try build(chapters: [
            TXTChapter(title: "正文", content: "A😀e\u{0301}终"),
        ]), "OEBPS/chapter-1.xhtml")
        let body = try XCTUnwrap(chapter.named("p").first?.text)
        XCTAssertEqual(body.unicodeScalars.map(\.value), [0x41, 0x1F600, 0x65, 0x301, 0x7EC8])
    }

    // Catches a consistent-but-wrong mapping across nav/manifest/spine by checking each against literal routing.
    func testChapterMainIDsNavigationAndSpineFollowReadingOrder() throws {
        let entries = try build(chapters: threeChapters())
        let nav = try xml(entries, "OEBPS/nav.xhtml")
        XCTAssertEqual(nav.named("a").map { $0.attributes["href"] }, ["chapter-1.xhtml", "chapter-2.xhtml", "chapter-3.xhtml"])
        XCTAssertEqual(nav.named("a").map(\.text), ["书名", "第一章 开始", "第二章 结束"])
        let package = try xml(entries, "OEBPS/content.opf")
        let items = package.named("item").filter { $0.attributes["media-type"] == "application/xhtml+xml" && $0.attributes["properties"] != "nav" }
        XCTAssertEqual(items.map { $0.attributes["id"] }, ["chapter-1", "chapter-2", "chapter-3"])
        XCTAssertEqual(items.map { $0.attributes["href"] }, ["chapter-1.xhtml", "chapter-2.xhtml", "chapter-3.xhtml"])
        XCTAssertEqual(package.named("itemref").map { $0.attributes["idref"] }, ["chapter-1", "chapter-2", "chapter-3"])
        for (path, expectedID) in [("OEBPS/chapter-1.xhtml", "chapter-1"),
                                   ("OEBPS/chapter-2.xhtml", "chapter-2"),
                                   ("OEBPS/chapter-3.xhtml", "chapter-3")] {
            XCTAssertEqual(try xml(entries, path).named("main").map { $0.attributes["id"] }, [expectedID])
        }
    }

    // Catches sourceURL overloads bypassing decoding/normalization or changing the parsed-input projection.
    func testSourceURLAndParsedOverloadsHaveTheSameStableConsumerOutput() throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.txt")
        try Data("\u{FEFF}序言\r\n第一章 开始\r甲<>&\u{2028}第二章 结束\n乙".utf8).write(to: source)
        let firstURL = directory.appendingPathComponent("from-source.epub")
        let secondURL = directory.appendingPathComponent("from-parsed.epub")
        try TXTReaderAssetBuilder.build(sourceURL: source, destinationURL: firstURL)
        try TXTReaderAssetBuilder.build(parsed: TXTParser().parse(url: source), destinationURL: secondURL)
        let first = try readArchive(firstURL)
        let second = try readArchive(secondURL)
        try assertStableEntriesEqual(first, second)
        XCTAssertEqual(try xml(first, "OEBPS/chapter-1.xhtml").named("p").map(\.text), ["序言"])
        XCTAssertEqual(try xml(first, "OEBPS/chapter-2.xhtml").named("p").map(\.text), ["甲<>&"])
        XCTAssertEqual(try xml(first, "OEBPS/nav.xhtml").named("a").map(\.text), ["source", "第一章 开始", "第二章 结束"])
    }

    // Catches the legacy parsed-input fallback silently losing chapter detection when chapters is nil.
    func testMissingChapterArrayUsesRealSplitter() throws {
        let directory = try temporaryDirectory()
        let destination = directory.appendingPathComponent("fallback.epub")
        let parsed = ParsedBook(title: "书名", author: nil, chapterCount: 0,
                                content: "序言\n第一章 开始\n甲\n第二章 结束\n乙")
        try TXTReaderAssetBuilder.build(parsed: parsed, destinationURL: destination)
        let entries = try readArchive(destination)
        XCTAssertEqual(try xml(entries, "OEBPS/nav.xhtml").named("a").map(\.text), ["书名", "第一章 开始", "第二章 结束"])
        XCTAssertEqual(try xml(entries, "OEBPS/chapter-3.xhtml").named("p").map(\.text), ["乙"])
    }

    // Catches unstable body/routes while allowing the deliberately fresh publication ID and timestamp.
    func testRepeatedBuildsPreserveSemanticsRatherThanZIPBytes() throws {
        let first = try build(chapters: threeChapters())
        let second = try build(chapters: threeChapters())
        try assertStableEntriesEqual(first, second)
        let firstOPF = try xml(first, "OEBPS/content.opf")
        let secondOPF = try xml(second, "OEBPS/content.opf")
        let firstID = try XCTUnwrap(firstOPF.named("identifier").first?.text)
        let secondID = try XCTUnwrap(secondOPF.named("identifier").first?.text)
        XCTAssertTrue(firstID.hasPrefix("urn:uuid:"))
        XCTAssertTrue(secondID.hasPrefix("urn:uuid:"))
        XCTAssertNotNil(UUID(uuidString: String(firstID.dropFirst("urn:uuid:".count))))
        XCTAssertNotNil(UUID(uuidString: String(secondID.dropFirst("urn:uuid:".count))))
        XCTAssertNotEqual(firstID, secondID)
        for opf in [firstOPF, secondOPF] {
            let modified = try XCTUnwrap(opf.named("meta").first { $0.attributes["property"] == "dcterms:modified" }?.text)
            XCTAssertNotNil(ISO8601DateFormatter().date(from: modified))
        }
    }

    // Catches destructive overwrite or leaked temporary archives after a destination collision.
    func testExistingDestinationIsNotOverwritten() throws {
        let directory = try temporaryDirectory()
        let destination = directory.appendingPathComponent("existing.epub")
        let sentinel = Data("not-an-archive-sentinel".utf8)
        try sentinel.write(to: destination)
        do {
            try TXTReaderAssetBuilder.build(parsed: document(threeChapters()), destinationURL: destination)
            XCTFail("Expected destinationAlreadyExists")
        } catch TXTReaderAssetError.destinationAlreadyExists {
            // Expected boundary; the bytes below are the behavioral guarantee.
        }
        XCTAssertEqual(try Data(contentsOf: destination), sentinel)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["existing.epub"])
    }

    // Catches creating output directories or partial assets before refusing an empty document.
    func testEmptyDocumentDoesNotCreateAnAssetOrItsParentDirectory() throws {
        let directory = try temporaryDirectory()
        let parent = directory.appendingPathComponent("not-created", isDirectory: true)
        let destination = parent.appendingPathComponent("empty.epub")
        do {
            try TXTReaderAssetBuilder.build(
                parsed: ParsedBook(title: "空书", author: nil, chapterCount: 0, content: ""),
                destinationURL: destination
            )
            XCTFail("Expected emptyContent")
        } catch ParseError.emptyContent {
            // Other errors propagate and fail the test.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    // This must fail before validation exists: ZIP creation is not a valid-XML guarantee.
    func testInvalidXMLBodyScalarsAreRejectedBeforeCreatingOutput() throws {
        let directory = try temporaryDirectory()
        for value: UInt32 in [0x0000, 0x0001, 0x000B, 0x000C, 0xFFFE, 0xFFFF] {
            let scalar = try XCTUnwrap(Unicode.Scalar(value))
            let parent = directory.appendingPathComponent("scalar-\(value)", isDirectory: true)
            let destination = parent.appendingPathComponent("invalid.epub")
            let parsed = document([TXTChapter(title: "正文", content: "甲\(scalar)乙")])
            XCTAssertThrowsError(try TXTReaderAssetBuilder.build(parsed: parsed, destinationURL: destination), "U+\(String(value, radix: 16))")
            XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path), "U+\(String(value, radix: 16))")
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    // Metadata and TOC text need the same rejection, not just paragraph contents.
    func testInvalidDocumentAndChapterTitlesAreRejectedWithoutWritingFiles() throws {
        let directory = try temporaryDirectory()
        let fixtures = [
            document([TXTChapter(title: "正文", content: "有效正文")], title: "书\u{0001}名"),
            document([TXTChapter(title: "章\u{0001}名", content: "有效正文")]),
        ]
        for (index, parsed) in fixtures.enumerated() {
            let parent = directory.appendingPathComponent("title-\(index)", isDirectory: true)
            let destination = parent.appendingPathComponent("invalid.epub")
            XCTAssertThrowsError(try TXTReaderAssetBuilder.build(parsed: parsed, destinationURL: destination))
            XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    // Catches an overbroad control/ASCII filter; XML1.0 permits these whitespace and scalar-range edges.
    func testXMLLegalWhitespaceAndUnicodeRemainUnchanged() throws {
        let entries = try build(chapters: [
            TXTChapter(title: "正文", content: "A\tB\nC\rD \u{D7FF}\u{E000}\u{FFFD}\u{10000}\u{10FFFF}中文😀e\u{0301}"),
        ])
        let serialized = try text(entries, "OEBPS/chapter-1.xhtml")
        XCTAssertTrue(serialized.contains("A\tB<br />\nC\rD \u{D7FF}\u{E000}\u{FFFD}\u{10000}\u{10FFFF}中文😀e\u{0301}"))
        let body = try XCTUnwrap(xml(entries, "OEBPS/chapter-1.xhtml").named("p").first?.text)
        // Literal CR is normalized to LF by the XML consumer, not by a new TXT rule.
        XCTAssertEqual(body.unicodeScalars.map(\.value), "A\tB\nC\nD \u{D7FF}\u{E000}\u{FFFD}\u{10000}\u{10FFFF}中文😀e\u{0301}".unicodeScalars.map(\.value))
    }

    private func threeChapters() -> [TXTChapter] {
        [TXTChapter(title: "书名", content: "序言"),
         TXTChapter(title: "第一章 开始", content: "第一章 开始\n甲"),
         TXTChapter(title: "第二章 结束", content: "第二章 结束\n乙")]
    }

    private func document(_ chapters: [TXTChapter], title: String = "书名") -> ParsedBook {
        ParsedBook(title: title, author: nil, chapterCount: chapters.count,
                   content: chapters.map(\.content).joined(separator: "\n"), chapters: chapters)
    }

    private func build(title: String = "书名", chapters: [TXTChapter]) throws -> [String: Data] {
        let directory = try temporaryDirectory()
        let destination = directory.appendingPathComponent("nested", isDirectory: true).appendingPathComponent("reader.epub")
        try TXTReaderAssetBuilder.build(parsed: document(chapters, title: title), destinationURL: destination)
        return try readArchive(destination)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TXTAssetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func readArchive(_ url: URL) throws -> [String: Data] {
        let archive = try Archive(url: url, accessMode: .read)
        var entries: [String: Data] = [:]
        for entry in archive {
            var bytes = Data()
            let checksum = try archive.extract(entry) { bytes.append($0) }
            guard checksum == entry.checksum else {
                throw FixtureError.invalidArchive("CRC mismatch: \(entry.path)")
            }
            guard entries.updateValue(bytes, forKey: entry.path) == nil else {
                throw FixtureError.invalidArchive("Duplicate entry: \(entry.path)")
            }
        }
        return entries
    }

    private func text(_ entries: [String: Data], _ path: String) throws -> String {
        let data = try XCTUnwrap(entries[path], path)
        return try XCTUnwrap(String(data: data, encoding: .utf8), path)
    }

    private func xml(_ entries: [String: Data], _ path: String) throws -> XMLProbe {
        let data = try XCTUnwrap(entries[path], path)
        let probe = XMLProbe()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = probe
        guard parser.parse() else {
            throw FixtureError.invalidXML("\(path): \(String(describing: parser.parserError))")
        }
        return probe
    }

    private func assertStableEntriesEqual(_ first: [String: Data], _ second: [String: Data]) throws {
        XCTAssertEqual(Set(first.keys), Set(second.keys))
        for path in first.keys where path != "OEBPS/content.opf" {
            XCTAssertEqual(first[path], second[path], path)
        }
        let firstOPF = try xml(first, "OEBPS/content.opf")
        let secondOPF = try xml(second, "OEBPS/content.opf")
        // Only the text of these leaves varies; their namespace, attributes and position still matter.
        func stable(_ probe: XMLProbe) -> [XMLProbe.Element] {
            probe.elements.map { element in
                var result = element
                if (element.name == "identifier" && element.namespace == "http://purl.org/dc/elements/1.1/") ||
                    (element.name == "meta" && element.attributes["property"] == "dcterms:modified") {
                    result.text = ""
                }
                return result
            }
        }
        XCTAssertEqual(stable(firstOPF), stable(secondOPF))
    }

    private func attachIllegalControlDiagnostic() throws {
        let directory = try temporaryDirectory()
        for (label, text) in [("NUL", "甲\u{0000}乙"), ("SOH", "甲\u{0001}乙"), ("VT", "甲\u{000B}乙")] {
            let destination = directory.appendingPathComponent("\(label).epub")
            let observation: String
            do {
                try TXTReaderAssetBuilder.build(parsed: document([TXTChapter(title: "正文", content: text)]), destinationURL: destination)
                let entries = try readArchive(destination)
                guard let data = entries["OEBPS/chapter-1.xhtml"] else {
                    throw FixtureError.invalidArchive("Missing chapter-1.xhtml")
                }
                let parser = XMLParser(data: data)
                parser.shouldResolveExternalEntities = false
                let accepted = parser.parse()
                observation = "\(label): build=succeeded XMLParser.accepted=\(accepted) error=\(String(describing: parser.parserError))"
            } catch {
                observation = "\(label): build/read rejected: \(error)"
            }
            print("TXT_XML_CONTROL_DIAGNOSTIC \(observation)")
            let attachment = XCTAttachment(string: observation)
            attachment.name = "Non-gating XML control diagnostic: \(label)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private enum FixtureError: Error {
        case invalidXML(String)
        case invalidArchive(String)
    }

    private final class XMLProbe: NSObject, XMLParserDelegate {
        struct Element: Equatable {
            let name: String
            let namespace: String?
            let attributes: [String: String]
            var text = ""
        }
        var elements: [Element] = []
        private var stack: [Int] = []

        func named(_ name: String) -> [Element] { elements.filter { $0.name == name } }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            stack.append(elements.count)
            elements.append(Element(name: elementName, namespace: namespaceURI, attributes: attributeDict))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if let index = stack.last { elements[index].text += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = stack.popLast()
        }
    }
}
