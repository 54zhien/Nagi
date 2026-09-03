
import Foundation

struct EPUBReadingContentProvider: Sendable {
    private let parser = EPUBParser()

    func loadChapterContent(url: URL, href: String) throws -> String {
        try parser.loadChapterContent(url: url, href: href)
    }
}
