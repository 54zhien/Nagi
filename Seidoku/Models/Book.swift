//
//  Book.swift
//  Seidoku
//
//  书籍元数据模型（SwiftData）。正文不存这里，只存元数据 + 进度。
//

import Foundation
import SwiftData

enum BookFormat: String, Codable {
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
    var progressPercent: Double
    /// Readium Locator JSON。相比页码，它能在字号、边距和方向变化后恢复到同一内容位置。
    var readerLocatorJSON: String?
    /// TXT 的章节 + UTF-16 锚点；页码只由当前布局临时计算。
    var txtReadingLocationJSON: String?

    init(title: String, author: String?, format: BookFormat, sourceURL: String, chapterCount: Int = 0) {
        self.id = UUID()
        self.title = title
        self.author = author
        self.formatRaw = format.rawValue
        self.sourceURL = sourceURL
        self.addedAt = .now
        self.chapterCount = chapterCount
        self.currentChapterIndex = 0
        self.progressPercent = 0
        self.readerLocatorJSON = nil
        self.txtReadingLocationJSON = nil
    }

    var format: BookFormat {
        BookFormat(rawValue: formatRaw) ?? .txt
    }
}
