import ReadiumNavigator
import SwiftUI
import UIKit

@MainActor
final class ReadiumRenderer: ReaderRenderer, PageSurfaceProvider {
    let model: EPUBReaderModel
    private struct ActiveSurface {
        let navigatorSurface: NavigatorPageSurface
        let pageSurfaceID: UUID
        let epoch: UInt64
        var phase: Phase

        enum Phase: Equatable {
            case prepared
            case committing
            case reconciling
        }
    }

    private var activeSurface: ActiveSurface?
    private var surfaceEpoch: UInt64 = 0

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
    var isPageSurfaceProviderReady: Bool { model.navigator != nil }

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
        // Teardown is terminal: no caller can observe a later reconciliation,
        // so terminate and discard every old transaction bookkeeping entry.
        surfaceEpoch &+= 1
        if let activeSurface { model.navigator?.cancelAdjacentPage(activeSurface.navigatorSurface) }
        model.navigator?.invalidateAdjacentPageSurfaces()
        activeSurface = nil
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

    func adjacentSurfaceReadiness(direction: PageDirection) -> NavigatorPageSurfaceReadiness {
        guard model.pageTransition != .scroll, let navigator = model.navigator else {
            return .unavailable
        }
        let navigatorDirection: NavigatorPageDirection = direction == .forward ? .forward : .backward
        return navigator.adjacentPageReadiness(direction: navigatorDirection)
    }

    func takePreparedAdjacentSurface(direction: PageDirection) -> PageSurface? {
        guard model.pageTransition != .scroll, let navigator = model.navigator else { return nil }
        let navigatorDirection: NavigatorPageDirection = direction == .forward ? .forward : .backward
        guard let prepared = navigator.takePreparedAdjacentPage(direction: navigatorDirection) else {
            return nil
        }

        let surface = PageSurface(
            direction: direction,
            image: prepared.image,
            identity: prepared.identity,
            originIdentity: prepared.originIdentity,
            generation: prepared.generation,
            geometry: prepared.geometry,
            headerTitle: model.pageHeaderTitle(for: prepared.locator)
        )
        activeSurface = ActiveSurface(
            navigatorSurface: prepared,
            pageSurfaceID: surface.id,
            epoch: surfaceEpoch,
            phase: .prepared
        )
        return surface
    }

    func prewarmAdjacentSurfaces(preferredDirection: PageDirection) async {
        guard model.pageTransition != .scroll, let navigator = model.navigator else { return }
        await navigator.prewarmAdjacentPageSurfaces(
            preferredDirection: preferredDirection == .forward ? .forward : .backward
        )
    }

    func preparedCurrentSurface() -> NavigatorCurrentPageSurface? {
        model.navigator?.preparedCurrentPageSurface()
    }

    func commit(surface: PageSurface) async -> PageSurfaceCommitResult {
        guard var active = activeSurface,
              active.pageSurfaceID == surface.id,
              active.phase == .prepared else {
            return .indeterminate
        }
        guard let navigator = model.navigator else {
            activeSurface = nil
            return .indeterminate
        }
        guard active.epoch == surfaceEpoch else {
            navigator.cancelAdjacentPage(active.navigatorSurface)
            activeSurface = nil
            return .restored
        }
        active.phase = .committing
        activeSurface = active
        let result = await navigator.commitAdjacentPageResult(active.navigatorSurface)
        guard active.epoch == surfaceEpoch,
              activeSurface?.pageSurfaceID == surface.id,
              activeSurface?.navigatorSurface === active.navigatorSurface else {
            return .indeterminate
        }
        switch result {
        case .committed:
            activeSurface = nil
            return .committed
        case .restored:
            activeSurface = nil
            return .restored
        case .indeterminate:
            active.phase = .reconciling
            activeSurface = active
            return .indeterminate
        }
    }

    func reconcile(
        surface: PageSurface,
        deadline: UInt64
    ) async -> PageSurfaceCommitResult {
        guard let navigator = model.navigator,
              let active = activeSurface,
              active.pageSurfaceID == surface.id,
              active.phase == .reconciling else {
            return .indeterminate
        }
        switch await navigator.reconcileAdjacentPageResult(
            active.navigatorSurface,
            deadline: deadline
        ) {
        case .committed:
            activeSurface = nil
            return .committed
        case .restored:
            activeSurface = nil
            return .restored
        case .indeterminate: return .indeterminate
        }
    }

    func discardReconciliation(for surface: PageSurface) {
        guard activeSurface?.pageSurfaceID == surface.id,
              activeSurface?.phase == .reconciling else { return }
        activeSurface = nil
    }

    func cancel(surface: PageSurface) {
        guard let active = activeSurface, active.pageSurfaceID == surface.id else { return }
        model.navigator?.cancelAdjacentPage(active.navigatorSurface)
        if active.phase == .prepared { activeSurface = nil }
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
        // External ownership changes invalidate the old token immediately.
        // The old async task is generation/epoch-stale and must not block the
        // new navigation or layout operation.
        if let activeSurface { model.navigator?.cancelAdjacentPage(activeSurface.navigatorSurface) }
        surfaceEpoch &+= 1
        guard let navigator = model.navigator else {
            activeSurface = nil
            return
        }
        navigator.invalidateAdjacentPageSurfaces()
        activeSurface = nil
    }
}
