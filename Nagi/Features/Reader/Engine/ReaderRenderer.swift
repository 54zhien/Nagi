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
    private var pageSurfacePrewarmTask: Task<Void, Never>?
    private var pageSurfacePrewarmRevision: UInt = 0

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
        cancelPageSurfacePrewarm()
        surfaceEpoch &+= 1
        if let activeSurface { model.navigator?.cancelAdjacentPage(activeSurface.navigatorSurface) }
        model.navigator?.invalidateAdjacentPageSurfaces()
        model.finishPageTurnLocationTransaction(result: nil)
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

        let surface = makePageSurface(prepared, direction: direction)
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
        let preferred: NavigatorPageDirection = preferredDirection == .forward ? .forward : .backward

        let forwardReadiness = navigator.adjacentPageReadiness(direction: .forward)
        let backwardReadiness = navigator.adjacentPageReadiness(direction: .backward)
        let hasCurrentSurface = navigator.preparedCurrentPageSurface() != nil
        if hasCurrentSurface,
           prewarmStageIsPublished(forwardReadiness),
           prewarmStageIsPublished(backwardReadiness) {
            return
        }

        if pageSurfacePrewarmTask == nil {
            pageSurfacePrewarmRevision &+= 1
            let revision = pageSurfacePrewarmRevision
            let warmTask = Task { @MainActor [weak self] in
                guard let self, let navigator = self.model.navigator else { return }
                await navigator.prewarmAdjacentPageSurfaces(preferredDirection: preferred)
                let wasCancelled = Task.isCancelled
                guard revision == self.pageSurfacePrewarmRevision else { return }
                self.pageSurfacePrewarmTask = nil
                if !wasCancelled {
                    self.onStateChange?()
                }
            }
            pageSurfacePrewarmTask = warmTask
        }

        let revision = pageSurfacePrewarmRevision
        let deadline = DispatchTime.now().uptimeNanoseconds &+ 5_000_000_000
        await withTaskCancellationHandler(operation: {
            while !Task.isCancelled,
                  revision == pageSurfacePrewarmRevision,
                  DispatchTime.now().uptimeNanoseconds < deadline {
                let readiness = navigator.adjacentPageReadiness(direction: preferred)
                if prewarmStageIsTerminal(readiness) {
                    return
                }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.cancelPageSurfacePrewarm() }
        })

        guard revision == pageSurfacePrewarmRevision else { return }
        let readiness = navigator.adjacentPageReadiness(direction: preferred)
        if !prewarmStageIsPublished(readiness) {
            cancelPageSurfacePrewarm()
        }
    }

    func preparedCurrentSurface() -> NavigatorCurrentPageSurface? {
        model.navigator?.preparedCurrentPageSurface()
    }

    func preparedAdjacentSurface(direction: PageDirection) -> PageSurface? {
        guard model.pageTransition != .scroll, let navigator = model.navigator else { return nil }
        let navigatorDirection: NavigatorPageDirection = direction == .forward ? .forward : .backward
        guard let prepared = navigator.preparedAdjacentPageSurface(direction: navigatorDirection) else {
            return nil
        }
        return makePageSurface(prepared, direction: direction)
    }

    private func makePageSurface(
        _ prepared: NavigatorPageSurface,
        direction: PageDirection
    ) -> PageSurface {
        PageSurface(
            direction: direction,
            image: prepared.image,
            identity: prepared.identity,
            originIdentity: prepared.originIdentity,
            generation: prepared.generation,
            geometry: prepared.geometry,
            headerTitle: model.pageHeaderTitle(for: prepared.locator)
        )
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

        model.beginPageTurnLocationTransaction(
            origin: active.navigatorSurface.originIdentity.locator,
            target: active.navigatorSurface.locator
        )
        active.phase = .committing
        activeSurface = active
        let initialResult = await navigator.commitAdjacentPageResult(active.navigatorSurface)
        guard active.epoch == surfaceEpoch,
              activeSurface?.pageSurfaceID == surface.id,
              activeSurface?.navigatorSurface === active.navigatorSurface else {
            model.finishPageTurnLocationTransaction(result: nil)
            if activeSurface?.pageSurfaceID == surface.id {
                activeSurface = nil
            }
            return pageSurfaceCommitResult(from: initialResult)
        }

        if initialResult != .indeterminate {
            model.finishPageTurnLocationTransaction(result: initialResult)
            activeSurface = nil
            return pageSurfaceCommitResult(from: initialResult)
        }

        active.phase = .reconciling
        activeSurface = active
        return .indeterminate
    }

    func reconcile(
        surface: PageSurface,
        deadline: UInt64
    ) async -> PageSurfaceCommitResult {
        guard let navigator = model.navigator,
              let initialActive = activeSurface,
              initialActive.pageSurfaceID == surface.id,
              initialActive.phase == .reconciling else {
            return .indeterminate
        }

        while !Task.isCancelled,
              DispatchTime.now().uptimeNanoseconds < deadline {
            guard let active = activeSurface,
                  active.pageSurfaceID == surface.id,
                  active.phase == .reconciling,
                  active.epoch == initialActive.epoch,
                  active.navigatorSurface === initialActive.navigatorSurface else {
                return .indeterminate
            }

            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { break }
            let sliceDeadline = min(deadline, now &+ 750_000_000)
            let observed = await navigator.reconcileAdjacentPageResult(
                active.navigatorSurface,
                deadline: sliceDeadline
            )

            switch observed {
            case .committed, .restored:
                model.finishPageTurnLocationTransaction(result: observed)
                activeSurface = nil
                return pageSurfaceCommitResult(from: observed)
            case .indeterminate:
                let sleepStart = DispatchTime.now().uptimeNanoseconds
                guard sleepStart < deadline, !Task.isCancelled else { return .indeterminate }
                try? await Task.sleep(
                    nanoseconds: min(80_000_000, deadline - sleepStart)
                )
            }
        }
        return .indeterminate
    }

    private func pageSurfaceCommitResult(
        from result: NavigatorPageCommitResult
    ) -> PageSurfaceCommitResult {
        switch result {
        case .committed:
            return .committed
        case .restored:
            return .restored
        case .indeterminate:
            return .indeterminate
        }
    }

    func discardReconciliation(for surface: PageSurface) {
        guard activeSurface?.pageSurfaceID == surface.id,
              activeSurface?.phase == .reconciling else { return }
        model.finishPageTurnLocationTransaction(result: nil)
        activeSurface = nil
    }

    func cancel(surface: PageSurface) {
        guard let active = activeSurface, active.pageSurfaceID == surface.id else { return }
        model.navigator?.cancelAdjacentPage(active.navigatorSurface)
        switch active.phase {
        case .prepared:
            activeSurface = nil
        case .committing:
            // The navigator commit is still the transaction owner. Keep the
            // surface and deferred locator transaction alive until that
            // async call returns, even when cancellation asks it to restore.
            break
        case .reconciling:
            model.finishPageTurnLocationTransaction(result: nil)
            activeSurface = nil
        }
    }

    func navigateWithoutCustomTransition(direction: PageDirection) async -> Bool {
        cancelPageSurfacePrewarm()
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
        cancelPageSurfacePrewarm()
        if let activeSurface {
            model.navigator?.cancelAdjacentPage(activeSurface.navigatorSurface)
            if activeSurface.phase == .reconciling {
                model.finishPageTurnLocationTransaction(result: nil)
            }
        }
        surfaceEpoch &+= 1
        guard let navigator = model.navigator else {
            if activeSurface?.phase != .committing {
                activeSurface = nil
            }
            return
        }
        navigator.invalidateAdjacentPageSurfaces()
        if activeSurface?.phase != .committing {
            activeSurface = nil
        }
    }

    private func cancelPageSurfacePrewarm() {
        pageSurfacePrewarmRevision &+= 1
        pageSurfacePrewarmTask?.cancel()
        pageSurfacePrewarmTask = nil
    }

    private func prewarmStageIsTerminal(_ readiness: NavigatorPageSurfaceReadiness) -> Bool {
        switch readiness {
        case .ready, .failed, .unavailable:
            return true
        case .unknown, .preparing:
            return false
        }
    }

    private func prewarmStageIsPublished(_ readiness: NavigatorPageSurfaceReadiness) -> Bool {
        switch readiness {
        case .ready, .unavailable:
            return true
        case .unknown, .preparing, .failed:
            return false
        }
    }
}
