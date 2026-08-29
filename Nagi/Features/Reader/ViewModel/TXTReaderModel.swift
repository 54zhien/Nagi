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
    let pageSize: CGSize
    let insets: UIEdgeInsets
    let fontScale: Double
    let fontFamily: ReaderFontFamily
    let boldText: Bool
    let lineHeight: Double
    let paragraphIndent: Double
    let foregroundColor: UIColor
}

private struct TXTLayoutResult: @unchecked Sendable {
    let attributedText: NSAttributedString
    let pages: [TextPaginator.Page]
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
            guard currentPageIndex != oldValue else { return }
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

    private var chapterContents: [String] = []
    private var currentContent = ""
    private var hasLoaded = false
    private var pendingPageFraction: Double?
    private var pendingShowLastPage = false
    private var pendingCharacterOffset: Int?
    private var currentCharacterOffset = 0
    private var pendingScrollProgress: Double?
    private var layoutTask: Task<Void, Never>?
    private var layoutRequestID = 0
    private var persistenceTask: Task<Void, Never>?

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
                parsedChapters = await Task.detached(priority: .userInitiated) {
                    TXTParser.splitIntoChapters(content, fallbackTitle: fallbackTitle)
                }.value
            }
            guard !parsedChapters.isEmpty else { throw ParseError.emptyContent }

            chapterContents = parsedChapters.map { $0.content }
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
        try await Task.detached(priority: .userInitiated) {
            try TXTParser().parse(url: url)
        }.value
    }

    func loadCurrentChapter(showLastPage: Bool = false, restorePosition: Bool = false) {
        guard chapters.indices.contains(currentChapterIndex),
              chapterContents.indices.contains(currentChapterIndex) else { return }

        currentContent = chapterContents[currentChapterIndex]
        let savedLocation = restorePosition ? decodedReadingLocation() : nil
        let locationMatchesChapter = savedLocation?.chapterIndex == currentChapterIndex
        pendingCharacterOffset = locationMatchesChapter ? savedLocation?.characterOffset : nil
        pendingPageFraction = locationMatchesChapter
            ? savedLocation?.chapterFraction
            : (restorePosition ? chapterProgressFromBook : nil)
        pendingShowLastPage = showLastPage
        currentCharacterOffset = pendingCharacterOffset ?? 0
        fullText = NSAttributedString(string: "")
        pages = []
        pageRanges = []
        currentPageIndex = 0
        requestRepagination()
    }

    // MARK: - 分页与排版

    func updateViewport(size: CGSize, safeAreaInsets: UIEdgeInsets) {
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

    private func requestRepagination() {
        guard !currentContent.isEmpty else { return }

        layoutRequestID &+= 1
        let requestID = layoutRequestID
        let snapshot = TXTLayoutSnapshot(
            text: currentContent,
            pageSize: pageSize,
            insets: readerInsets,
            fontScale: fontScale,
            fontFamily: fontFamily,
            boldText: boldText,
            lineHeight: lineHeight,
            paragraphIndent: paragraphIndent,
            foregroundColor: theme.foregroundUIColor
        )
        let restoreCharacterOffset = pendingCharacterOffset
        let restorePageFraction = pendingPageFraction
        let restoreLastPage = pendingShowLastPage

        layoutTask?.cancel()
        layoutTask = Task { [weak self] in
            do {
                // Coalesce a slider's rapid updates into one layout request.
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return
            }

            let result = await Task.detached(priority: .userInitiated) {
                let attributed = Self.attributedText(from: snapshot.text, snapshot: snapshot)
                let pages: [TextPaginator.Page]
                if snapshot.pageSize.width > 0, snapshot.pageSize.height > 0 {
                    pages = TextPaginator.paginate(
                        attributed,
                        pageSize: snapshot.pageSize,
                        insets: snapshot.insets
                    )
                } else {
                    pages = []
                }
                return TXTLayoutResult(attributedText: attributed, pages: pages)
            }.value

            guard !Task.isCancelled,
                  let self,
                  self.layoutRequestID == requestID else { return }
            self.applyLayout(
                result,
                restoreCharacterOffset: restoreCharacterOffset,
                restorePageFraction: restorePageFraction,
                restoreLastPage: restoreLastPage
            )
        }
    }

    private func applyLayout(
        _ result: TXTLayoutResult,
        restoreCharacterOffset: Int?,
        restorePageFraction: Double?,
        restoreLastPage: Bool
    ) {
        fullText = result.attributedText
        pages = result.pages.map(\.attributedText)
        pageRanges = result.pages.map(\.characterRange)
        layoutGeneration &+= 1

        guard !pages.isEmpty else {
            pendingCharacterOffset = restoreCharacterOffset
            pendingPageFraction = restorePageFraction
            pendingShowLastPage = restoreLastPage
            return
        }

        if restoreLastPage {
            currentPageIndex = max(0, pages.count - 1)
        } else if let restoreCharacterOffset {
            currentPageIndex = pageIndex(containing: restoreCharacterOffset, in: pageRanges)
        } else if let restorePageFraction {
            currentPageIndex = Int(
                (min(max(restorePageFraction, 0), 1) * Double(max(pages.count - 1, 0))).rounded()
            )
        } else {
            currentPageIndex = pageIndex(containing: currentCharacterOffset, in: pageRanges)
        }

        currentPageIndex = min(max(currentPageIndex, 0), pages.count - 1)
        currentCharacterOffset = flowMode == .scroll
            ? min(max(restoreCharacterOffset ?? currentCharacterOffset, 0), currentContent.utf16.count)
            : pageRanges[currentPageIndex].location
        pendingCharacterOffset = nil
        pendingPageFraction = nil
        pendingShowLastPage = false
        updateReadingProgress()
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

    private nonisolated static func attributedText(
        from text: String,
        snapshot: TXTLayoutSnapshot
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
        paragraphStyle.firstLineHeadIndent = fontSize * CGFloat(snapshot.paragraphIndent)
        paragraphStyle.lineBreakMode = .byWordWrapping

        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .paragraphStyle: paragraphStyle,
            .foregroundColor: snapshot.foregroundColor,
        ])
        let string = text as NSString
        var location = 0
        while location < string.length {
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

    static func attributedText(from text: String, settings: TXTReaderModel) -> NSAttributedString {
        let snapshot = TXTLayoutSnapshot(
            text: text,
            pageSize: settings.pageSize,
            insets: settings.readerInsets,
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

    /// Initial position supplied to the UIKit scroll view.  A character
    /// anchor wins when one was persisted; otherwise the saved chapter
    /// fraction provides a backwards-compatible fallback.
    var initialScrollCharacterOffset: Int? {
        if let pendingCharacterOffset {
            return pendingCharacterOffset
        }
        return currentCharacterOffset > 0 ? currentCharacterOffset : nil
    }

    var initialScrollProgress: Double {
        pendingPageFraction ?? pendingScrollProgress ?? chapterProgressFromBook
    }

    func selectChapter(_ chapter: BookChapter) {
        guard chapters.indices.contains(chapter.index), chapter.index != currentChapterIndex else { return }
        currentChapterIndex = chapter.index
        loadCurrentChapter()
    }

    func updateScrollCharacterOffset(_ characterOffset: Int) {
        currentCharacterOffset = min(max(characterOffset, 0), currentContent.utf16.count)
    }

    func updateScrollProgress(_ chapterProgress: Double) {
        let fraction = min(max(chapterProgress, 0), 1)
        pendingScrollProgress = fraction
        scheduleProgressPersistence()
    }

    func retry() async {
        guard !isLoading else { return }
        hasLoaded = false
        await load()
    }

    func flushReadingProgress() {
        persistenceTask?.cancel()
        persistenceTask = nil
        if let pendingScrollProgress {
            persistReadingLocation(chapterProgress: pendingScrollProgress)
        } else if flowMode == .paged, !pages.isEmpty {
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
        requestRepagination()
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

    private var chapterProgressFromBook: Double {
        guard chapters.indices.contains(currentChapterIndex) else { return 0 }
        let lengths = chapterContents.map { max($0.utf16.count, 1) }
        let totalLength = lengths.reduce(0, +)
        guard totalLength > 0 else { return 0 }
        let chapterStart = lengths.prefix(currentChapterIndex).reduce(0, +)
        let target = min(max(book.progressPercent, 0), 1) * Double(totalLength)
        let chapterLength = Double(lengths[currentChapterIndex])
        return min(max((target - Double(chapterStart)) / chapterLength, 0), 1)
    }

    private func updateReadingProgress() {
        guard flowMode == .paged, !chapters.isEmpty, !pages.isEmpty else { return }
        let fraction = pages.count > 1
            ? Double(currentPageIndex) / Double(pages.count - 1)
            : 0
        if pageRanges.indices.contains(currentPageIndex) {
            currentCharacterOffset = pageRanges[currentPageIndex].location
        }
        persistReadingLocation(chapterProgress: fraction)
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
        persistReadingLocation(chapterProgress: pendingScrollProgress)
    }

    private func persistReadingLocation(chapterProgress: Double) {
        guard !chapters.isEmpty else { return }
        let fraction = min(max(chapterProgress, 0), 1)
        let globalProgress = globalProgress(for: fraction)
        book.currentChapterIndex = currentChapterIndex
        book.progressPercent = globalProgress
        book.lastReadAt = .now

        let location = TXTReadingLocation(
            version: 1,
            format: "txt",
            chapterIndex: currentChapterIndex,
            characterOffset: min(max(currentCharacterOffset, 0), currentContent.utf16.count),
            chapterFraction: fraction
        )
        if let data = try? JSONEncoder().encode(location),
           let json = String(data: data, encoding: .utf8) {
            book.readerLocatorJSON = json
        }
        pendingScrollProgress = nil
    }

    private func globalProgress(for chapterFraction: Double) -> Double {
        let lengths = chapterContents.map { max($0.utf16.count, 1) }
        let totalLength = lengths.reduce(0, +)
        guard totalLength > 0, lengths.indices.contains(currentChapterIndex) else {
            let total = Double(max(chapters.count, 1))
            return min(max((Double(currentChapterIndex) + chapterFraction) / total, 0), 1)
        }

        let chapterStart = lengths.prefix(currentChapterIndex).reduce(0, +)
        let currentLength = Double(lengths[currentChapterIndex])
        let absoluteOffset = Double(chapterStart) + min(max(chapterFraction, 0), 1) * currentLength
        return min(max(absoluteOffset / Double(totalLength), 0), 1)
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
