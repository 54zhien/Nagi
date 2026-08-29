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

@MainActor
@Observable
final class TXTReaderModel {
    let book: Book

    // 章节与当前位置
    var title: String
    var chapters: [BookChapter] = []
    var currentChapterIndex: Int
    var pages: [NSAttributedString] = []
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
    var lineHeight: Double { didSet { styleDidChange() } }
    var paragraphIndent: Double { didSet { styleDidChange() } }
    var pageMargins: Double { didSet { styleDidChange() } }
    var contentTopInset: Double { didSet { styleDidChange() } }
    var contentBottomInset: Double { didSet { styleDidChange() } }
    var theme: ReaderTheme { didSet { styleDidChange() } }
    var flowMode: ReaderFlowMode { didSet { persistPreferences() } }
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

    private enum PreferenceKey {
        static let fontScale = "reader.txt.fontScale"
        static let fontFamily = "reader.txt.fontFamily"
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
            let parsedChapters = TXTParser.splitIntoChapters(parsed.content, fallbackTitle: title)
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
            currentChapterIndex = min(max(book.currentChapterIndex, 0), chapters.count - 1)
            hasLoaded = true
            loadCurrentChapter(restorePosition: true)
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
        pendingPageFraction = restorePosition ? chapterProgressFromBook : nil
        pendingShowLastPage = showLastPage
        repaginate()

        if restorePosition {
            if pages.isEmpty {
                currentPageIndex = 0
            }
        } else {
            currentPageIndex = showLastPage ? max(0, pages.count - 1) : 0
            pendingShowLastPage = false
        }
        if !pages.isEmpty {
            updateReadingProgress()
        }
    }

    // MARK: - 分页与排版

    func updateViewport(size: CGSize, safeAreaInsets: UIEdgeInsets) {
        let sizeChanged = pageSize != size
        let insetsChanged = self.safeAreaInsets != safeAreaInsets
        guard sizeChanged || insetsChanged else { return }
        pageSize = size
        self.safeAreaInsets = safeAreaInsets
        scheduleRepaginate()
    }

    var readerInsets: UIEdgeInsets {
        let horizontal = max(0, CGFloat(pageMargins) * 24)
        return UIEdgeInsets(
            top: max(CGFloat(contentTopInset), safeAreaInsets.top),
            left: horizontal,
            bottom: max(CGFloat(contentBottomInset), safeAreaInsets.bottom),
            right: horizontal
        )
    }

    private func scheduleRepaginate() {
        guard !currentContent.isEmpty, pageSize.width > 0, pageSize.height > 0 else { return }
        repaginate()
    }

    private func repaginate() {
        let previousPageFraction = pages.count > 1
            ? Double(currentPageIndex) / Double(pages.count - 1)
            : nil
        let attributed = Self.attributedText(from: currentContent, settings: self)
        fullText = attributed
        guard pageSize.width > 0, pageSize.height > 0 else {
            pages = []
            return
        }

        pages = TextPaginator.paginate(attributed, pageSize: pageSize, insets: readerInsets)
        layoutGeneration &+= 1

        if let pendingPageFraction {
            currentPageIndex = pendingShowLastPage
                ? max(0, pages.count - 1)
                : Int((pendingPageFraction * Double(max(pages.count - 1, 0))).rounded())
            self.pendingPageFraction = nil
            pendingShowLastPage = false
        } else if let previousPageFraction {
            currentPageIndex = Int((previousPageFraction * Double(max(pages.count - 1, 0))).rounded())
        }

        if currentPageIndex >= pages.count {
            currentPageIndex = max(0, pages.count - 1)
        }
    }

    static func attributedText(from text: String, settings: TXTReaderModel) -> NSAttributedString {
        let fontSize = CGFloat(max(12, min(72, 17 * settings.fontScale)))
        let font = settings.fontFamily.uiFont(ofSize: fontSize)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = max(0, font.lineHeight * CGFloat(settings.lineHeight - 1))
        paragraphStyle.paragraphSpacing = font.lineHeight * 0.65
        paragraphStyle.firstLineHeadIndent = fontSize * CGFloat(settings.paragraphIndent)
        paragraphStyle.lineBreakMode = .byWordWrapping

        return NSAttributedString(string: text, attributes: [
            .font: font,
            .paragraphStyle: paragraphStyle,
            .foregroundColor: settings.theme.foregroundUIColor,
        ])
    }

    // MARK: - 翻页与目录

    var currentChapter: BookChapter? {
        guard chapters.indices.contains(currentChapterIndex) else { return nil }
        return chapters[currentChapterIndex]
    }

    var currentChapterID: String? {
        currentChapter?.id
    }

    func selectChapter(_ chapter: BookChapter) {
        guard chapters.indices.contains(chapter.index), chapter.index != currentChapterIndex else { return }
        currentChapterIndex = chapter.index
        loadCurrentChapter()
    }

    func updateScrollProgress(_ chapterProgress: Double) {
        let fraction = min(max(chapterProgress, 0), 1)
        updateBookProgress(chapterProgress: fraction)
    }

    // MARK: - 偏好

    func resetTypography() {
        fontScale = 1.0
        fontFamily = .systemSerif
        lineHeight = 1.5
        paragraphIndent = 2.0
        pageMargins = 1.0
        contentTopInset = 56
        contentBottomInset = 32
        theme = .light
    }

    private func styleDidChange() {
        persistPreferences()
        scheduleRepaginate()
    }

    private func persistPreferences() {
        let defaults = UserDefaults.standard
        defaults.set(fontScale, forKey: PreferenceKey.fontScale)
        defaults.set(fontFamily.rawValue, forKey: PreferenceKey.fontFamily)
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
        guard chapters.count > 0 else { return 0 }
        let global = min(max(book.progressPercent, 0), 1) * Double(chapters.count)
        return min(max(global - Double(currentChapterIndex), 0), 1)
    }

    private func updateReadingProgress() {
        guard !chapters.isEmpty else { return }
        let fraction = pages.count > 1
            ? Double(currentPageIndex) / Double(pages.count - 1)
            : 0
        updateBookProgress(chapterProgress: fraction)
    }

    private func updateBookProgress(chapterProgress: Double) {
        guard !chapters.isEmpty else { return }
        let fraction = min(max(chapterProgress, 0), 1)
        let total = Double(chapters.count)
        book.currentChapterIndex = currentChapterIndex
        book.progressPercent = min(max((Double(currentChapterIndex) + fraction) / total, 0), 1)
        book.lastReadAt = .now
    }
}
