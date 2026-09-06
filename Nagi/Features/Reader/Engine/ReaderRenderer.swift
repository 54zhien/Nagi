import ReadiumNavigator
import SwiftUI
import UIKit

@MainActor
final class ReadiumRenderer: ReaderRenderer, PageSurfaceProvider {
    let model: EPUBReaderModel
    private var preparedSurfaces: [UUID: NavigatorPageSurface] = [:]

    var onStateChange: (() -> Void)?

    init(book: Book) {
        model = EPUBReaderModel(book: book)
    }

    var title: String { model.title }
    var isContentReady: Bool { model.navigator != nil }
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
    var pageSurfaceProvider: (any PageSurfaceProvider)? { self }

    var readingDirection: PageTurnReadingDirection {
        model.navigator?.pageReadingProgression == .rtl ? .rightToLeft : .leftToRight
    }

    func load() async {
        model.onStateChange = { [weak self] in self?.onStateChange?() }
        await model.loadIfNeeded()
        onStateChange?()
    }

    func makeContentView(
        onToggleControls: @escaping () -> Void,
        onSwipeStart: @escaping () -> Void,
        onPageTurnRequested: @escaping (PageDirection) -> Void
    ) -> AnyView {
        model.onToggleControls = onToggleControls
        model.onSwipeStart = onSwipeStart
        model.onPageTurnRequested = onPageTurnRequested

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
                            Task { await self.load() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(SwiftUI.Color(uiColor: backgroundColor))
                )
            }

            return AnyView(
                ProgressView("正在打开阅读器…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(SwiftUI.Color(uiColor: backgroundColor))
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
        invalidatePreparedSurfaces()
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
        if preferences != model.readerPreferences {
            invalidatePreparedSurfaces()
        }
        model.apply(preferences: preferences, commitBehavior: commitBehavior)
        onStateChange?()
    }

    func updateSystemAppearance(isDark: Bool) {
        invalidatePreparedSurfaces()
        model.updateSystemAppearance(isDark: isDark)
        onStateChange?()
    }

    func selectPreset(_ preset: ReaderThemePreset) {
        invalidatePreparedSurfaces()
        model.apply(preset: preset)
        onStateChange?()
    }

    func tearDown() {
        invalidatePreparedSurfaces()
        model.tearDown()
        model.onStateChange = nil
    }

    func selectChapter(at index: Int) {
        guard model.tableOfContents.indices.contains(index) else { return }
        invalidatePreparedSurfaces()
        model.go(to: model.tableOfContents[index])
    }

    func saveProgress() {
        model.saveProgress()
        onStateChange?()
    }

    func readingPosition() -> ReadingPosition? {
        guard let locatorJSON = model.currentLocatorJSON else { return nil }
        return ReadingPosition(locatorJSON: locatorJSON)
    }

    func prepareAdjacentSurface(direction: PageDirection) async -> PageSurface? {
        guard model.pageTransition != .scroll, let navigator = model.navigator else { return nil }
        let navigatorDirection: NavigatorPageDirection = direction == .forward ? .forward : .backward
        guard let prepared = await navigator.prepareAdjacentPage(direction: navigatorDirection) else {
            return nil
        }

        let surface = PageSurface(direction: direction, view: prepared.view)
        preparedSurfaces[surface.id] = prepared
        return surface
    }

    func prewarmAdjacentSurfaces() async {
        guard model.pageTransition != .scroll, let navigator = model.navigator else { return }
        await navigator.prewarmAdjacentPageSurfaces()
    }

    func commit(surface: PageSurface) async -> Bool {
        guard let navigator = model.navigator,
              let prepared = preparedSurfaces.removeValue(forKey: surface.id) else {
            return false
        }
        return await navigator.commitAdjacentPage(prepared)
    }

    func cancel(surface: PageSurface) {
        guard let navigator = model.navigator,
              let prepared = preparedSurfaces.removeValue(forKey: surface.id) else { return }
        navigator.cancelAdjacentPage(prepared)
    }

    func navigateWithoutCustomTransition(direction: PageDirection) async -> Bool {
        guard let navigator = model.navigator else { return false }
        switch direction {
        case .forward:
            return await navigator.goForward(options: .none)
        case .backward:
            return await navigator.goBackward(options: .none)
        }
    }

    func setBuiltInPageTurnInteractionEnabled(_ enabled: Bool) {
        model.navigator?.isUserPageTurnInteractionEnabled = enabled
    }

    func invalidatePreparedSurfaces() {
        guard let navigator = model.navigator else {
            preparedSurfaces.removeAll()
            return
        }
        navigator.invalidateAdjacentPageSurfaces()
        for prepared in preparedSurfaces.values {
            navigator.cancelAdjacentPage(prepared)
        }
        preparedSurfaces.removeAll()
    }
}
