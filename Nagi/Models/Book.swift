
import Foundation
import SwiftData

enum BookFormat: String, Codable, Sendable, Hashable {
    case epub
    case txt
}

@Model
final class Book {
    var id: UUID
    var title: String
    var author: String?
    var formatRaw: String
    var sourceURL: String
    var coverData: Data?
    var addedAt: Date
    var lastReadAt: Date?
    var chapterCount: Int
    var currentChapterIndex: Int
    var currentChapterTitle: String?
    var progressPercent: Double
    var readerLocatorJSON: String?
    var readerAssetURL: String?
    var txtReadingLocationJSON: String?

    init(
        title: String,
        author: String?,
        format: BookFormat,
        sourceURL: String,
        chapterCount: Int = 0,
        coverData: Data? = nil,
        readerAssetURL: String? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.author = author
        self.formatRaw = format.rawValue
        self.sourceURL = sourceURL
        self.coverData = coverData
        self.addedAt = .now
        self.chapterCount = chapterCount
        self.currentChapterIndex = 0
        self.currentChapterTitle = nil
        self.progressPercent = 0
        self.readerLocatorJSON = nil
        self.readerAssetURL = readerAssetURL
        self.txtReadingLocationJSON = nil
    }

    var format: BookFormat {
        BookFormat(rawValue: formatRaw) ?? .txt
    }
}
