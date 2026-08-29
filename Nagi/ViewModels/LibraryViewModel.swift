//
//  LibraryViewModel.swift
//  Nagi
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
    let coverData: Data?

    func makeBook() -> Book {
        Book(
            title: title,
            author: author,
            format: format,
            sourceURL: sourceURL,
            chapterCount: chapterCount,
            coverData: coverData
        )
    }
}

private struct BookCoverRequest: Sendable {
    let id: UUID
    let sourceURL: String
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
                try Self.upsert(results, into: context)
                try context.save()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Backfills covers for EPUB records created before cover extraction was
    /// wired into the import pipeline.  Only file paths and UUIDs cross the
    /// detached task; SwiftData objects remain on the main actor.
    func backfillMissingCovers(for books: [Book], into context: ModelContext) {
        let requests = books.compactMap { book -> BookCoverRequest? in
            guard book.format == .epub, book.coverData == nil else { return nil }
            return BookCoverRequest(id: book.id, sourceURL: book.sourceURL)
        }
        guard !requests.isEmpty else { return }

        Task {
            let covers = await Self.loadMissingCoversInBackground(requests)
            guard !covers.isEmpty else { return }

            let currentBooks = (try? context.fetch(FetchDescriptor<Book>())) ?? []
            var didUpdate = false
            for book in currentBooks {
                guard book.coverData == nil, let coverData = covers[book.id] else { continue }
                book.coverData = coverData
                didUpdate = true
            }

            if didUpdate {
                try? context.save()
            }
        }
    }

    private static func loadMissingCoversInBackground(
        _ requests: [BookCoverRequest]
    ) async -> [UUID: Data] {
        let task = Task.detached(priority: .utility) {
            let parser = EPUBParser()
            var covers: [UUID: Data] = [:]
            for request in requests {
                do {
                    if let coverData = try parser.loadCoverData(
                        url: URL(fileURLWithPath: request.sourceURL)
                    ) {
                        covers[request.id] = coverData
                    }
                } catch {
                    // A missing or malformed cover must not prevent other
                    // library records from being backfilled.
                }
            }
            return covers
        }
        return await task.value
    }

    /// 后台解析，返回纯值（不创建 @Model 对象）。
    nonisolated static func parseBooksInBackground(_ files: [URL]) async throws -> [BookImportResult] {
        let task = Task.detached(priority: .userInitiated) {
            var results: [BookImportResult] = []
            let parserFactory = BookImportParserFactory()
            for fileURL in files {
                let parser = try parserFactory.parser(for: fileURL)
                let parsed = try parser.parse(url: fileURL)
                results.append(BookImportResult(
                    title: parsed.title,
                    author: parsed.author,
                    format: try parserFactory.format(for: fileURL),
                    sourceURL: fileURL.path,
                    chapterCount: parsed.chapterCount,
                    coverData: parsed.coverData
                ))
            }
            return results
        }
        return try await task.value
    }

    /// Keep one SwiftData record per imported sandbox path. Re-importing a
    /// replaced file updates its metadata instead of creating a duplicate
    /// Book that points to the same physical TXT.
    static func upsert(_ results: [BookImportResult], into context: ModelContext) throws {
        var existingBooks = try context.fetch(FetchDescriptor<Book>())
        for result in results {
            if let existing = existingBooks.first(where: { $0.sourceURL == result.sourceURL }) {
                existing.author = result.author
                existing.formatRaw = result.format.rawValue
                existing.chapterCount = result.chapterCount
                existing.coverData = result.coverData
            } else {
                let book = result.makeBook()
                context.insert(book)
                existingBooks.append(book)
            }
        }
    }

    // MARK: - 书库操作

    /// 重命名：改文件名 + 改书名。
    func rename(_ book: Book, to newName: String, context: ModelContext) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let oldURL = URL(fileURLWithPath: book.sourceURL)
        let ext = oldURL.pathExtension
        let newURL = oldURL.deletingLastPathComponent()
            .appendingPathComponent(trimmed)
            .appendingPathExtension(ext)

        if oldURL.lastPathComponent != newURL.lastPathComponent {
            do {
                try FileManager.default.moveItem(at: oldURL, to: newURL)
            } catch {
                errorMessage = "重命名失败：\(error.localizedDescription)"
                return
            }
        }

        book.title = trimmed
        book.sourceURL = newURL.path
        do {
            try context.save()
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    /// 删除：删文件 + 删 SwiftData 记录。
    func delete(_ book: Book, context: ModelContext) {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: book.sourceURL))
        context.delete(book)
        do {
            try context.save()
        } catch {
            errorMessage = "删除失败：\(error.localizedDescription)"
        }
    }
}
