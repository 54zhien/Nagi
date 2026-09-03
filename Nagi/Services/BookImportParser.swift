
import Foundation

protocol BookImportParser: Sendable {
    func parse(url: URL) throws -> ParsedBook
}

struct TXTImportParser: BookImportParser {
    func parse(url: URL) throws -> ParsedBook {
        try TXTParser().parse(url: url)
    }
}

struct EPUBImportParser: BookImportParser {
    func parse(url: URL) throws -> ParsedBook {
        try EPUBParser().parse(url: url)
    }
}

struct BookImportParserFactory: Sendable {
    func parser(for url: URL) throws -> any BookImportParser {
        switch url.pathExtension.lowercased() {
        case let fileExtension where TXTParser.supportedExtensions.contains(fileExtension):
            return TXTImportParser()
        case "epub":
            return EPUBImportParser()
        default:
            throw ParseError.cannotRead("不支持的文件格式：\(url.pathExtension)")
        }
    }

    func format(for url: URL) throws -> BookFormat {
        switch url.pathExtension.lowercased() {
        case let fileExtension where TXTParser.supportedExtensions.contains(fileExtension):
            return .txt
        case "epub":
            return .epub
        default:
            throw ParseError.cannotRead("不支持的文件格式：\(url.pathExtension)")
        }
    }
}
