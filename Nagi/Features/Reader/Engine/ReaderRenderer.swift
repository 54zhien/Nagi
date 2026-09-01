//
//  ReaderRenderer.swift
//  Nagi
//
//  TXT 与 EPUB 的渲染适配器。两种格式的活动阅读路径都交给 Readium；
//  TextKit 实现暂时保留为兼容代码，工厂不会再选择它。
//

import Foundation
import SwiftUI
import UIKit

@MainActor
enum ReaderRendererFactory {
    static func make(book: Book) -> any ReaderRenderer {
        switch book.format {
        case .txt, .epub:
            return ReadiumRenderer(book: book)
        }
    }
}

@MainActor
final class TextKitRenderer: ReaderRenderer {
    let book: Book
    let model: TXTReaderModel

    private(set) var document: ReaderDocument?
    var onStateChange: (() -> Void)?

    init(book: Book) {
        self.book = book
        let model = TXTReaderModel(book: book)
        self.model = model
        model.onStateChange = { [weak self] in
            self?.onStateChange?()
        }
    }

    var title: String { model.title }
    var isLoading: Bool { model.isLoading }
    var errorMessage: String? { model.errorMessage }
    var currentChapterID: String? { model.currentChapterID }
    var progress: Double { model.progress }
    var chapters: [ReaderChapter] {
        model.chapters.map { chapter in
            ReaderChapter(id: chapter.id, title: chapter.title, index: chapter.index, depth: 0)
        }
    }
    var previewText: String { Self.previewExcerpt(model.fullText.string) }
    var previewChapterTitle: String { model.currentChapter?.title ?? "" }
    var isLoadingPreview: Bool { model.isLoading && model.fullText.length == 0 }
    var preferences: ReaderPreferences { model.readerPreferences }
    var backgroundColor: UIColor { model.readerBackgroundUIColor }
    var contentColor: UIColor { model.readerContentUIColor }
    var headerColor: UIColor { model.readerContentUIColor }
    var chromeLayout: ReaderChromeLayout { .legacyOverlay }
    var handlesContentTap: Bool { true }
    var canGoNext: Bool { model.canGoNext }
    var canGoPrevious: Bool { model.canGoPrevious }

    func load() async {
        await model.load()
        if !model.chapters.isEmpty {
            document = ReaderDocument(
                id: book.id,
                title: model.title,
                author: book.author,
                chapters: chapters
            )
        }
        onStateChange?()
    }

    func makeContentView(
        onToggleControls: @escaping () -> Void,
        onSwipeStart: @escaping () -> Void
    ) -> AnyView {
        AnyView(
            TXTReaderContentView(
                model: model,
                onStateChange: { [weak self] in self?.onStateChange?() },
                onSwipeStart: onSwipeStart
            )
        )
    }

    func waitForVisualUpdate() async {
        await Task.yield()
    }

    func restoreFromForeground(isDark: Bool) async {
        _ = isDark
        await Task.yield()
    }

    @discardableResult
    func updateViewport(size: CGSize, safeAreaInsets: UIEdgeInsets, displayScale: CGFloat) -> Bool {
        let changed = model.updateViewport(size: size, safeAreaInsets: safeAreaInsets)
        _ = displayScale
        if changed {
            onStateChange?()
        }
        return changed
    }

    func apply(
        preferences: ReaderPreferences,
        commitBehavior: ReaderPreferenceCommitBehavior
    ) {
        _ = commitBehavior
        model.apply(preferences: preferences)
        onStateChange?()
    }

    func updateSystemAppearance(isDark: Bool) {
        model.updateSystemAppearance(isDark: isDark)
        onStateChange?()
    }

    func selectPreset(_ preset: ReaderThemePreset) {
        model.apply(preset: preset)
        onStateChange?()
    }

    func tearDown() {
        model.cancelPendingLayout()
        model.onStateChange = nil
    }

    func clearError() {
        model.errorMessage = nil
    }

    func goForward() {
        model.goForward()
        onStateChange?()
    }

    func goBackward() {
        model.goBackward()
        onStateChange?()
    }

    func selectChapter(at index: Int) {
        guard model.chapters.indices.contains(index) else { return }
        model.selectChapter(model.chapters[index])
        onStateChange?()
    }

    func saveProgress() {
        model.flushReadingProgress()
        onStateChange?()
    }

    func readingPosition() -> ReadingPosition? {
        nil
    }

    private static func previewExcerpt(_ text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > 280 else { return cleaned }
        return String(cleaned.prefix(280)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

@MainActor
final class ReadiumRenderer: ReaderRenderer {
    let book: Book
    let model: EPUBReaderModel

    private(set) var document: ReaderDocument?
    var onStateChange: (() -> Void)?

    init(book: Book) {
        self.book = book
        model = EPUBReaderModel(book: book)
    }

    var title: String { model.title }
    var isLoading: Bool { model.isLoading }
    var errorMessage: String? { model.errorMessage }
    var currentChapterID: String? { model.currentTOCEntryID ?? model.currentReadingHref }
    var progress: Double { model.progress }
    var chapters: [ReaderChapter] {
        model.tableOfContents.enumerated().map { index, entry in
            ReaderChapter(id: entry.id, title: entry.title, index: index, depth: entry.depth)
        }
    }
    var previewText: String { model.previewText }
    var previewChapterTitle: String { model.previewChapterTitle }
    var isLoadingPreview: Bool { model.isLoadingPreview }
    var preferences: ReaderPreferences { model.readerPreferences }
    var backgroundColor: UIColor { model.readerBackgroundUIColor }
    var contentColor: UIColor { model.readerContentUIColor }
    var headerColor: UIColor { model.readerContentUIColor }
    var chromeLayout: ReaderChromeLayout { .cornerAligned }
    var handlesContentTap: Bool { false }
    var canGoNext: Bool { model.navigator != nil }
    var canGoPrevious: Bool { model.navigator != nil }

    func load() async {
        model.onStateChange = { [weak self] in self?.onStateChange?() }
        await model.loadIfNeeded()
        rebuildDocument()
        onStateChange?()
    }

    func makeContentView(
        onToggleControls: @escaping () -> Void,
        onSwipeStart: @escaping () -> Void
    ) -> AnyView {
        model.onToggleControls = onToggleControls
        model.onSwipeStart = onSwipeStart

        guard let navigator = model.navigator else {
            if let error = model.errorMessage {
                return AnyView(
                    VStack(spacing: 12) {
                        ContentUnavailableView(
                            "无法显示内容",
                            systemImage: "book.closed",
                            description: Text(error)
                        )

                        Button("重试") {
                            Task { await self.model.loadIfNeeded() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: backgroundColor))
                )
            }

            return AnyView(
                ProgressView("正在打开阅读器…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: backgroundColor))
            )
        }

        return AnyView(
            ReadiumNavigatorView(
                navigator: navigator,
                background: Color(uiColor: backgroundColor),
                isReflowable: model.isReflowable
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
    }

    func waitForVisualUpdate() async {
        await model.waitForVisualUpdate()
    }

    func restoreFromForeground(isDark: Bool) async {
        await model.restoreFromForeground(isDark: isDark)
        onStateChange?()
    }

    @discardableResult
    func updateViewport(size: CGSize, safeAreaInsets: UIEdgeInsets, displayScale: CGFloat) -> Bool {
        return model.updateViewport(
            size: size,
            safeAreaInsets: safeAreaInsets,
            displayScale: displayScale
        )
    }

    func apply(
        preferences: ReaderPreferences,
        commitBehavior: ReaderPreferenceCommitBehavior
    ) {
        model.apply(preferences: preferences, commitBehavior: commitBehavior)
        onStateChange?()
    }

    func updateSystemAppearance(isDark: Bool) {
        model.updateSystemAppearance(isDark: isDark)
        onStateChange?()
    }

    func selectPreset(_ preset: ReaderThemePreset) {
        let epubPreset: EPUBReaderPreset
        switch preset {
        case .original: epubPreset = .original
        case .quiet: epubPreset = .quiet
        case .paper: epubPreset = .paper
        }
        model.apply(preset: epubPreset)
        onStateChange?()
    }

    func tearDown() {
        model.tearDown()
        model.onStateChange = nil
    }

    func clearError() {
        model.clearError()
    }

    func goForward() {
        model.goForward()
    }

    func goBackward() {
        model.goBackward()
    }

    func selectChapter(at index: Int) {
        guard model.tableOfContents.indices.contains(index) else { return }
        model.go(to: model.tableOfContents[index])
    }

    func saveProgress() {
        model.saveProgress()
        onStateChange?()
    }

    func readingPosition() -> ReadingPosition? {
        // Do not re-persist a legacy TXT location JSON as if it were a
        // Readium Locator.  The model only exposes a value after validation or
        // after the navigator reports a new location.
        guard let locatorJSON = model.currentLocatorJSON else { return nil }
        return ReadingPosition(
            bookID: book.id,
            chapterID: currentChapterID,
            progression: progress,
            payload: .epub(
                EPUBReadingPosition(
                    locatorJSON: locatorJSON,
                    href: model.currentReadingHref,
                    progression: progress
                )
            )
        )
    }

    private func rebuildDocument() {
        document = ReaderDocument(
            id: book.id,
            title: model.title,
            author: book.author,
            chapters: chapters
        )
    }
}

private struct TXTReaderContentView: View {
    @Environment(\.displayScale) private var displayScale

    let model: TXTReaderModel
    let onStateChange: () -> Void
    let onSwipeStart: () -> Void

    var body: some View {
        GeometryReader { geometry in
            Group {
                if model.isLoading && model.layoutPhase != .ready {
                    ProgressView("正在打开 TXT…")
                } else if let error = model.errorMessage {
                    ContentUnavailableView(
                        "无法打开",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                } else if model.layoutPhase != .ready {
                    ProgressView(model.layoutPhase.progressTitle)
                } else if model.flowMode == .paged {
                    PageViewController(
                        pages: model.pages,
                        transitionStyle: model.pageTransition == .pageCurl
                            ? .pageCurl
                            : .scroll,
                        insets: model.readerInsets,
                        background: Color(uiColor: model.readerBackgroundUIColor),
                        currentPage: Binding(
                            get: { model.currentPageIndex },
                            set: {
                                model.currentPageIndex = $0
                                onStateChange()
                            }
                        ),
                        pageRanges: model.pageRanges,
                        onSwipeStart: onSwipeStart,
                        onNeedNextPages: { model.requestNextPageBatch() },
                        onNeedPreviousPages: { model.requestPreviousPageBatch() }
                    )
                    .id("\(model.layoutGeneration)-\(model.pageTransition.rawValue)")
                } else {
                    ScrollableTextView(
                        attributedText: model.fullText,
                        insets: model.readerInsets,
                        background: Color(uiColor: model.readerBackgroundUIColor),
                        revision: model.layoutGeneration,
                        positionID: model.scrollPositionID,
                        initialCharacterOffset: model.initialScrollCharacterOffset,
                        initialProgress: model.initialScrollProgress,
                        onSwipeStart: onSwipeStart,
                        onCharacterOffset: {
                            model.updateScrollCharacterOffset($0)
                            onStateChange()
                        },
                        onProgress: {
                            model.updateScrollProgress($0)
                            onStateChange()
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: model.readerBackgroundUIColor))
            .onAppear {
                updateViewport(geometry)
            }
            .onChange(of: geometry.size) { _, _ in
                updateViewport(geometry)
            }
            .onChange(of: geometry.safeAreaInsets.top) { _, _ in
                updateViewport(geometry)
            }
            .onChange(of: geometry.safeAreaInsets.bottom) { _, _ in
                updateViewport(geometry)
            }
            .onChange(of: model.layoutGeneration) { _, _ in
                onStateChange()
            }
        }
        .ignoresSafeArea()
    }

    private func updateViewport(_ geometry: GeometryProxy) {
        model.updateViewport(
            size: geometry.size,
            safeAreaInsets: UIEdgeInsets(
                top: geometry.safeAreaInsets.top,
                left: geometry.safeAreaInsets.leading,
                bottom: geometry.safeAreaInsets.bottom,
                right: geometry.safeAreaInsets.trailing
            )
        )
    }
}
