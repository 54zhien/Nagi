//
//  TXTReaderModel.swift
//  Nagi
//
//  TXT 阅读状态、章节切分、TextKit 分页和排版偏好。
//

import Foundation
import Observation
import SwiftUI
import UIKit

private struct TXTLayoutSnapshot: @unchecked Sendable {
    let text: String
    let existingAttributedText: NSAttributedString?
    let pageSize: CGSize
    let insets: UIEdgeInsets
    let pageRange: NSRange
    let maximumPages: Int
    let shouldPaginate: Bool
    let fontScale: Double
    let fontFamily: ReaderFontFamily
    let boldText: Bool
    let lineHeight: Double
    let paragraphIndent: Double
    let foregroundColor: UIColor
}

private struct TXTLayoutResult: @unchecked Sendable {
    let attributedText: NSAttributedString
    let pageBatch: TextPaginator.PageBatch?
}

@MainActor
@Observable
final class TXTReaderModel {
    private struct TXTReadingLocation: Codable {
        let version: Int
        let format: String
        var chapterIndex: Int
        var characterOffset: Int
        var chapterFraction: Double
    }

    let book: Book

    // 章节与当前位置
    var title: String
    var chapters: [BookChapter] = []
    var currentChapterIndex: Int
    var pages: [NSAttributedString] = []
    private(set) var pageRanges: [NSRange] = []
    var currentPageIndex = 0 {
        didSet {
            guard currentPageIndex != oldValue, !suppressPageProgress else { return }
            updateReadingProgress()
        }
    }
    var fullText = NSAttributedString(string: "")

    // 与 EPUB 主题控件共用的排版值域
    var fontScale: Double { didSet { styleDidChange() } }
    var fontFamily: ReaderFontFamily { didSet { styleDidChange() } }
    var boldText: Bool { didSet { styleDidChange() } }
    var lineHeight: Double { didSet { styleDidChange() } }
    var paragraphIndent: Double { didSet { styleDidChange() } }
    var pageMargins: Double { didSet { styleDidChange() } }
    var contentTopInset: Double { didSet { styleDidChange() } }
    var contentBottomInset: Double { didSet { styleDidChange() } }
    var theme: ReaderTheme { didSet { styleDidChange() } }
    var flowMode: ReaderFlowMode { didSet { flowModeDidChange() } }
    var pageTransition: ReaderPageTransitionMode { didSet { persistPreferences() } }
    var showBookTitleInPageHeader: Bool { didSet { persistPreferences() } }

    // 由阅读视图注入的全屏 viewport；分页和正文边距都以此为唯一基准。
    var pageSize = CGSize.zero
    var safeAreaInsets = UIEdgeInsets.zero

    var isLoading = false
    var errorMessage: String?
    private(set) var layoutGeneration = 0

    private var chapterLengths: [Int] = []
    /// UTF-16 offsets of each chapter inside `currentContent`.  Keeping the
    /// source as one continuous string makes TXT pagination behave like the
    /// EPUB spine instead of stopping at every chapter boundary.
    private var chapterStartOffsets: [Int] = []
    private var currentContent = ""
    private var hasLoaded = false
    private var pendingCharacterOffset: Int?
    private var currentCharacterOffset = 0
    private var pendingScrollProgress: Double?
    private var scrollPositionGeneration = 0
    private var suppressPageProgress = false
    private var layoutTask: Task<Void, Never>?
    private var nextPageTask: Task<Void, Never>?
    private var previousPageTask: Task<Void, Never>?
    private var layoutRequestID = 0
    private var persistenceTask: Task<Void, Never>?

    private var nextPageOffset: Int?
    private var hasMorePreviousPages = false

    private static let pageBatchSize = 8
    private static let pageBatchCharacterLimit = 128_000

    private enum PreferenceKey {
        static let fontScale = "reader.txt.fontScale"
        static let fontFamily = "reader.txt.fontFamily"
        static let boldText = "reader.txt.boldText"
        static let lineHeight = "reader.txt.lineHeight"
        static let paragraphIndent = "reader.txt.paragraphIndent"
        static let pageMargins = "reader.txt.pageMargins"
        static let contentTopInset = "reader.txt.contentTopInset"
        static let contentBottomInset = "reader.txt.contentBottomInset"
        static let theme = "reader.txt.theme"
        static let flowMode = "reader.txt.flowMode"
        static let pageTransition = "reader.txt.pageTransition"
        static let showBookTitleInPageHeader = "reader.txt.showBookTitleInPageHeader"
    }

    init(book: Book) {
        self.book = book
        title = book.title
        currentChapterIndex = max(book.currentChapterIndex, 0)

        let defaults = UserDefaults.standard
        fontScale = defaults.object(forKey: PreferenceKey.fontScale) as? Double ?? 1.0
        fontFamily = defaults.string(forKey: PreferenceKey.fontFamily)
            .flatMap(ReaderFontFamily.init) ?? .systemSerif
        boldText = defaults.object(forKey: PreferenceKey.boldText) as? Bool ?? false
        lineHeight = defaults.object(forKey: PreferenceKey.lineHeight) as? Double ?? 1.5
        paragraphIndent = defaults.object(forKey: PreferenceKey.paragraphIndent) as? Double ?? 2.0
        pageMargins = defaults.object(forKey: PreferenceKey.pageMargins) as? Double ?? 1.0
        contentTopInset = defaults.object(forKey: PreferenceKey.contentTopInset) as? Double ?? 56
        contentBottomInset = defaults.object(forKey: PreferenceKey.contentBottomInset) as? Double ?? 32
        theme = defaults.string(forKey: PreferenceKey.theme).flatMap(ReaderTheme.init) ?? .light
        flowMode = defaults.string(forKey: PreferenceKey.flowMode).flatMap(ReaderFlowMode.init) ?? .paged
        pageTransition = defaults.string(forKey: PreferenceKey.pageTransition)
            .flatMap(ReaderPageTransitionMode.init) ?? .pageCurl
        showBookTitleInPageHeader = defaults.object(forKey: PreferenceKey.showBookTitleInPageHeader)
            as? Bool ?? false
    }

    // MARK: - 加载

    func load() async {
        guard !hasLoaded, !isLoading else { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let parsed = try await Self.parseInBackground(url: URL(fileURLWithPath: book.sourceURL))
            guard !Task.isCancelled else { return }

            title = book.title.isEmpty ? parsed.title : book.title
            let content = parsed.content
            let fallbackTitle = title
            let parsedChapters: [TXTChapter]
            if let chapters = parsed.chapters {
                parsedChapters = chapters
            } else {
                parsedChapters = await Task.detached(priority: .utility) {
                    TXTParser.splitIntoChapters(content, fallbackTitle: fallbackTitle)
                }.value
            }
            guard !parsedChapters.isEmpty else { throw ParseError.emptyContent }

            let chapterTexts = parsedChapters.map { $0.content }
            chapterLengths = chapterTexts.map { $0.utf16.count }
            chapterStartOffsets = makeChapterStartOffsets(for: chapterTexts)
            currentContent = chapterTexts.joined(separator: "\n\n")
            chapters = parsedChapters.enumerated().map { index, chapter in
                BookChapter(
                    id: "txt-\(index)",
                    title: chapter.title,
                    href: "txt://\(index)",
                    index: index
                )
            }
            let savedLocation = decodedReadingLocation()
            let savedChapter = savedLocation?.chapterIndex ?? book.currentChapterIndex
            currentChapterIndex = min(max(savedChapter, 0), chapters.count - 1)
            hasLoaded = true
            loadCurrentChapter(restorePosition: true)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private nonisolated static func parseInBackground(url: URL) async throws -> ParsedBook {
        try await Task.detached(priority: .utility) {
            try TXTParser().parse(url: url)
        }.value
    }

    func loadCurrentChapter(showLastPage: Bool = false, restorePosition: Bool = false) {
        guard chapters.indices.contains(currentChapterIndex),
              chapterLengths.indices.contains(currentChapterIndex) else { return }

        let savedLocation = restorePosition ? decodedReadingLocation() : nil
        let targetOffset: Int
        if restorePosition, let savedLocation {
            targetOffset = globalOffset(for: savedLocation)
        } else if restorePosition {
            targetOffset = globalOffsetForLegacyBookPosition()
        } else if showLastPage {
            targetOffset = max(chapterEndOffset(for: currentChapterIndex) - 1, chapterStartOffset(for: currentChapterIndex))
        } else {
            targetOffset = chapterStartOffset(for: currentChapterIndex)
        }

        pendingCharacterOffset = targetOffset
        currentCharacterOffset = targetOffset

        // Scrolling uses one continuous text view and does not need a page
        // rebuild for a chapter jump.  Changing the position ID in
        // `selectChapter` moves that view to the new anchor.
        if flowMode == .scroll,
           fullText.length > 0,
           fullText.length == currentContent.utf16.count {
            currentChapterIndex = chapterIndex(forGlobalOffset: targetOffset)
            persistReadingLocation()
            return
        }

        // A generated page can be reused for a TOC jump.  Only rebuild when
        // the requested anchor is outside the currently materialized window.
        if flowMode == .paged,
           fullText.length > 0,
           let targetPage = pageIndexIfContaining(targetOffset, in: pageRanges) {
            suppressPageProgress = true
            currentPageIndex = targetPage
            suppressPageProgress = false
            currentCharacterOffset = targetOffset
            currentChapterIndex = chapterIndex(forGlobalOffset: targetOffset)
            pendingCharacterOffset = nil
            persistReadingLocation()
            return
        }

        // The first load and a jump outside the current page window need a
        // fresh batch.  Keep the attributed text during a jump when possible;
        // the page view will show the normal progress state until the batch is
        // ready, without duplicating the full book in memory.
        if flowMode == .paged {
            pages = []
            pageRanges = []
            nextPageOffset = nil
            hasMorePreviousPages = false
        } else if fullText.length == 0 {
            fullText = NSAttributedString(string: "")
        }

        suppressPageProgress = true
        currentPageIndex = 0
        suppressPageProgress = false

        let startOffset = showLastPage
            ? max(targetOffset - Self.pageBatchCharacterLimit, 0)
            : targetOffset
        requestRepagination(startOffset: startOffset)
    }

    // MARK: - 分页与排版

    func updateViewport(size: CGSize, safeAreaInsets: UIEdgeInsets) {
        // SwiftUI can report a transient zero-sized geometry while the
        // reader surface is being inserted.  Starting a layout for that
        // value only creates an empty result and makes the real layout race
        // with it.
        guard size.width > 1, size.height > 1 else { return }
        let sizeChanged = pageSize != size
        let insetsChanged = self.safeAreaInsets != safeAreaInsets
        guard sizeChanged || insetsChanged else { return }
        pageSize = size
        self.safeAreaInsets = safeAreaInsets
        requestRepagination()
    }

    var readerInsets: UIEdgeInsets {
        let horizontal = max(0, CGFloat(pageMargins) * 24)
        return UIEdgeInsets(
            // ReaderChrome 负责控件布局；正文仍要避开设备的所有安全区。
            top: max(CGFloat(contentTopInset), safeAreaInsets.top),
            left: max(horizontal, safeAreaInsets.left),
            bottom: max(CGFloat(contentBottomInset), safeAreaInsets.bottom),
            right: max(horizontal, safeAreaInsets.right)
        )
    }

    private func requestRepagination(
        startOffset requestedStartOffset: Int? = nil,
        rebuildAttributedText: Bool = false
    ) {
        guard !currentContent.isEmpty else { return }

        let shouldPaginate = flowMode == .paged
        // The initial load can finish before GeometryReader reports a usable
        // viewport.  Never fall back to a full-book attributed layout for a
        // paged reader in that transient state; wait for updateViewport and
        // generate the first bounded batch there.
        guard !shouldPaginate || (pageSize.width > 1 && pageSize.height > 1) else {
            return
        }

        layoutRequestID &+= 1
        let requestID = layoutRequestID
        let requestedAnchor = clampCharacterOffset(
            requestedStartOffset
                ?? pendingCharacterOffset
                ?? currentCharacterOffset
        )
        // A pagination window needs at least one character.  A saved
        // progression of exactly 1.0 should open on the final page instead of
        // producing an empty batch forever; scrolling can still use the exact
        // end offset below.
        let anchor = shouldPaginate && !currentContent.isEmpty
            ? min(requestedAnchor, currentContent.utf16.count - 1)
            : requestedAnchor
        let documentLength = currentContent.utf16.count
        let pageRangeEnd = shouldPaginate
            ? min(documentLength, anchor + Self.pageBatchCharacterLimit)
            : documentLength
        let pageRange = NSRange(
            location: anchor,
            length: max(pageRangeEnd - anchor, 0)
        )
        let hasCompleteAttributedText = fullText.length == documentLength
        let snapshot = TXTLayoutSnapshot(
            text: currentContent,
            existingAttributedText: shouldPaginate
                || rebuildAttributedText
                || !hasCompleteAttributedText
                ? nil
                : fullText,
            pageSize: pageSize,
            insets: readerInsets,
            pageRange: pageRange,
            maximumPages: shouldPaginate ? Self.pageBatchSize : 0,
            shouldPaginate: shouldPaginate,
            fontScale: fontScale,
            fontFamily: fontFamily,
            boldText: boldText,
            lineHeight: lineHeight,
            paragraphIndent: paragraphIndent,
            foregroundColor: theme.foregroundUIColor
        )
        let restoreCharacterOffset = pendingCharacterOffset

        layoutTask?.cancel()
        nextPageTask?.cancel()
        previousPageTask?.cancel()
        nextPageTask = nil
        previousPageTask = nil
        layoutTask = Task { [weak self] in
            do {
                // Coalesce a slider's rapid updates into one layout request.
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return
            }

            let worker = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                if snapshot.shouldPaginate,
                   snapshot.pageSize.width > 0,
                   snapshot.pageSize.height > 0 {
                    let paged = try Self.makePagedLayout(
                        from: snapshot,
                        shouldCancel: { Task.isCancelled }
                    )
                    return TXTLayoutResult(
                        attributedText: paged.attributedText,
                        pageBatch: paged.pageBatch
                    )
                } else {
                    let attributed = snapshot.existingAttributedText ?? Self.attributedText(
                        from: snapshot.text,
                        snapshot: snapshot,
                        shouldCancel: { Task.isCancelled }
                    )
                    try Task.checkCancellation()
                    return TXTLayoutResult(
                        attributedText: attributed,
                        pageBatch: nil
                    )
                }
            }

            let result: TXTLayoutResult
            do {
                result = try await withTaskCancellationHandler(operation: {
                    try await worker.value
                }, onCancel: {
                    worker.cancel()
                })
            } catch {
                worker.cancel()
                return
            }

            guard !Task.isCancelled,
                  let self,
                  self.layoutRequestID == requestID else { return }
            self.applyLayout(
                result,
                restoreCharacterOffset: restoreCharacterOffset
            )
        }
    }

    private func applyLayout(
        _ result: TXTLayoutResult,
        restoreCharacterOffset: Int?
    ) {
        fullText = result.attributedText
        layoutGeneration &+= 1

        guard flowMode == .paged else {
            pages = []
            pageRanges = []
            nextPageOffset = nil
            hasMorePreviousPages = false
            let targetOffset = clampCharacterOffset(
                restoreCharacterOffset ?? currentCharacterOffset
            )
            currentCharacterOffset = targetOffset
            currentChapterIndex = chapterIndex(forGlobalOffset: targetOffset)
            pendingCharacterOffset = targetOffset
            return
        }

        guard let pageBatch = result.pageBatch else {
            pendingCharacterOffset = restoreCharacterOffset
            return
        }

        pages = pageBatch.pages.map(\.attributedText)
        pageRanges = pageBatch.pages.map(\.characterRange)
        nextPageOffset = pageBatch.isComplete
            ? nil
            : max(
                pageBatch.nextCharacterOffset,
                pageRanges.last.map { NSMaxRange($0) } ?? anchorOffset
            )
        hasMorePreviousPages = pageRanges.first?.location ?? 0 > 0

        guard !pages.isEmpty else {
            pendingCharacterOffset = restoreCharacterOffset
            return
        }

        let targetOffset: Int
        if let restoreCharacterOffset {
            targetOffset = clampCharacterOffset(restoreCharacterOffset)
        } else {
            targetOffset = clampCharacterOffset(currentCharacterOffset)
        }

        let targetPage = pageIndex(containing: targetOffset, in: pageRanges)
        let hasExplicitAnchor = restoreCharacterOffset != nil
        currentCharacterOffset = flowMode == .scroll || hasExplicitAnchor
            ? targetOffset
            : pageRanges[targetPage].location
        currentChapterIndex = chapterIndex(forGlobalOffset: currentCharacterOffset)
        suppressPageProgress = true
        currentPageIndex = min(max(targetPage, 0), pages.count - 1)
        suppressPageProgress = false
        pendingCharacterOffset = flowMode == .scroll ? targetOffset : nil
        if flowMode == .paged {
            if hasExplicitAnchor {
                persistReadingLocation()
            } else {
                updateReadingProgress()
            }
        }

        // A restored location may start in the middle of the book.  Materialize
        // one preceding batch in the background so the first reverse swipe is
        // available immediately instead of hitting the window boundary.
        if hasMorePreviousPages {
            requestPreviousPageBatch()
        }
        // Extremely large type or a very short source range can produce only
        // one page in the first batch.  Fill one more batch before the user
        // gets a chance to swipe into an empty data-source boundary.
        if pages.count < 2, nextPageOffset != nil {
            requestNextPageBatch()
        }
    }

    private var anchorOffset: Int {
        clampCharacterOffset(pendingCharacterOffset ?? currentCharacterOffset)
    }

    private func pageIndex(containing characterOffset: Int, in ranges: [NSRange]) -> Int {
        guard !ranges.isEmpty else { return 0 }
        let offset = max(0, characterOffset)
        for (index, range) in ranges.enumerated() {
            if offset < NSMaxRange(range) {
                return index
            }
        }
        return ranges.count - 1
    }

    private func pageIndexIfContaining(
        _ characterOffset: Int,
        in ranges: [NSRange]
    ) -> Int? {
        guard !ranges.isEmpty else { return nil }
        let offset = max(0, characterOffset)
        for (index, range) in ranges.enumerated() {
            if offset >= range.location, offset < NSMaxRange(range) {
                return index
            }
        }
        return nil
    }

    private nonisolated static func attributedText(
        from text: String,
        snapshot: TXTLayoutSnapshot,
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> NSAttributedString {
        let fontSize = CGFloat(max(12, min(72, 17 * snapshot.fontScale)))
        let baseFont = snapshot.fontFamily.uiFont(ofSize: fontSize)
        let font: UIFont = {
            guard snapshot.boldText,
                  let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitBold)
            else {
                return baseFont
            }
            return UIFont(descriptor: descriptor, size: baseFont.pointSize)
        }()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = max(0, font.lineHeight * CGFloat(snapshot.lineHeight - 1))
        paragraphStyle.paragraphSpacing = font.lineHeight * 0.65
        // Use the final Dynamic Type-scaled font so the indent follows the
        // glyph metrics instead of drifting when a font family is changed.
        paragraphStyle.firstLineHeadIndent = font.pointSize * CGFloat(snapshot.paragraphIndent)
        paragraphStyle.lineBreakMode = .byWordWrapping

        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .paragraphStyle: paragraphStyle,
            .foregroundColor: snapshot.foregroundColor,
        ])
        let string = text as NSString
        var location = 0
        while location < string.length {
            if shouldCancel() {
                return attributed
            }

            var paragraphStart = 0
            var paragraphEnd = 0
            var contentsEnd = 0
            string.getParagraphStart(
                &paragraphStart,
                end: &paragraphEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )

            var style = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
            let hasBlankLineBefore = paragraphStart == 0 || (
                paragraphStart >= 2
                    && string.substring(with: NSRange(location: paragraphStart - 2, length: 2)) == "\n\n"
            )
            if !hasBlankLineBefore {
                // A single newline is usually a hard-wrapped source line, not
                // a new prose paragraph.  Do not indent or add paragraph gap.
                style.firstLineHeadIndent = 0
                style.paragraphSpacing = 0
            }

            // Some TXT files already contain a full-width space, tab, or a
            // conventional two-space indent.  Keep that source indentation,
            // but do not add the theme indent on top of it.
            let contentLength = max(contentsEnd - paragraphStart, 0)
            if contentLength > 0 {
                let firstCharacter = string.character(at: paragraphStart)
                let hasSourceIndent = firstCharacter == 0x3000
                    || firstCharacter == 0x0009
                    || (firstCharacter == 0x0020
                        && contentLength > 1
                        && string.character(at: paragraphStart + 1) == 0x0020)
                if hasSourceIndent {
                    style.firstLineHeadIndent = 0
                }
            }
            attributed.addAttribute(
                .paragraphStyle,
                value: style,
                range: NSRange(location: paragraphStart, length: paragraphEnd - paragraphStart)
            )

            guard paragraphEnd > location else { break }
            location = paragraphEnd
        }
        return attributed
    }

    /// Build attributes and pages for one bounded UTF-16 window.  Paged TXT
    /// reading must never create an attributed string for the whole book just
    /// to display the first screen; the source string remains cheap to share,
    /// while TextKit only receives the requested window.
    private nonisolated static func makePagedLayout(
        from snapshot: TXTLayoutSnapshot,
        shouldCancel: @Sendable () -> Bool
    ) throws -> (
        attributedText: NSAttributedString,
        pageBatch: TextPaginator.PageBatch
    ) {
        try Task.checkCancellation()

        let source = snapshot.text as NSString
        let range = snapshot.pageRange
        guard range.length > 0 else {
            return (
                NSAttributedString(string: ""),
                TextPaginator.PageBatch(
                    pages: [],
                    nextCharacterOffset: range.location,
                    isComplete: true
                )
            )
        }

        let localText = source.substring(with: range)
        let attributed = attributedText(
            from: localText,
            snapshot: snapshot,
            shouldCancel: shouldCancel
        )
        try Task.checkCancellation()

        let localBatch = try TextPaginator.paginateBatch(
            attributed,
            pageSize: snapshot.pageSize,
            insets: snapshot.insets,
            range: NSRange(location: 0, length: attributed.length),
            maximumPages: snapshot.maximumPages
        )
        let globalPages = localBatch.pages.map { page in
            TextPaginator.Page(
                attributedText: page.attributedText,
                characterRange: NSRange(
                    location: range.location + page.characterRange.location,
                    length: page.characterRange.length
                )
            )
        }
        let globalNextOffset = range.location + localBatch.nextCharacterOffset
        let globalBatch = TextPaginator.PageBatch(
            pages: globalPages,
            nextCharacterOffset: globalNextOffset,
            isComplete: globalNextOffset >= snapshot.text.utf16.count
        )
        return (attributed, globalBatch)
    }

    static func attributedText(from text: String, settings: TXTReaderModel) -> NSAttributedString {
        let snapshot = TXTLayoutSnapshot(
            text: text,
            existingAttributedText: nil,
            pageSize: settings.pageSize,
            insets: settings.readerInsets,
            pageRange: NSRange(location: 0, length: text.utf16.count),
            maximumPages: 0,
            shouldPaginate: false,
            fontScale: settings.fontScale,
            fontFamily: settings.fontFamily,
            boldText: settings.boldText,
            lineHeight: settings.lineHeight,
            paragraphIndent: settings.paragraphIndent,
            foregroundColor: settings.theme.foregroundUIColor
        )
        return attributedText(from: text, snapshot: snapshot)
    }

    // MARK: - 翻页与目录

    var currentChapter: BookChapter? {
        guard chapters.indices.contains(currentChapterIndex) else { return nil }
        return chapters[currentChapterIndex]
    }

    var currentChapterID: String? {
        currentChapter?.id
    }

    /// Changes only for an explicit TOC jump.  The current chapter itself is
    /// updated continuously while scrolling, but that must not make the
    /// `UITextView` reset its content offset at every chapter boundary.
    var scrollPositionID: String {
        "txt-position-\(scrollPositionGeneration)"
    }

    /// Initial position supplied to the UIKit scroll view.  A character
    /// anchor wins when one was persisted; otherwise the continuous book
    /// progress provides a stable fallback.
    var initialScrollCharacterOffset: Int? {
        if let pendingCharacterOffset {
            return pendingCharacterOffset
        }
        return currentCharacterOffset > 0 ? currentCharacterOffset : nil
    }

    var initialScrollProgress: Double {
        if let pendingCharacterOffset {
            return globalProgress(forGlobalOffset: pendingCharacterOffset)
        }
        if let pendingScrollProgress {
            return pendingScrollProgress
        }
        if currentContent.isEmpty {
            return min(max(book.progressPercent, 0), 1)
        }
        return globalProgress(forGlobalOffset: currentCharacterOffset)
    }

    func selectChapter(_ chapter: BookChapter) {
        guard chapters.indices.contains(chapter.index), chapter.index != currentChapterIndex else { return }
        currentChapterIndex = chapter.index
        scrollPositionGeneration &+= 1
        loadCurrentChapter()
    }

    /// Called by the page controller when the reader is close to the end of
    /// the materialized window.  More pages are generated off the main actor
    /// and appended without rebuilding the already visible controller.
    func requestNextPageBatch() {
        guard flowMode == .paged,
              nextPageTask == nil,
              let nextPageOffset,
              nextPageOffset < currentContent.utf16.count,
              !pages.isEmpty,
              pageSize.width > 0,
              pageSize.height > 0 else { return }

        let requestID = layoutRequestID
        let documentLength = currentContent.utf16.count
        let end = min(
            documentLength,
            nextPageOffset + Self.pageBatchCharacterLimit
        )
        let snapshot = makePageLayoutSnapshot(
            range: NSRange(location: nextPageOffset, length: end - nextPageOffset),
            maximumPages: Self.pageBatchSize
        )

        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let paged = try Self.makePagedLayout(
                from: snapshot,
                shouldCancel: { Task.isCancelled }
            )
            return paged.pageBatch
        }

        nextPageTask = Task { [weak self] in
            let batch: TextPaginator.PageBatch
            do {
                batch = try await withTaskCancellationHandler(operation: {
                    try await worker.value
                }, onCancel: {
                    worker.cancel()
                })
            } catch {
                worker.cancel()
                if self?.layoutRequestID == requestID {
                    self?.nextPageTask = nil
                }
                return
            }

            guard !Task.isCancelled,
                  let self,
                  self.layoutRequestID == requestID else {
                if self?.layoutRequestID == requestID {
                    self?.nextPageTask = nil
                }
                return
            }
            self.append(nextPageBatch: batch)
            self.nextPageTask = nil
        }
    }

    /// Called when the user reaches the beginning of a lazily materialized
    /// window after a TOC jump or a restored location.
    func requestPreviousPageBatch() {
        guard flowMode == .paged,
              previousPageTask == nil,
              hasMorePreviousPages,
              let firstPageStart = pageRanges.first?.location,
              firstPageStart > 0,
              !pages.isEmpty,
              pageSize.width > 0,
              pageSize.height > 0 else { return }

        let requestID = layoutRequestID
        let start = max(firstPageStart - Self.pageBatchCharacterLimit, 0)
        let snapshot = makePageLayoutSnapshot(
            range: NSRange(location: start, length: firstPageStart - start),
            // Generate the whole bounded prefix so that taking its suffix
            // really produces pages adjacent to the current window.  The
            // source is still capped at 128k UTF-16 units, never the book.
            maximumPages: Int.max
        )

        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let expanded = try Self.makePagedLayout(
                from: snapshot,
                shouldCancel: { Task.isCancelled }
            )
            return TextPaginator.PageBatch(
                pages: Array(expanded.pageBatch.pages.suffix(Self.pageBatchSize)),
                nextCharacterOffset: expanded.pageBatch.nextCharacterOffset,
                isComplete: expanded.pageBatch.isComplete
            )
        }

        previousPageTask = Task { [weak self] in
            let batch: TextPaginator.PageBatch
            do {
                batch = try await withTaskCancellationHandler(operation: {
                    try await worker.value
                }, onCancel: {
                    worker.cancel()
                })
            } catch {
                worker.cancel()
                if self?.layoutRequestID == requestID {
                    self?.previousPageTask = nil
                }
                return
            }

            guard !Task.isCancelled,
                  let self,
                  self.layoutRequestID == requestID else {
                if self?.layoutRequestID == requestID {
                    self?.previousPageTask = nil
                }
                return
            }
            self.prepend(previousPageBatch: batch)
            self.previousPageTask = nil
        }
    }

    private func makePageLayoutSnapshot(
        range: NSRange,
        maximumPages: Int
    ) -> TXTLayoutSnapshot {
        TXTLayoutSnapshot(
            text: currentContent,
            existingAttributedText: nil,
            pageSize: pageSize,
            insets: readerInsets,
            pageRange: range,
            maximumPages: maximumPages,
            shouldPaginate: true,
            fontScale: fontScale,
            fontFamily: fontFamily,
            boldText: boldText,
            lineHeight: lineHeight,
            paragraphIndent: paragraphIndent,
            foregroundColor: theme.foregroundUIColor
        )
    }

    private func append(nextPageBatch batch: TextPaginator.PageBatch) {
        guard !batch.pages.isEmpty else {
            nextPageOffset = nil
            return
        }
        pages.append(contentsOf: batch.pages.map(\.attributedText))
        pageRanges.append(contentsOf: batch.pages.map(\.characterRange))
        nextPageOffset = batch.isComplete
            ? nil
            : max(
                batch.nextCharacterOffset,
                pageRanges.last.map { NSMaxRange($0) } ?? currentContent.utf16.count
            )
    }

    private func prepend(previousPageBatch batch: TextPaginator.PageBatch) {
        guard !batch.pages.isEmpty else {
            hasMorePreviousPages = false
            return
        }

        let oldPageIndex = currentPageIndex
        let newPages = batch.pages.map(\.attributedText)
        let newRanges = batch.pages.map(\.characterRange)
        pages.insert(contentsOf: newPages, at: 0)
        pageRanges.insert(contentsOf: newRanges, at: 0)
        suppressPageProgress = true
        currentPageIndex = oldPageIndex + newPages.count
        suppressPageProgress = false
        hasMorePreviousPages = pageRanges.first?.location ?? 0 > 0
    }

    func updateScrollCharacterOffset(_ characterOffset: Int) {
        let offset = clampCharacterOffset(characterOffset)
        currentCharacterOffset = offset
        currentChapterIndex = chapterIndex(forGlobalOffset: offset)
        // The UIKit bridge calls this after applying a requested anchor.  Do
        // not keep replaying that same anchor on later SwiftUI updates.
        pendingCharacterOffset = nil
    }

    func updateScrollProgress(_ globalProgress: Double) {
        let fraction = min(max(globalProgress, 0), 1)
        pendingScrollProgress = fraction
        scheduleProgressPersistence()
    }

    /// Stop detached parsing/layout work when the reader leaves the screen.
    /// Without this explicit cancellation a large TXT could continue laying
    /// out in the background after dismissal and keep the device busy.
    func cancelPendingLayout() {
        layoutTask?.cancel()
        nextPageTask?.cancel()
        previousPageTask?.cancel()
        layoutTask = nil
        nextPageTask = nil
        previousPageTask = nil
        layoutRequestID &+= 1
    }

    func retry() async {
        guard !isLoading else { return }
        cancelPendingLayout()
        fullText = NSAttributedString(string: "")
        pages = []
        pageRanges = []
        nextPageOffset = nil
        hasMorePreviousPages = false
        chapterLengths = []
        chapterStartOffsets = []
        currentContent = ""
        chapters = []
        hasLoaded = false
        await load()
    }

    func flushReadingProgress() {
        persistenceTask?.cancel()
        persistenceTask = nil
        if flowMode == .scroll {
            persistReadingLocation(progressHint: pendingScrollProgress)
        } else if !pages.isEmpty {
            updateReadingProgress()
        }
    }

    // MARK: - 偏好

    func resetTypography() {
        fontScale = 1.0
        fontFamily = .systemSerif
        boldText = false
        lineHeight = 1.5
        paragraphIndent = 2.0
        pageMargins = 1.0
        contentTopInset = 56
        contentBottomInset = 32
        theme = .light
    }

    private func styleDidChange() {
        persistPreferences()
        requestRepagination(rebuildAttributedText: true)
    }

    private func flowModeDidChange() {
        persistPreferences()
        guard hasLoaded else { return }
        requestRepagination()
    }

    private func persistPreferences() {
        let defaults = UserDefaults.standard
        defaults.set(fontScale, forKey: PreferenceKey.fontScale)
        defaults.set(fontFamily.rawValue, forKey: PreferenceKey.fontFamily)
        defaults.set(boldText, forKey: PreferenceKey.boldText)
        defaults.set(lineHeight, forKey: PreferenceKey.lineHeight)
        defaults.set(paragraphIndent, forKey: PreferenceKey.paragraphIndent)
        defaults.set(pageMargins, forKey: PreferenceKey.pageMargins)
        defaults.set(contentTopInset, forKey: PreferenceKey.contentTopInset)
        defaults.set(contentBottomInset, forKey: PreferenceKey.contentBottomInset)
        defaults.set(theme.rawValue, forKey: PreferenceKey.theme)
        defaults.set(flowMode.rawValue, forKey: PreferenceKey.flowMode)
        defaults.set(pageTransition.rawValue, forKey: PreferenceKey.pageTransition)
        defaults.set(showBookTitleInPageHeader, forKey: PreferenceKey.showBookTitleInPageHeader)
    }

    private func updateReadingProgress() {
        guard flowMode == .paged, !chapters.isEmpty, !pages.isEmpty else { return }
        if pageRanges.indices.contains(currentPageIndex) {
            currentCharacterOffset = pageRanges[currentPageIndex].location
        }
        currentChapterIndex = chapterIndex(forGlobalOffset: currentCharacterOffset)
        persistReadingLocation()
    }

    private func scheduleProgressPersistence() {
        guard persistenceTask == nil else { return }
        persistenceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.persistenceTask = nil
            self?.persistPendingScrollProgress()
        }
    }

    private func persistPendingScrollProgress() {
        guard let pendingScrollProgress else { return }
        persistReadingLocation(progressHint: pendingScrollProgress)
    }

    private func persistReadingLocation(progressHint: Double? = nil) {
        guard !chapters.isEmpty else { return }
        let offset: Int
        if currentContent.isEmpty {
            offset = 0
        } else if currentCharacterOffset > 0 || progressHint == nil {
            offset = clampCharacterOffset(currentCharacterOffset)
        } else {
            // The progress callback is a safe fallback if UIKit has not yet
            // produced a character anchor (for example during first layout).
            offset = globalOffset(forBookProgress: progressHint ?? 0)
        }

        currentCharacterOffset = offset
        currentChapterIndex = chapterIndex(forGlobalOffset: offset)
        let chapterOffset = localOffset(
            forGlobalOffset: offset,
            chapterIndex: currentChapterIndex
        )
        let chapterLength = chapterLengths.indices.contains(currentChapterIndex)
            ? chapterLengths[currentChapterIndex]
            : 0
        let chapterFraction = chapterLength > 0
            ? min(max(Double(chapterOffset) / Double(chapterLength), 0), 1)
            : 0
        let bookProgress = globalProgress(forGlobalOffset: offset)

        book.currentChapterIndex = currentChapterIndex
        book.progressPercent = bookProgress
        book.lastReadAt = .now

        let location = TXTReadingLocation(
            version: 1,
            format: "txt",
            chapterIndex: currentChapterIndex,
            // The persisted offset is local to the chapter for compatibility
            // with locations written by the previous chapter-at-a-time reader.
            characterOffset: chapterOffset,
            chapterFraction: chapterFraction
        )
        if let data = try? JSONEncoder().encode(location),
           let json = String(data: data, encoding: .utf8) {
            book.readerLocatorJSON = json
        }
        pendingScrollProgress = nil
    }

    // MARK: - Continuous TXT coordinate space

    /// Build the UTF-16 coordinate of each chapter after joining the parsed
    /// chapters with one blank line.  TextKit and the scroll view both use
    /// this same coordinate space, so page turns and vertical scrolling never
    /// lose the chapter boundary.
    private func makeChapterStartOffsets(for contents: [String]) -> [Int] {
        var offsets: [Int] = []
        offsets.reserveCapacity(contents.count)

        var offset = 0
        for (index, content) in contents.enumerated() {
            if index > 0 {
                offset += 2 // "\n\n".utf16.count
            }
            offsets.append(offset)
            offset += content.utf16.count
        }
        return offsets
    }

    private func chapterStartOffset(for index: Int) -> Int {
        guard chapterStartOffsets.indices.contains(index) else { return 0 }
        return chapterStartOffsets[index]
    }

    private func chapterEndOffset(for index: Int) -> Int {
        guard chapterLengths.indices.contains(index) else { return chapterStartOffset(for: index) }
        return chapterStartOffset(for: index) + chapterLengths[index]
    }

    private func clampCharacterOffset(_ offset: Int) -> Int {
        min(max(offset, 0), currentContent.utf16.count)
    }

    /// Convert a persisted (chapter-local) TXT location to the continuous
    /// offset used by TextKit.  Invalid or legacy locations fall back to the
    /// book-level progress value instead of opening at an arbitrary chapter.
    private func globalOffset(for location: TXTReadingLocation) -> Int {
        guard chapterLengths.indices.contains(location.chapterIndex) else {
            return globalOffset(forBookProgress: book.progressPercent)
        }

        let length = chapterLengths[location.chapterIndex]
        // Early builds persisted only the chapter/page fraction for paged TXT
        // books.  Honour it when no usable character anchor was written.
        let localOffset: Int
        if location.characterOffset > 0 || location.chapterFraction <= 0 {
            localOffset = min(max(location.characterOffset, 0), length)
        } else {
            localOffset = Int(
                (min(max(location.chapterFraction, 0), 1) * Double(length)).rounded()
            )
        }
        return clampCharacterOffset(chapterStartOffset(for: location.chapterIndex) + localOffset)
    }

    /// Before TXT locations were stored as character anchors, `Book` used a
    /// chapter-weighted progress value.  Keep that value readable for books
    /// that have no locator yet, while all new writes use the continuous
    /// character coordinate below.
    private func globalOffsetForLegacyBookPosition() -> Int {
        guard !chapterLengths.isEmpty else { return 0 }
        let chapterIndex = min(
            max(book.currentChapterIndex, 0),
            chapterLengths.count - 1
        )
        let chapterCount = Double(max(chapterLengths.count, 1))
        let chapterPosition = min(max(book.progressPercent, 0), 1) * chapterCount
        let fraction = min(
            max(chapterPosition - Double(chapterIndex), 0),
            1
        )
        let length = chapterLengths[chapterIndex]
        return clampCharacterOffset(
            chapterStartOffset(for: chapterIndex)
                + Int((fraction * Double(length)).rounded())
        )
    }

    private func globalOffset(forBookProgress progress: Double) -> Int {
        let length = currentContent.utf16.count
        guard length > 0 else { return 0 }
        let fraction = min(max(progress, 0), 1)
        return min(max(Int((fraction * Double(length)).rounded()), 0), length)
    }

    private func chapterIndex(forGlobalOffset offset: Int) -> Int {
        guard !chapterStartOffsets.isEmpty else { return 0 }
        let clamped = clampCharacterOffset(offset)

        for index in chapterStartOffsets.indices {
            let nextStart = index + 1 < chapterStartOffsets.count
                ? chapterStartOffsets[index + 1]
                : currentContent.utf16.count
            if clamped < nextStart {
                return index
            }
        }
        return chapterStartOffsets.count - 1
    }

    private func localOffset(forGlobalOffset offset: Int, chapterIndex: Int) -> Int {
        guard chapterLengths.indices.contains(chapterIndex) else { return 0 }
        let local = clampCharacterOffset(offset) - chapterStartOffset(for: chapterIndex)
        return min(max(local, 0), chapterLengths[chapterIndex])
    }

    private func globalProgress(forGlobalOffset offset: Int) -> Double {
        let length = currentContent.utf16.count
        guard length > 0 else { return 0 }
        return Double(clampCharacterOffset(offset)) / Double(length)
    }

    private func decodedReadingLocation() -> TXTReadingLocation? {
        guard let json = book.readerLocatorJSON,
              let data = json.data(using: .utf8),
              let location = try? JSONDecoder().decode(TXTReadingLocation.self, from: data),
              location.format == "txt",
              location.version == 1 else {
            return nil
        }
        return location
    }
}
