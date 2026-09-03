
import Foundation
import SwiftData
import Observation

struct BookImportResult: Sendable {
    let title: String
    let author: String?
    let format: BookFormat
    let sourceURL: String
    let chapterCount: Int
    let coverData: Data?
    let readerAssetURL: String?

    func makeBook() -> Book {
        Book(
            title: title,
            author: author,
            format: format,
            sourceURL: sourceURL,
            chapterCount: chapterCount,
            coverData: coverData,
            readerAssetURL: readerAssetURL
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
        let importedFiles: [URL]
        do {
            importedFiles = try FileImportService().importFiles(urls)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let files = importedFiles
        Task {
            var results: [BookImportResult] = []
            do {
                results = try await Self.parseBooksInBackground(files)
                try Self.upsert(results, into: context)
                try context.save()
            } catch {
                for result in results {
                    TXTReaderAssetStore.removeAsset(atPath: result.readerAssetURL)
                }
                errorMessage = error.localizedDescription
            }
        }
    }

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
                }
            }
            return covers
        }
        return await task.value
    }

    nonisolated static func parseBooksInBackground(_ files: [URL]) async throws -> [BookImportResult] {
        let task = Task.detached(priority: .userInitiated) {
            var results: [BookImportResult] = []
            let parserFactory = BookImportParserFactory()
            var generatedAssetPaths: [String] = []

            do {
                for fileURL in files {
                    try Task.checkCancellation()
                    let format = try parserFactory.format(for: fileURL)
                    let parser = try parserFactory.parser(for: fileURL)
                    let parsed = try parser.parse(url: fileURL)

                    var readerAssetURL: String?
                    if format == .txt {
                        let assetURL = try TXTReaderAssetStore.makeAssetURL()
                        try TXTReaderAssetBuilder.build(
                            parsed: parsed,
                            destinationURL: assetURL
                        )
                        readerAssetURL = assetURL.path
                        generatedAssetPaths.append(assetURL.path)
                    }

                    results.append(BookImportResult(
                        title: parsed.title,
                        author: parsed.author,
                        format: format,
                        sourceURL: fileURL.path,
                        chapterCount: parsed.chapterCount,
                        coverData: parsed.coverData,
                        readerAssetURL: readerAssetURL
                    ))
                }
            } catch {
                for path in generatedAssetPaths {
                    TXTReaderAssetStore.removeAsset(atPath: path)
                }
                throw error
            }
            return results
        }
        return try await task.value
    }

    static func upsert(_ results: [BookImportResult], into context: ModelContext) throws {
        var existingBooks = try context.fetch(FetchDescriptor<Book>())
        for result in results {
            if let existing = existingBooks.first(where: { $0.sourceURL == result.sourceURL }) {
                existing.author = result.author
                existing.formatRaw = result.format.rawValue
                existing.chapterCount = result.chapterCount
                existing.coverData = result.coverData
                existing.readerAssetURL = result.readerAssetURL
            } else {
                let book = result.makeBook()
                context.insert(book)
                existingBooks.append(book)
            }
        }
    }


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

    func delete(_ book: Book, context: ModelContext) {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: book.sourceURL))
        TXTReaderAssetStore.removeAsset(atPath: book.readerAssetURL)
        context.delete(book)
        do {
            try context.save()
        } catch {
            errorMessage = "删除失败：\(error.localizedDescription)"
        }
    }
}
