//
//  LibraryViewModel.swift
//  Seidoku
//
//  书库视图模型：导入 → 解析 → 生成 Book 存入 SwiftData。
//  复制文件同步做（security-scoped 权限有效期内）；解析在后台返回纯值，主线程创建 Book 存库。
//

import Foundation
import SwiftData
import Observation

/// 解析结果（纯值，可跨线程传递）。
struct BookImportResult: Sendable {
    let title: String
    let author: String?
    let format: BookFormat
    let sourceURL: String
    let chapterCount: Int

    func makeBook() -> Book {
        Book(title: title, author: author, format: format, sourceURL: sourceURL, chapterCount: chapterCount)
    }
}

@MainActor
@Observable
final class LibraryViewModel {
    var errorMessage: String?

    func importAndParse(_ urls: [URL], into context: ModelContext) {
        // 第一步：复制到沙盒（同步，在 fileImporter 回调内，security-scoped 权限仍有效）
        let importedFiles: [URL]
        do {
            importedFiles = try FileImportService().importFiles(urls)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        // 第二步：后台解析返回纯值，主线程创建 Book 存入 SwiftData（不跨线程碰 ModelContext）
        let files = importedFiles
        Task {
            do {
                let results = try await Self.parseBooksInBackground(files)
                for result in results {
                    context.insert(result.makeBook())
                }
                try context.save()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 后台解析，返回纯值（不创建 @Model 对象）。
    nonisolated static func parseBooksInBackground(_ files: [URL]) async throws -> [BookImportResult] {
        let task = Task.detached(priority: .userInitiated) {
            var results: [BookImportResult] = []
            for fileURL in files {
                switch fileURL.pathExtension.lowercased() {
                case "txt":
                    let parsed = try TXTParser().parse(url: fileURL)
                    results.append(BookImportResult(
                        title: parsed.title, author: parsed.author,
                        format: .txt, sourceURL: fileURL.path,
                        chapterCount: parsed.chapterCount
                    ))
                case "epub":
                    let parsed = try EPUBParser().parse(url: fileURL)
                    results.append(BookImportResult(
                        title: parsed.title, author: parsed.author,
                        format: .epub, sourceURL: fileURL.path,
                        chapterCount: parsed.chapterCount
                    ))
                default:
                    throw ParseError.cannotRead("不支持的文件格式：\(fileURL.pathExtension)")
                }
            }
            return results
        }
        return try await task.value
    }
}
