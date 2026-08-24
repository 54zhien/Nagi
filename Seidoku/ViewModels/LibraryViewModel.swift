//
//  LibraryViewModel.swift
//  Seidoku
//
//  书库视图模型：导入 → 解析 → 生成 Book 存入 SwiftData。
//  复制文件在完成回调里同步做（security-scoped 权限有效期内），解析放后台线程避免卡主线程。
//

import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class LibraryViewModel {
    var errorMessage: String?

    /// 导入并解析文件。
    func importAndParse(_ urls: [URL], into context: ModelContext) {
        // 第一步：复制到沙盒（同步，在 fileImporter 回调内，security-scoped 权限仍有效）
        let importedFiles: [URL]
        do {
            importedFiles = try FileImportService().importFiles(urls)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        // 第二步：后台解析（读沙盒文件，无权限问题），完成后回主线程存库
        let files = importedFiles
        Task.detached(priority: .userInitiated) {
            do {
                let books = try Self.parseBooks(files)
                await MainActor.run {
                    for book in books {
                        context.insert(book)
                    }
                    do {
                        try context.save()
                    } catch {
                        self.errorMessage = error.localizedDescription
                    }
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    self.errorMessage = message
                }
            }
        }
    }

    /// 后台解析：按扩展名分派 TXT/EPUB 解析器。
    nonisolated private static func parseBooks(_ files: [URL]) throws -> [Book] {
        var books: [Book] = []
        for fileURL in files {
            switch fileURL.pathExtension.lowercased() {
            case "txt":
                let parsed = try TXTParser().parse(url: fileURL)
                books.append(Book(
                    title: parsed.title,
                    author: parsed.author,
                    format: .txt,
                    sourceURL: fileURL.path,
                    chapterCount: parsed.chapterCount
                ))
            case "epub":
                let parsed = try EPUBParser().parse(url: fileURL)
                books.append(Book(
                    title: parsed.title,
                    author: parsed.author,
                    format: .epub,
                    sourceURL: fileURL.path,
                    chapterCount: parsed.chapterCount
                ))
            default:
                throw ParseError.cannotRead("不支持的文件格式：\(fileURL.pathExtension)")
            }
        }
        return books
    }
}
