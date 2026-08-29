//
//  Book.swift
//  Nagi
//
//  书籍元数据模型（SwiftData）。正文不存这里，只存元数据 + 进度。
//

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
    var formatRaw: String          // BookFormat.rawValue
    var sourceURL: String          // 沙盒内文件路径
    var coverData: Data?
    var addedAt: Date
    var lastReadAt: Date?
    var chapterCount: Int
    // 阅读进度
    var currentChapterIndex: Int
    var currentChapterTitle: String?
    var progressPercent: Double
    /// Readium Locator JSON，TXT 也使用同一字段保存字符锚点。
    var readerLocatorJSON: String?
    /// TXT 的字符锚点；与 EPUB 的 Readium Locator 分开保存，避免两种格式互相覆盖。
    var txtReadingLocationJSON: String?

    init(
        title: String,
        author: String?,
        format: BookFormat,
        sourceURL: String,
        chapterCount: Int = 0,
        coverData: Data? = nil
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
        self.txtReadingLocationJSON = nil
    }

    var format: BookFormat {
        BookFormat(rawValue: formatRaw) ?? .txt
    }
}
