
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
final class ReadiumRenderer: ReaderRenderer {
    let model: EPUBReaderModel

    private(set) var isDocumentLoaded = false
    var onStateChange: (() -> Void)?

    init(book: Book) {
        model = EPUBReaderModel(book: book)
    }

    var title: String { model.title }
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

    func waitForVisualUpdate(for kind: ReaderVisualMutationKind) async {
        await model.waitForVisualUpdate(for: kind)
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

    func selectChapter(at index: Int) {
        guard model.tableOfContents.indices.contains(index) else { return }
        model.go(to: model.tableOfContents[index])
    }

    func saveProgress() {
        model.saveProgress()
        onStateChange?()
    }

    private func rebuildDocument() {
        isDocumentLoaded = true
    }
}
