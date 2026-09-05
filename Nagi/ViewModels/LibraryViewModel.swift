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
}

private struct BookCoverRequest: Sendable {
    let id: UUID
    let sourceURL: String
}

private struct ProgressiveImportRequest: Sendable {
    let bookID: UUID
    let operationID: UUID
    let sourceURL: URL
    let destinationPath: String
    let holdsSecurityScopedAccess: Bool
}

private struct RecoveredImportRequest: Sendable {
    let bookID: UUID
    let operationID: UUID
    let processingURL: URL
    let stagedURL: URL?
    let destinationPath: String
}

@MainActor
@Observable
final class LibraryViewModel {
    var errorMessage: String?

    func importAndParse(
        _ urls: [URL],
        into context: ModelContext,
        completion: (([String], [String]) -> Void)? = nil
    ) {
        let parserFactory = BookImportParserFactory()
        var requests: [ProgressiveImportRequest] = []
        var preparationFailures: [String] = []

        for url in urls {
            do {
                let format = try parserFactory.format(for: url)
                let operationID = UUID()
                let holdsSecurityScopedAccess = url.startAccessingSecurityScopedResource()
                let book = Book(
                    title: url.deletingPathExtension().lastPathComponent,
                    author: nil,
                    format: format,
                    sourceURL: "Imports/.pending/\(operationID.uuidString)"
                )
                let fileExtension = url.pathExtension.lowercased()
                let destinationPath = "Imports/Books/\(book.id.uuidString)/source.\(fileExtension)"
                book.sourceURL = destinationPath
                context.insert(book)

                book.importState = .importing
                book.importOperationID = operationID
                book.importStagingPath = FileImportService.stagingPersistedPath(
                    operationID: operationID,
                    fileExtension: url.pathExtension
                )
                book.importErrorMessage = nil
                requests.append(
                    ProgressiveImportRequest(
                        bookID: book.id,
                        operationID: operationID,
                        sourceURL: url,
                        destinationPath: destinationPath,
                        holdsSecurityScopedAccess: holdsSecurityScopedAccess
                    )
                )
            } catch {
                preparationFailures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }

        do {
            try context.save()
        } catch {
            errorMessage = "无法显示导入任务：\(error.localizedDescription)"
            for request in requests where request.holdsSecurityScopedAccess {
                request.sourceURL.stopAccessingSecurityScopedResource()
            }
            completion?([], preparationFailures + [error.localizedDescription])
            return
        }

        Task {
            var importedTitles: [String] = []
            var failures = preparationFailures

            for request in requests {
                defer {
                    if request.holdsSecurityScopedAccess {
                        request.sourceURL.stopAccessingSecurityScopedResource()
                    }
                }
                var stagedURL: URL?
                do {
                    stagedURL = try await Self.stageInBackground(
                        request.sourceURL,
                        operationID: request.operationID
                    )
                    guard let book = Self.book(
                        id: request.bookID,
                        operationID: request.operationID,
                        in: context
                    ) else {
                        if let stagedURL { try? FileManager.default.removeItem(at: stagedURL) }
                        continue
                    }

                    book.importStagingPath = stagedURL.map {
                        BookFileLocator.persistedPath(for: $0)
                    }
                    try context.save()

                    guard let stagedURL else { continue }
                    let parsedResult = try await Self.parseBookInBackground(stagedURL)
                    guard Self.book(
                        id: request.bookID,
                        operationID: request.operationID,
                        in: context
                    ) != nil else {
                        try? FileManager.default.removeItem(at: stagedURL)
                        continue
                    }

                    try await Self.commitInBackground(
                        stagedURL,
                        destinationPath: request.destinationPath
                    )
                    let result = BookImportResult(
                        title: parsedResult.title,
                        author: parsedResult.author,
                        format: parsedResult.format,
                        sourceURL: request.destinationPath,
                        chapterCount: parsedResult.chapterCount,
                        coverData: parsedResult.coverData
                    )
                    guard let committedBook = Self.book(
                        id: request.bookID,
                        operationID: request.operationID,
                        in: context
                    ) else {
                        Self.removeImportedFileIfOrphaned(request.destinationPath, in: context)
                        continue
                    }

                    Self.apply(result, to: committedBook)
                    try context.save()
                    importedTitles.append(committedBook.title)
                } catch {
                    let message = error.localizedDescription
                    failures.append("\(request.sourceURL.lastPathComponent)：\(message)")
                    if let book = Self.book(
                        id: request.bookID,
                        operationID: request.operationID,
                        in: context
                    ) {
                        book.importState = .failed
                        book.importOperationID = nil
                        book.importStagingPath = stagedURL.map {
                            BookFileLocator.persistedPath(for: $0)
                        }
                        book.importErrorMessage = message
                        try? context.save()
                    }
                }
            }

            if !failures.isEmpty {
                errorMessage = failures.joined(separator: "\n")
            }
            completion?(importedTitles, failures)
        }
    }

    static func resumeInterruptedImports(in context: ModelContext) {
        let interrupted = ((try? context.fetch(FetchDescriptor<Book>())) ?? [])
            .filter { $0.importState == .importing }
        var requests: [RecoveredImportRequest] = []

        for book in interrupted {
            let stagedURL = book.importStagingPath
                .flatMap { BookFileLocator.resolve($0) }
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            let committedURL = BookFileLocator.resolve(book.sourceURL)
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            guard let processingURL = stagedURL ?? committedURL else {
                book.importState = .failed
                book.importOperationID = nil
                book.importErrorMessage = "导入被中断，请重新导入"
                continue
            }

            let operationID = book.importOperationID ?? UUID()
            book.importOperationID = operationID
            requests.append(
                RecoveredImportRequest(
                    bookID: book.id,
                    operationID: operationID,
                    processingURL: processingURL,
                    stagedURL: stagedURL,
                    destinationPath: book.sourceURL
                )
            )
        }
        try? context.save()

        Task {
            for request in requests {
                do {
                    try await finishRecoveredImport(
                        id: request.bookID,
                        operationID: request.operationID,
                        processingURL: request.processingURL,
                        stagedURL: request.stagedURL,
                        destinationPath: request.destinationPath,
                        context: context
                    )
                } catch {
                    guard let currentBook = book(
                        id: request.bookID,
                        operationID: request.operationID,
                        in: context
                    ) else { continue }
                    currentBook.importState = .failed
                    currentBook.importOperationID = nil
                    currentBook.importErrorMessage = error.localizedDescription
                    try? context.save()
                }
            }
        }
    }

    func retryImport(_ book: Book, in context: ModelContext) {
        let stagedURL = book.importStagingPath
            .flatMap { BookFileLocator.resolve($0) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let committedURL = BookFileLocator.resolve(book.sourceURL)
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        guard let processingURL = stagedURL ?? committedURL else {
            errorMessage = "源文件不存在，请重新选择并导入这本书"
            return
        }

        let operationID = UUID()
        let bookID = book.id
        let destinationPath = book.sourceURL
        book.importState = .importing
        book.importOperationID = operationID
        book.importErrorMessage = nil
        try? context.save()

        Task {
            do {
                try await Self.finishRecoveredImport(
                    id: bookID,
                    operationID: operationID,
                    processingURL: processingURL,
                    stagedURL: stagedURL,
                    destinationPath: destinationPath,
                    context: context
                )
            } catch {
                guard let currentBook = Self.book(
                    id: bookID,
                    operationID: operationID,
                    in: context
                ) else { return }
                currentBook.importState = .failed
                currentBook.importOperationID = nil
                currentBook.importErrorMessage = error.localizedDescription
                errorMessage = error.localizedDescription
                try? context.save()
            }
        }
    }

    /// Backfills covers for EPUB records created before cover extraction was
    /// wired into the import pipeline.  Only file paths and UUIDs cross the
    /// detached task; SwiftData objects remain on the main actor.
    func backfillMissingCovers(for books: [Book], into context: ModelContext) {
        let requests = books.compactMap { book -> BookCoverRequest? in
            guard book.format == .epub,
                  book.coverData == nil,
                  let sourceURL = BookFileLocator.resolve(book.sourceURL) else {
                return nil
            }
            return BookCoverRequest(
                id: book.id,
                sourceURL: sourceURL.path
            )
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

    private nonisolated static func stageInBackground(
        _ sourceURL: URL,
        operationID: UUID
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try FileImportService().stageFile(sourceURL, operationID: operationID)
        }.value
    }

    private nonisolated static func commitInBackground(
        _ stagedURL: URL,
        destinationPath: String
    ) async throws {
        guard let destinationURL = BookFileLocator.resolve(destinationPath) else {
            throw ParseError.cannotRead("无法定位导入目录")
        }
        try await Task.detached(priority: .userInitiated) {
            try FileImportService().commitStagedFile(stagedURL, to: destinationURL)
        }.value
    }

    private nonisolated static func parseBookInBackground(
        _ fileURL: URL
    ) async throws -> BookImportResult {
        try await Task.detached(priority: .userInitiated) {
            try makeImportResult(for: fileURL)
        }.value
    }

    private nonisolated static func makeImportResult(for fileURL: URL) throws -> BookImportResult {
        try Task.checkCancellation()
        let parserFactory = BookImportParserFactory()
        let format = try parserFactory.format(for: fileURL)
        let parsed: ParsedBook
        if format == .txt {
            parsed = try TXTParser().parseMetadata(url: fileURL)
        } else {
            parsed = try parserFactory.parser(for: fileURL).parse(url: fileURL)
        }

        return BookImportResult(
            title: parsed.title,
            author: parsed.author,
            format: format,
            sourceURL: BookFileLocator.persistedPath(for: fileURL),
            chapterCount: parsed.chapterCount,
            coverData: parsed.coverData
        )
    }

    private static func finishRecoveredImport(
        id: UUID,
        operationID: UUID,
        processingURL: URL,
        stagedURL: URL?,
        destinationPath: String,
        context: ModelContext
    ) async throws {
        let parsedResult = try await parseBookInBackground(processingURL)
        guard book(id: id, operationID: operationID, in: context) != nil else { return }

        if let stagedURL {
            try await commitInBackground(stagedURL, destinationPath: destinationPath)
        }

        guard let currentBook = book(id: id, operationID: operationID, in: context) else {
            removeImportedFileIfOrphaned(destinationPath, in: context)
            return
        }
        let result = BookImportResult(
            title: parsedResult.title,
            author: parsedResult.author,
            format: parsedResult.format,
            sourceURL: destinationPath,
            chapterCount: parsedResult.chapterCount,
            coverData: parsedResult.coverData
        )
        apply(result, to: currentBook)
        try context.save()
    }

    private static func apply(_ result: BookImportResult, to book: Book) {
        TXTReaderAssetStore.removeAsset(atPath: book.readerAssetURL)
        book.title = result.title
        book.author = result.author
        book.formatRaw = result.format.rawValue
        book.sourceURL = result.sourceURL
        book.chapterCount = result.chapterCount
        book.coverData = result.coverData
        book.readerAssetURL = nil
        book.importState = .ready
        book.importOperationID = nil
        book.importStagingPath = nil
        book.importErrorMessage = nil
    }

    private static func book(
        id: UUID,
        operationID: UUID,
        in context: ModelContext
    ) -> Book? {
        ((try? context.fetch(FetchDescriptor<Book>())) ?? []).first {
            $0.id == id && $0.importOperationID == operationID
        }
    }

    private static func removeImportedFileIfOrphaned(
        _ storedPath: String,
        in context: ModelContext
    ) {
        let hasOwner = ((try? context.fetch(FetchDescriptor<Book>())) ?? []).contains {
            BookFileLocator.normalizedPersistedPath($0.sourceURL) == storedPath
        }
        guard !hasOwner, let fileURL = BookFileLocator.resolve(storedPath) else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - 书库操作

    static func migrateStoredFileLocations(in context: ModelContext) {
        guard let books = try? context.fetch(FetchDescriptor<Book>()) else { return }
        var changed = false

        for book in books {
            let sourcePath = BookFileLocator.normalizedPersistedPath(book.sourceURL)
            if sourcePath != book.sourceURL {
                book.sourceURL = sourcePath
                changed = true
            }

            if let assetPath = book.readerAssetURL {
                let normalizedAssetPath = BookFileLocator.normalizedPersistedPath(assetPath)
                if normalizedAssetPath != assetPath {
                    book.readerAssetURL = normalizedAssetPath
                    changed = true
                }
            }

            if let stagingPath = book.importStagingPath {
                let normalizedStagingPath = BookFileLocator.normalizedPersistedPath(stagingPath)
                if normalizedStagingPath != stagingPath {
                    book.importStagingPath = normalizedStagingPath
                    changed = true
                }
            }
        }

        if changed {
            try? context.save()
        }
    }

    /// 重命名：改文件名 + 改书名。
    func rename(_ book: Book, to newName: String, context: ModelContext) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains("\\") else {
            errorMessage = "书名不能包含路径分隔符"
            return
        }

        guard let oldURL = BookFileLocator.resolve(book.sourceURL) else {
            errorMessage = "无法定位源文件，请重新导入这本书"
            return
        }
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
        book.sourceURL = BookFileLocator.persistedPath(for: newURL)
        do {
            try context.save()
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    /// 删除：删文件 + 删 SwiftData 记录。
    func delete(_ book: Book, context: ModelContext) {
        if let sourceURL = BookFileLocator.resolve(book.sourceURL) {
            try? FileManager.default.removeItem(at: sourceURL)
        }
        TXTReaderAssetStore.removeAsset(atPath: book.readerAssetURL)
        TXTReaderAssetStore.removeAsset(atPath: book.importStagingPath)
        context.delete(book)
        do {
            try context.save()
        } catch {
            errorMessage = "删除失败：\(error.localizedDescription)"
        }
    }
}
