
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
    let characterSpacing: Double
    let wordSpacing: Double
    let foregroundColor: UIColor
}

private struct TXTLayoutResult: @unchecked Sendable {
    let attributedText: NSAttributedString
    let pageBatch: TextPaginator.PageBatch?
}

enum TXTLayoutPhase: Equatable {
    case idle
    case loading
    case waitingForViewport
    case layingOut
    case ready
    case failed(String)

    var progressTitle: String {
        switch self {
        case .idle: return "准备阅读…"
        case .loading: return "正在打开 TXT…"
        case .waitingForViewport: return "准备阅读区域…"
        case .layingOut: return "正在排版…"
        case .ready: return ""
        case .failed: return "排版失败"
        }
    }
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

    var fontScale: Double { didSet { styleDidChange() } }
    var fontFamily: ReaderFontFamily { didSet { styleDidChange() } }
    var boldText: Bool { didSet { styleDidChange() } }
    var lineHeight: Double { didSet { styleDidChange() } }
    var paragraphIndent: Double { didSet { styleDidChange() } }
    var pageMargins: Double { didSet { styleDidChange() } }
    var characterSpacing: Double { didSet { styleDidChange() } }
    var wordSpacing: Double { didSet { styleDidChange() } }
    var theme: ReaderTheme { didSet { styleDidChange() } }
    var appearanceMode: ReaderAppearanceMode { didSet { styleDidChange() } }
    var brightness: Double
    var flowMode: ReaderFlowMode { didSet { flowModeDidChange() } }
    var pageTransition: ReaderPageTransitionMode { didSet { persistPreferences() } }
    var showBookTitleInPageHeader: Bool { didSet { persistPreferences() } }

    var pageSize = CGSize.zero
    var safeAreaInsets = UIEdgeInsets.zero

    var isLoading = false
    var errorMessage: String?
    var onStateChange: (() -> Void)?
    private(set) var layoutPhase: TXTLayoutPhase = .idle
    private(set) var layoutGeneration = 0

    private var chapterLengths: [Int] = []
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
    private var systemIsDark = false

    private nonisolated static let pageBatchSize = 8
    private nonisolated static let pageBatchCharacterLimit = 128_000

    private enum PreferenceKey {
        static let fontScale = "reader.txt.fontScale"
        static let fontFamily = "reader.txt.fontFamily"
        static let boldText = "reader.txt.boldText"
        static let lineHeight = "reader.txt.lineHeight"
        static let paragraphIndent = "reader.txt.paragraphIndent"
        static let pageMargins = "reader.txt.pageMargins"
        static let pageMarginAdjustment = "reader.txt.pageMarginAdjustment"
        static let pageMarginPoints = "reader.txt.pageMarginPoints"
        static let characterSpacing = "reader.txt.characterSpacing"
        static let wordSpacing = "reader.txt.wordSpacing"
        static let theme = "reader.txt.theme"
        static let appearanceMode = "reader.txt.appearanceMode"
        static let brightness = "reader.txt.brightness"
        static let flowMode = "reader.txt.flowMode"
        static let pageTransition = "reader.txt.pageTransition"
        static let showBookTitleInPageHeader = "reader.txt.showBookTitleInPageHeader"
    }

    init(book: Book) {
        self.book = book
        title = book.title
        currentChapterIndex = max(book.currentChapterIndex, 0)

        let defaults = UserDefaults.standard
        let savedFontScale = defaults.object(forKey: PreferenceKey.fontScale) as? Double ?? 1.0
        fontScale = min(
            max(savedFontScale, ReaderFontSize.minimumScale),
            ReaderFontSize.maximumScale
        )
        fontFamily = defaults.string(forKey: PreferenceKey.fontFamily)
            .flatMap(ReaderFontFamily.init) ?? .original
        boldText = defaults.object(forKey: PreferenceKey.boldText) as? Bool ?? false
        lineHeight = ReaderLayoutMetrics.clampLineHeight(
            defaults.object(forKey: PreferenceKey.lineHeight) as? Double
                ?? ReaderLayoutMetrics.defaultLineHeight
        )
        paragraphIndent = ReaderLayoutMetrics.fixedParagraphIndent
        if let pageMargin = defaults.object(forKey: PreferenceKey.pageMarginPoints) as? Double {
            pageMargins = ReaderLayoutMetrics.clampPageMargins(pageMargin)
        } else if let adjustment = defaults.object(forKey: PreferenceKey.pageMarginAdjustment) as? Double {
            pageMargins = ReaderLayoutMetrics.migrateLegacyPageMarginAdjustment(adjustment)
        } else {
            pageMargins = ReaderLayoutMetrics.migrateLegacyPageMargins(
                defaults.object(forKey: PreferenceKey.pageMargins) as? Double
            )
        }
        characterSpacing = ReaderLayoutMetrics.clampCharacterSpacing(
            defaults.object(forKey: PreferenceKey.characterSpacing) as? Double
                ?? ReaderLayoutMetrics.defaultCharacterSpacing
        )
        wordSpacing = ReaderLayoutMetrics.clampWordSpacing(
            defaults.object(forKey: PreferenceKey.wordSpacing) as? Double
                ?? ReaderLayoutMetrics.defaultWordSpacing
        )
        theme = defaults.string(forKey: PreferenceKey.theme).flatMap(ReaderTheme.init) ?? .light
        appearanceMode = defaults.string(forKey: PreferenceKey.appearanceMode)
            .flatMap(ReaderAppearanceMode.init) ?? .system
        brightness = 1
        flowMode = defaults.string(forKey: PreferenceKey.flowMode).flatMap(ReaderFlowMode.init) ?? .paged
        pageTransition = defaults.string(forKey: PreferenceKey.pageTransition)
            .flatMap(ReaderPageTransitionMode.init) ?? .pageCurl
        showBookTitleInPageHeader = defaults.object(forKey: PreferenceKey.showBookTitleInPageHeader)
            as? Bool ?? false
    }


    func load() async {
        guard !hasLoaded, !isLoading else { return }

        isLoading = true
        errorMessage = nil
        layoutPhase = .loading
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
            layoutPhase = .waitingForViewport
            loadCurrentChapter(restorePosition: true)
            if layoutPhase == .waitingForViewport {
                tryStartLayoutIfReady()
            }
            onStateChange?()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            layoutPhase = .failed(error.localizedDescription)
        }
    }

    private nonisolated static func parseInBackground(url: URL) async throws -> ParsedBook {
        try await Task.detached(priority: .utility) {
            try TXTParser().parse(url: url)
        }.value
    }

    func loadCurrentChapter(showLastPage: Bool = false, restorePosition: Bool = false) {
        guard chapters.indices.contains(currentChapterIndex),
              chapterLengths.indices.contains(currentChapterIndex) else {
            markLayoutFailure("排版失败：章节索引无效")
            return
        }

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

        if flowMode == .scroll,
           fullText.length > 0,
           fullText.length == currentContent.utf16.count {
            currentChapterIndex = chapterIndex(forGlobalOffset: targetOffset)
            layoutPhase = .ready
            persistReadingLocation()
            onStateChange?()
            return
        }

        if flowMode == .paged,
           fullText.length > 0,
           let targetPage = pageIndexIfContaining(targetOffset, in: pageRanges) {
            suppressPageProgress = true
            currentPageIndex = targetPage
            suppressPageProgress = false
            currentCharacterOffset = targetOffset
            currentChapterIndex = chapterIndex(forGlobalOffset: targetOffset)
            pendingCharacterOffset = nil
            layoutPhase = .ready
            persistReadingLocation()
            onStateChange?()
            return
        }

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
        tryStartLayoutIfReady(startOffset: startOffset)
    }


    @discardableResult
    func updateViewport(size: CGSize, safeAreaInsets: UIEdgeInsets) -> Bool {
        guard size.width > 1, size.height > 1 else {
            if hasLoaded, !currentContent.isEmpty, flowMode == .paged {
                cancelLayoutTasks()
                layoutRequestID &+= 1
                layoutPhase = .waitingForViewport
                return true
            }
            return false
        }
        let sizeChanged = pageSize != size
        let insetsChanged = self.safeAreaInsets != safeAreaInsets
        guard sizeChanged || insetsChanged else {
            if layoutPhase == .waitingForViewport {
                tryStartLayoutIfReady()
                return true
            }
            return false
        }
        pageSize = size
        self.safeAreaInsets = safeAreaInsets
        tryStartLayoutIfReady()
        return true
    }

    var readerInsets: UIEdgeInsets {
        ReaderContentInsetResolver.resolve(
            safeAreaInsets: safeAreaInsets,
            top: 0,
            bottom: 0,
            horizontal: ReaderLayoutMetrics.pageBlankInset(for: pageMargins)
        )
    }

    var readerBackgroundUIColor: UIColor {
        resolvedTheme.readerBackgroundUIColor(isDarkAppearance: isDarkAppearance)
    }

    var readerContentUIColor: UIColor {
        resolvedTheme.readerContentUIColor(isDarkAppearance: isDarkAppearance)
    }

    var resolvedTheme: ReaderTheme {
        switch appearanceMode {
        case .light:
            return theme == .dark ? .light : theme
        case .dark:
            return theme == .light ? .dark : theme
        case .system:
            return systemIsDark
                ? (theme == .light ? .dark : theme)
                : (theme == .dark ? .light : theme)
        }
    }

    private var isDarkAppearance: Bool {
        switch appearanceMode {
        case .light:
            return false
        case .dark:
            return true
        case .system:
            return systemIsDark
        }
    }

    var progress: Double {
        guard !currentContent.isEmpty else { return min(max(book.progressPercent, 0), 1) }
        return globalProgress(forGlobalOffset: currentCharacterOffset)
    }

    var canGoNext: Bool {
        guard flowMode == .paged else { return false }
        return currentPageIndex < pages.count - 1
            || nextPageOffset != nil
            || currentChapterIndex < chapters.count - 1
    }

    var canGoPrevious: Bool {
        guard flowMode == .paged else { return false }
        return currentPageIndex > 0
            || hasMorePreviousPages
            || currentChapterIndex > 0
    }

    private func cancelLayoutTasks() {
        layoutTask?.cancel()
        nextPageTask?.cancel()
        previousPageTask?.cancel()
        layoutTask = nil
        nextPageTask = nil
        previousPageTask = nil
    }

    private func tryStartLayoutIfReady(
        startOffset requestedStartOffset: Int? = nil,
        rebuildAttributedText: Bool = false
    ) {
        guard !currentContent.isEmpty else { return }

        let shouldPaginate = flowMode == .paged
        guard !shouldPaginate || (pageSize.width > 1 && pageSize.height > 1) else {
            cancelLayoutTasks()
            layoutRequestID &+= 1
            layoutPhase = .waitingForViewport
            return
        }

        layoutRequestID &+= 1
        let requestID = layoutRequestID
        layoutPhase = .layingOut
        errorMessage = nil
        let requestedAnchor = clampCharacterOffset(
            requestedStartOffset
                ?? pendingCharacterOffset
                ?? currentCharacterOffset
        )
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
            characterSpacing: characterSpacing,
            wordSpacing: wordSpacing,
            foregroundColor: readerContentUIColor
        )
        let restoreCharacterOffset = pendingCharacterOffset

        cancelLayoutTasks()
        layoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch is CancellationError {
                guard let self, self.layoutRequestID == requestID else { return }
                self.layoutTask = nil
                self.layoutPhase = .waitingForViewport
                return
            } catch {
                guard let self, self.layoutRequestID == requestID else { return }
                self.layoutTask = nil
                let message = "排版任务启动失败：\(error.localizedDescription)"
                self.errorMessage = message
                self.layoutPhase = .failed(message)
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
            } catch is CancellationError {
                worker.cancel()
                guard let self, self.layoutRequestID == requestID else { return }
                self.layoutTask = nil
                self.layoutPhase = .waitingForViewport
                return
            } catch {
                worker.cancel()
                guard let self, self.layoutRequestID == requestID else { return }
                self.layoutTask = nil
                let message = "排版失败：\(error.localizedDescription)"
                self.errorMessage = message
                self.layoutPhase = .failed(message)
                return
            }

            guard !Task.isCancelled,
                  let self,
                  self.layoutRequestID == requestID else { return }
            self.layoutTask = nil
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
            guard fullText.length > 0 else {
                markLayoutFailure("排版失败：没有生成可显示的文本")
                return
            }
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
            layoutPhase = .ready
            onStateChange?()
            return
        }

        guard let pageBatch = result.pageBatch else {
            pendingCharacterOffset = restoreCharacterOffset
            markLayoutFailure("排版失败：没有生成分页结果")
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
            markLayoutFailure("排版失败：没有生成可显示的页面")
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
        layoutPhase = .ready
        onStateChange?()

        if hasMorePreviousPages {
            requestPreviousPageBatch()
        }
        if pages.count < 2, nextPageOffset != nil {
            requestNextPageBatch()
        }
    }

    private func markLayoutFailure(_ message: String) {
        errorMessage = message
        layoutPhase = .failed(message)
        onStateChange?()
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
        let fontSize = CGFloat(
            max(
                ReaderFontSize.minimum,
                min(72, ReaderFontSize.defaultValue * snapshot.fontScale)
            )
        )
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
        paragraphStyle.lineHeightMultiple = CGFloat(
            ReaderLayoutMetrics.clampLineHeight(snapshot.lineHeight)
        )
        paragraphStyle.lineSpacing = 0
        paragraphStyle.paragraphSpacing = font.lineHeight * 0.65
        paragraphStyle.firstLineHeadIndent = font.pointSize * CGFloat(snapshot.paragraphIndent)
        paragraphStyle.lineBreakMode = .byWordWrapping

        let characterSpacing = ReaderLayoutMetrics.spacingPoints(
            for: snapshot.characterSpacing
        )
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .paragraphStyle: paragraphStyle,
            .foregroundColor: snapshot.foregroundColor,
            .kern: characterSpacing,
        ])

        let wordSpacing = ReaderLayoutMetrics.spacingPoints(for: snapshot.wordSpacing)
        if wordSpacing != 0 {
            var index = text.startIndex
            while index < text.endIndex {
                let nextIndex = text.index(after: index)
                let character = text[index]
                let isWordSeparator = character.unicodeScalars.contains {
                    CharacterSet.whitespaces.contains($0) || $0.value == 0x3000
                }
                if isWordSeparator {
                    let range = NSRange(index..<nextIndex, in: text)
                    attributed.addAttribute(
                        .kern,
                        value: characterSpacing + wordSpacing,
                        range: range
                    )
                }
                index = nextIndex
            }
        }
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

            let style = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
            let hasBlankLineBefore = paragraphStart == 0 || (
                paragraphStart >= 2
                    && string.substring(with: NSRange(location: paragraphStart - 2, length: 2)) == "\n\n"
            )
            if !hasBlankLineBefore {
                style.firstLineHeadIndent = 0
                style.paragraphSpacing = 0
            }

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
            characterSpacing: settings.characterSpacing,
            wordSpacing: settings.wordSpacing,
            foregroundColor: settings.readerContentUIColor
        )
        return attributedText(from: text, snapshot: snapshot)
    }


    var currentChapter: BookChapter? {
        guard chapters.indices.contains(currentChapterIndex) else { return nil }
        return chapters[currentChapterIndex]
    }

    var currentChapterID: String? {
        currentChapter?.id
    }

    var scrollPositionID: String {
        "txt-position-\(scrollPositionGeneration)"
    }

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

    func goForward() {
        guard flowMode == .paged else { return }

        if currentPageIndex < pages.count - 1 {
            currentPageIndex += 1
            return
        }

        if let nextPageOffset {
            pages = []
            pageRanges = []
            hasMorePreviousPages = true
            pendingCharacterOffset = nextPageOffset
            currentCharacterOffset = nextPageOffset
            tryStartLayoutIfReady(startOffset: nextPageOffset)
            return
        }

        guard chapters.indices.contains(currentChapterIndex + 1) else { return }
        selectChapter(chapters[currentChapterIndex + 1])
    }

    func goBackward() {
        guard flowMode == .paged else { return }

        if currentPageIndex > 0 {
            currentPageIndex -= 1
            return
        }

        if hasMorePreviousPages, let firstRange = pageRanges.first {
            let targetOffset = max(firstRange.location - Self.pageBatchCharacterLimit, 0)
            pages = []
            pageRanges = []
            nextPageOffset = nil
            pendingCharacterOffset = targetOffset
            currentCharacterOffset = targetOffset
            tryStartLayoutIfReady(startOffset: targetOffset)
            return
        }

        guard chapters.indices.contains(currentChapterIndex - 1) else { return }
        currentChapterIndex -= 1
        scrollPositionGeneration &+= 1
        loadCurrentChapter(showLastPage: true)
    }

    func updateSystemAppearance(isDark: Bool) {
        guard systemIsDark != isDark else { return }
        systemIsDark = isDark
        guard appearanceMode == .system else { return }
        styleDidChange()
    }

    func apply(preferences: ReaderPreferences) {
        fontScale = min(
            max(preferences.fontSize / ReaderFontSize.defaultValue, ReaderFontSize.minimumScale),
            ReaderFontSize.maximumScale
        )
        fontFamily = preferences.fontFamily
        boldText = preferences.boldText
        lineHeight = ReaderLayoutMetrics.clampLineHeight(preferences.lineHeight)
        paragraphIndent = ReaderLayoutMetrics.fixedParagraphIndent
        pageMargins = ReaderLayoutMetrics.clampPageMargins(preferences.pageMargins)
        characterSpacing = ReaderLayoutMetrics.clampCharacterSpacing(preferences.characterSpacing)
        wordSpacing = ReaderLayoutMetrics.clampWordSpacing(preferences.wordSpacing)
        appearanceMode = preferences.appearanceMode
        brightness = 1
        showBookTitleInPageHeader = preferences.showBookTitleInPageHeader
        theme = Self.theme(for: preferences.themePreset)

        switch preferences.pageTransition {
        case .scroll:
            flowMode = .scroll
        case .pageCurl:
            flowMode = .paged
            pageTransition = .pageCurl
        case .slide, .fade:
            flowMode = .paged
            pageTransition = .cover
        }
    }

    func apply(preset: ReaderThemePreset) {
        var preferences = readerPreferences
        preferences.themePreset = preset
        apply(preferences: preferences)
    }

    var readerPreferences: ReaderPreferences {
        ReaderPreferences(
            fontSize: ReaderFontSize.defaultValue * fontScale,
            fontFamily: fontFamily,
            boldText: boldText,
            lineHeight: lineHeight,
            paragraphSpacing: 10,
            pageMargins: pageMargins,
            paragraphIndent: ReaderLayoutMetrics.fixedParagraphIndent,
            characterSpacing: characterSpacing,
            wordSpacing: wordSpacing,
            publisherStyles: false,
            themePreset: Self.preset(for: theme),
            appearanceMode: appearanceMode,
            brightness: 1,
            pageTransition: Self.pageTransition(for: flowMode, mode: pageTransition),
            showBookTitleInPageHeader: showBookTitleInPageHeader
        )
    }

    private static func theme(for preset: ReaderThemePreset) -> ReaderTheme {
        switch preset {
        case .original: return .light
        case .quiet: return .quiet
        case .paper: return .sepia
        }
    }

    private static func preset(for theme: ReaderTheme) -> ReaderThemePreset {
        switch theme {
        case .quiet: return .quiet
        case .sepia: return .paper
        case .light, .dark: return .original
        }
    }

    private static func pageTransition(
        for flowMode: ReaderFlowMode,
        mode: ReaderPageTransitionMode
    ) -> ReaderPageTransition {
        guard flowMode == .scroll else {
            return mode == .pageCurl ? .pageCurl : .slide
        }
        return .scroll
    }

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
            characterSpacing: characterSpacing,
            wordSpacing: wordSpacing,
            foregroundColor: readerContentUIColor
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
        pendingCharacterOffset = nil
    }

    func updateScrollProgress(_ globalProgress: Double) {
        let fraction = min(max(globalProgress, 0), 1)
        pendingScrollProgress = fraction
        scheduleProgressPersistence()
    }

    func cancelPendingLayout() {
        cancelLayoutTasks()
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
        layoutPhase = .idle
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


    func resetTypography() {
        fontScale = 1.0
        fontFamily = .original
        boldText = false
        lineHeight = ReaderLayoutMetrics.defaultLineHeight
        paragraphIndent = ReaderLayoutMetrics.fixedParagraphIndent
        pageMargins = ReaderLayoutMetrics.defaultPageMargins
        characterSpacing = ReaderLayoutMetrics.defaultCharacterSpacing
        wordSpacing = ReaderLayoutMetrics.defaultWordSpacing
        theme = .light
    }

    private func styleDidChange() {
        persistPreferences()
        tryStartLayoutIfReady(rebuildAttributedText: true)
    }

    private func flowModeDidChange() {
        persistPreferences()
        guard hasLoaded else { return }
        tryStartLayoutIfReady()
    }

    private func persistPreferences() {
        let defaults = UserDefaults.standard
        defaults.set(fontScale, forKey: PreferenceKey.fontScale)
        defaults.set(fontFamily.rawValue, forKey: PreferenceKey.fontFamily)
        defaults.set(boldText, forKey: PreferenceKey.boldText)
        defaults.set(lineHeight, forKey: PreferenceKey.lineHeight)
        defaults.set(pageMargins, forKey: PreferenceKey.pageMarginPoints)
        defaults.set(ReaderLayoutMetrics.fixedParagraphIndent, forKey: PreferenceKey.paragraphIndent)
        defaults.set(characterSpacing, forKey: PreferenceKey.characterSpacing)
        defaults.set(wordSpacing, forKey: PreferenceKey.wordSpacing)
        defaults.set(theme.rawValue, forKey: PreferenceKey.theme)
        defaults.set(appearanceMode.rawValue, forKey: PreferenceKey.appearanceMode)
        defaults.set(1.0, forKey: PreferenceKey.brightness)
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
        book.currentChapterTitle = currentChapter?.title
        book.progressPercent = bookProgress
        book.lastReadAt = .now

        let location = TXTReadingLocation(
            version: 1,
            format: "txt",
            chapterIndex: currentChapterIndex,
            characterOffset: chapterOffset,
            chapterFraction: chapterFraction
        )
        if let data = try? JSONEncoder().encode(location),
           let json = String(data: data, encoding: .utf8) {
            book.txtReadingLocationJSON = json
            book.readerLocatorJSON = json
        }
        pendingScrollProgress = nil
    }


    private func makeChapterStartOffsets(for contents: [String]) -> [Int] {
        var offsets: [Int] = []
        offsets.reserveCapacity(contents.count)

        var offset = 0
        for (index, content) in contents.enumerated() {
            if index > 0 {
                offset += 2
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

    private func globalOffset(for location: TXTReadingLocation) -> Int {
        guard chapterLengths.indices.contains(location.chapterIndex) else {
            return globalOffset(forBookProgress: book.progressPercent)
        }

        let length = chapterLengths[location.chapterIndex]
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
        guard let json = book.txtReadingLocationJSON ?? book.readerLocatorJSON,
              let data = json.data(using: .utf8),
              let location = try? JSONDecoder().decode(TXTReadingLocation.self, from: data),
              location.format == "txt",
              location.version == 1 else {
            return nil
        }
        return location
    }
}
