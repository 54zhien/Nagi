//
//  LibraryViewModel.swift
//  Seidoku
//
//  书库视图模型：导入 → 解析 → 生成 Book 存入 SwiftData。
//

import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class LibraryViewModel {
    private let importService = FileImportService()
    private let txtParser = TXTParser()
    private let epubParser = EPUBParser()

    var errorMessage: String?
    var importCount = 0

    /// 导入并解析文件，生成 Book 存入 context。
    func importAndParse(_ urls: [URL], into context: ModelContext) {
        do {
            let importedFiles = try importService.importFiles(urls)
            var count = 0
            for fileURL in importedFiles {
                let book = try parseBook(fileURL)
                context.insert(book)
                count += 1
            }
            try context.save()
            importCount = count
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func parseBook(_ url: URL) throws -> Book {
        switch url.pathExtension.lowercased() {
        case "txt":
            let parsed = try txtParser.parse(url: url)
            return Book(
                title: parsed.title,
                author: parsed.author,
                format: .txt,
                sourceURL: url.path,
                chapterCount: parsed.chapterCount
            )
        case "epub":
            let parsed = try epubParser.parse(url: url)
            return Book(
                title: parsed.title,
                author: parsed.author,
                format: .epub,
                sourceURL: url.path,
                chapterCount: parsed.chapterCount
            )
        default:
            throw ParseError.cannotRead("不支持的文件格式：\(url.pathExtension)")
        }
    }
}
