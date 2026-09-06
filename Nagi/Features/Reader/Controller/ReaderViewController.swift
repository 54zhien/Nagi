import SwiftUI
import UIKit

@MainActor
final class ReaderViewController: UIViewController, UIGestureRecognizerDelegate {
    private let model: ReaderViewModel
    private let readerTransitionCoordinator: ReaderTransitionCoordinator

    private let chromeView = ReaderChromeView()
    private let snapshotHostView = ReaderSnapshotHostView()
    private var contentHostController: UIHostingController<ReaderContentHostView>?
    private var contentSignature: ReaderContentSignature?
    private var panGestureRecognizer: UIPanGestureRecognizer?
    private let pageTurnStateMachine = PageTurnStateMachine()
    private var pageTurnTask: Task<Void, Never>?
    private var pageTurnPrewarmTask: Task<Void, Never>?
    private var pageTurnPrewarmRevision: UInt = 0
    private var cachedCurrentComposite: UIView?
    private var activeTargetComposite: UIView?
    private var adjacentSurfaceCacheIsWarm = false
    private var activePageSurface: PageSurface?
    private var pageTurnAnimator: (any PageTurnAnimating)?
    private var activeTurnGeneration: UInt?
    private var pendingPanTranslationX: CGFloat = 0
    private var pendingPanVelocityX: CGFloat = 0
    private var pendingPanDidEnd = false
    private var panHasStartedTurn = false
    private var isBoundaryResistanceTurn = false

    private var latestStateRevision = 0
    private var latestTitle: String
    private var latestTitleColor: UIColor
    private var latestReaderBackground: UIColor
    private var latestTitleFontFamily: ReaderFontFamily
    private var latestShowsTitle: Bool
    private var latestReduceMotion: Bool
    private var latestCornerInsets: ReaderChromeCornerInsets
    private var latestPageSurfacePreferences: ReaderPreferences
    private var lastViewportBounds = CGRect.null
    private var lastViewportContentInsets = UIEdgeInsets.zero
    private var lastViewportDisplayScale: CGFloat = 0

    private var onDismiss: () -> Void
    private var onTableOfContents: () -> Void
    private var onSettings: () -> Void

    init(
        model: ReaderViewModel,
        title: String,
        titleColor: UIColor,
        readerBackground: UIColor,
        titleFontFamily: ReaderFontFamily,
        showsTitle: Bool,
        reduceMotion: Bool,
        cornerInsets: ReaderChromeCornerInsets,
        onDismiss: @escaping () -> Void,
        onTableOfContents: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        transitionCoordinator: ReaderTransitionCoordinator
    ) {
        self.model = model
        self.readerTransitionCoordinator = transitionCoordinator
        latestTitle = title
        latestTitleColor = titleColor
        latestReaderBackground = readerBackground
        latestTitleFontFamily = titleFontFamily
        latestShowsTitle = showsTitle
        latestReduceMotion = reduceMotion
        latestCornerInsets = cornerInsets
        latestPageSurfacePreferences = model.preferences
        self.onDismiss = onDismiss
        self.onTableOfContents = onTableOfContents
        self.onSettings = onSettings
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = latestReaderBackground
        view.isOpaque = true
        view.accessibilityLabel = "阅读器"
        view.accessibilityElementsHidden = false

        contentSignature = makeContentSignature()
        let contentRoot = makeContentRoot()
        let contentController = UIHostingController(rootView: contentRoot)
        contentController.view.backgroundColor = .clear
        contentController.view.isOpaque = false
        contentController.view.accessibilityCustomActions = [
            UIAccessibilityCustomAction(
                name: "显示或隐藏阅读控件",
                target: self,
                selector: #selector(accessibilityToggleControls(_:))
            )
        ]
        addChild(contentController)
        view.insertSubview(contentController.view, at: 0)
        contentController.didMove(toParent: self)
        contentHostController = contentController

        chromeView.onDismiss = { [weak self] in self?.performAfterCancellingPageTurn { $0.onDismiss() } }
        chromeView.onTableOfContents = { [weak self] in self?.performAfterCancellingPageTurn { $0.onTableOfContents() } }
        chromeView.onSettings = { [weak self] in self?.performAfterCancellingPageTurn { $0.onSettings() } }
        view.addSubview(chromeView)

        snapshotHostView.isUserInteractionEnabled = false
        snapshotHostView.accessibilityElementsHidden = true
        snapshotHostView.isAccessibilityElement = false
        snapshotHostView.fallbackBackgroundColor = latestReaderBackground
        view.insertSubview(snapshotHostView, belowSubview: chromeView)

        readerTransitionCoordinator.register(captureAnchor: contentController.view)
        readerTransitionCoordinator.register(snapshotHost: snapshotHostView)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        pan.delegate = self
        contentController.view.addGestureRecognizer(pan)
        panGestureRecognizer = pan

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(voiceOverStatusDidChange),
            name: UIAccessibility.voiceOverStatusDidChangeNotification,
            object: nil
        )

        updateChrome()
        configurePageTurnInteraction()
        setNeedsStatusBarAppearanceUpdate()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        schedulePageTurnPrewarm()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        chromeView.setNeedsLayout()
        view.setNeedsLayout()
    }

    func update(
        stateRevision: Int,
        title: String,
        titleColor: UIColor,
        readerBackground: UIColor,
        titleFontFamily: ReaderFontFamily,
        showsTitle: Bool,
        reduceMotion: Bool,
        cornerInsets: ReaderChromeCornerInsets,
        onDismiss: @escaping () -> Void,
        onTableOfContents: @escaping () -> Void,
        onSettings: @escaping () -> Void
    ) {
        let stateRevisionChanged = latestStateRevision != stateRevision
        let showsTitleChanged = latestShowsTitle != showsTitle
        let cornerInsetsChanged = latestCornerInsets != cornerInsets
        let pageSurfacePreferencesChanged = latestPageSurfacePreferences != model.preferences
        latestStateRevision = stateRevision
        latestTitle = title
        latestTitleColor = titleColor
        latestReaderBackground = readerBackground
        latestTitleFontFamily = titleFontFamily
        latestShowsTitle = showsTitle
        latestReduceMotion = reduceMotion
        latestCornerInsets = cornerInsets
        latestPageSurfacePreferences = model.preferences
        self.onDismiss = onDismiss
        self.onTableOfContents = onTableOfContents
        self.onSettings = onSettings

        guard isViewLoaded else { return }

        view.backgroundColor = readerBackground
        snapshotHostView.fallbackBackgroundColor = readerBackground
        updateChrome()
        if showsTitleChanged || cornerInsetsChanged {
            view.setNeedsLayout()
        }
        if stateRevisionChanged {
            refreshContentIfNeeded()
            schedulePageTurnPrewarm()
        }
        if pageSurfacePreferencesChanged {
            cancelPageTurn(animated: false)
            invalidatePageTurnCache()
        }
        configurePageTurnInteraction()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let bounds = view.bounds
        contentHostController?.view.frame = bounds
        chromeView.frame = bounds
        snapshotHostView.frame = bounds

        let chromeSafeAreaInsets = view.safeAreaInsets
        let inheritedCornerRadius = max(view.layer.cornerRadius, view.window?.layer.cornerRadius ?? 0)
        let safeAreaDerivedRadius = max(chromeSafeAreaInsets.top, chromeSafeAreaInsets.bottom)
        let pageCornerRadius = min(
            max(inheritedCornerRadius, safeAreaDerivedRadius),
            min(bounds.width, bounds.height) / 2
        )
        snapshotHostView.layer.cornerCurve = .continuous
        snapshotHostView.layer.cornerRadius = pageCornerRadius
        snapshotHostView.layer.masksToBounds = true
        let contentInsets = readableContentInsets(for: chromeSafeAreaInsets)
        let displayScale = view.window?.screen.scale ?? UIScreen.main.scale
        guard bounds != lastViewportBounds
            || contentInsets != lastViewportContentInsets
            || displayScale != lastViewportDisplayScale else {
            return
        }

        let viewportChanged = !lastViewportBounds.isNull && lastViewportBounds != bounds
        lastViewportBounds = bounds
        lastViewportContentInsets = contentInsets
        lastViewportDisplayScale = displayScale
        if viewportChanged {
            cancelPageTurn(animated: false)
            invalidatePageTurnCache()
        }
        model.updateViewport(
            size: bounds.size,
            safeAreaInsets: contentInsets,
            displayScale: displayScale
        )
        schedulePageTurnPrewarm()
    }

    func dismantle() {
        NotificationCenter.default.removeObserver(self)
        cancelPageTurn(animated: false)
        pageTurnPrewarmTask?.cancel()
        pageTurnPrewarmTask = nil
        cachedCurrentComposite = nil
        model.pageSurfaceProvider?.setBuiltInPageTurnInteractionEnabled(true)
        panGestureRecognizer?.removeTarget(nil, action: nil)
        panGestureRecognizer?.delegate = nil
        panGestureRecognizer = nil

        readerTransitionCoordinator.cancel()
        chromeView.onDismiss = nil
        chromeView.onTableOfContents = nil
        chromeView.onSettings = nil
        chromeView.setControlsVisible(
            false,
            animated: false,
            reduceMotion: latestReduceMotion
        )

        if let contentHostController {
            contentHostController.willMove(toParent: nil)
            contentHostController.view.removeFromSuperview()
            contentHostController.removeFromParent()
            self.contentHostController = nil
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: gesture.view)
        let velocity = gesture.velocity(in: gesture.view)

        switch gesture.state {
        case .began:
            guard isCustomPageTurnEnabled else { return }
            pendingPanTranslationX = translation.x
            pendingPanVelocityX = velocity.x
            pendingPanDidEnd = false
            panHasStartedTurn = false

        case .changed:
            pendingPanTranslationX = translation.x
            pendingPanVelocityX = velocity.x
            startPageTurnFromPanIfNeeded()
            updateInteractivePageTurn()

        case .ended:
            pendingPanTranslationX = translation.x
            pendingPanVelocityX = velocity.x
            pendingPanDidEnd = true
            startPageTurnFromPanIfNeeded()
            finishInteractivePageTurnIfReady()

        case .cancelled, .failed:
            cancelPageTurn(animated: pageTurnStateMachine.state == .interactive)

        default:
            break
        }
    }

    @objc private func voiceOverStatusDidChange() {
        cancelPageTurn(animated: false)
        configurePageTurnInteraction()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        cancelPageTurn(animated: false)
        invalidatePageTurnCache()
    }

    @objc private func accessibilityToggleControls(
        _ action: UIAccessibilityCustomAction
    ) -> Bool {
        _ = action
        chromeView.noteInteraction()
        chromeView.toggleControls()
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        let isManagedGesture = gestureRecognizer === panGestureRecognizer
        let isOtherManagedGesture = otherGestureRecognizer === panGestureRecognizer
        guard isManagedGesture || isOtherManagedGesture,
              let contentView = contentHostController?.view else {
            return false
        }

        if isCustomPageTurnEnabled {
            return false
        }

        let peer = isManagedGesture ? otherGestureRecognizer : gestureRecognizer
        guard let peerView = peer.view else { return false }
        return peerView === contentView || peerView.isDescendant(of: contentView)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panGestureRecognizer, let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return true
        }
        guard isCustomPageTurnEnabled else { return false }
        let velocity = pan.velocity(in: pan.view)
        return abs(velocity.x) > abs(velocity.y) && abs(velocity.x) > 20
    }

    private func updateChrome() {
        chromeView.update(
            title: latestTitle,
            titleColor: latestTitleColor,
            fontFamily: latestTitleFontFamily,
            showsTitle: latestShowsTitle,
            reduceMotion: latestReduceMotion,
            cornerInsets: latestCornerInsets
        )
    }

    private func readableContentInsets(for systemInsets: UIEdgeInsets) -> UIEdgeInsets {
        var contentInsets = systemInsets
        contentInsets.top += CGFloat(
            ReaderLayoutMetrics.pageHeaderHeight
                + ReaderLayoutMetrics.contentTopSpacing
        )

        let controlRadius = CGFloat(ReaderLayoutMetrics.chromeControlDiameter / 2)
        let bottomControlCenter = max(
            controlRadius,
            max(
                latestCornerInsets.bottomLeading.height,
                latestCornerInsets.bottomTrailing.height
            )
        )
        let controlClearance = bottomControlCenter
            + controlRadius
            + CGFloat(ReaderLayoutMetrics.contentBottomControlSpacing)
        contentInsets.bottom = max(contentInsets.bottom, controlClearance)
        return contentInsets
    }

    private func handleContentToggle() {
        chromeView.noteInteraction()
        chromeView.toggleControls()
    }

    private var isCustomPageTurnEnabled: Bool {
        model.preferences.pageTransition != .scroll
            && !latestReduceMotion
            && !UIAccessibility.isVoiceOverRunning
            && model.pageSurfaceProvider != nil
    }

    private func configurePageTurnInteraction() {
        let enabled = isCustomPageTurnEnabled
        panGestureRecognizer?.isEnabled = enabled
        model.pageSurfaceProvider?.setBuiltInPageTurnInteractionEnabled(!enabled)
        if !enabled, pageTurnStateMachine.state != .idle {
            cancelPageTurn(animated: false)
        }
        if enabled {
            schedulePageTurnPrewarm()
        }
    }

    private func startPageTurn(direction: PageDirection, interactive: Bool) {
        guard let provider = model.pageSurfaceProvider else { return }
        guard model.preferences.pageTransition != .scroll else {
            handleContentToggle()
            return
        }
        guard let generation = pageTurnStateMachine.prepare(direction: direction) else { return }

        guard let currentComposite = cachedCurrentComposite else {
            pageTurnStateMachine.invalidate()
            schedulePageTurnPrewarm()
            return
        }

        activeTurnGeneration = generation
        pendingPanDidEnd = !interactive
        if !interactive {
            pendingPanTranslationX = 0
            pendingPanVelocityX = 0
        }

        pageTurnTask?.cancel()
        pageTurnTask = Task { @MainActor [weak self] in
            guard let self else { return }

            if latestReduceMotion || UIAccessibility.isVoiceOverRunning {
                _ = pageTurnStateMachine.enterFallback(.unsupportedContent, generation: generation)
                _ = await provider.navigateWithoutCustomTransition(direction: direction)
                _ = pageTurnStateMachine.finish(generation: generation)
                activeTurnGeneration = nil
                return
            }

            guard let surface = await provider.prepareAdjacentSurface(direction: direction) else {
                guard pageTurnStateMachine.accepts(generation) else { return }
                let destinationX = PageTurnMetrics.completionTranslationX(
                    containerWidth: snapshotHostView.bounds.width,
                    direction: direction,
                    readingDirection: provider.readingDirection
                )
                let boundaryAnimator = PageTurnBoundaryAnimator(
                    hostView: snapshotHostView,
                    currentView: currentComposite,
                    completionTranslationX: destinationX
                )
                isBoundaryResistanceTurn = true
                pageTurnAnimator = boundaryAnimator
                chromeView.setPageHeaderHiddenForTransition(true)
                boundaryAnimator.install()
                guard pageTurnStateMachine.beginInteractive(generation: generation) else {
                    cleanupPageTurn(cancelPreparedSurface: false)
                    return
                }
                updateInteractivePageTurn()
                finishInteractivePageTurnIfReady()
                return
            }

            guard !Task.isCancelled, pageTurnStateMachine.accepts(generation) else {
                provider.cancel(surface: surface)
                return
            }

            cachedCurrentComposite = nil
            let targetComposite = makeCompositeSurface(content: surface.view)
            activeTargetComposite = targetComposite
            adjacentSurfaceCacheIsWarm = false
            let readingDirection = provider.readingDirection
            let destinationX = PageTurnMetrics.completionTranslationX(
                containerWidth: snapshotHostView.bounds.width,
                direction: direction,
                readingDirection: readingDirection
            )
            let animator: any PageTurnAnimating
            switch model.preferences.pageTransition {
            case .pageCurl:
                animator = PageTurnCurlAnimator(
                    hostView: snapshotHostView,
                    currentView: currentComposite,
                    targetView: targetComposite,
                    completionTranslationX: destinationX,
                    direction: direction,
                    isDark: isDarkPageBackground
                ) ?? PageTurnVisualAnimator(
                    style: .cover,
                    hostView: snapshotHostView,
                    currentView: currentComposite,
                    targetView: targetComposite,
                    direction: direction,
                    completionTranslationX: destinationX,
                    isDark: isDarkPageBackground
                )
            case .fade:
                animator = PageTurnVisualAnimator(
                    style: .fade,
                    hostView: snapshotHostView,
                    currentView: currentComposite,
                    targetView: targetComposite,
                    direction: direction,
                    completionTranslationX: destinationX,
                    isDark: isDarkPageBackground
                )
            case .slide, .scroll:
                animator = PageTurnVisualAnimator(
                    style: .cover,
                    hostView: snapshotHostView,
                    currentView: currentComposite,
                    targetView: targetComposite,
                    direction: direction,
                    completionTranslationX: destinationX,
                    isDark: isDarkPageBackground
                )
            }

            activePageSurface = surface
            pageTurnAnimator = animator
            chromeView.hideControlsForSwipe()
            chromeView.setPageHeaderHiddenForTransition(true)
            animator.install()
            guard pageTurnStateMachine.beginInteractive(generation: generation) else {
                cleanupPageTurn(cancelPreparedSurface: true)
                return
            }

            if interactive {
                updateInteractivePageTurn()
                finishInteractivePageTurnIfReady()
            } else {
                _ = pageTurnStateMachine.finish(with: .complete, generation: generation)
                animatePageTurnCompletion(generation: generation)
            }
        }
    }

    private func updateInteractivePageTurn() {
        guard let generation = activeTurnGeneration,
              let direction = pageTurnStateMachine.direction,
              pageTurnStateMachine.state == .interactive else { return }
        let progress = PageTurnMetrics.progress(
            forTranslationX: pendingPanTranslationX,
            containerWidth: snapshotHostView.bounds.width,
            direction: direction,
            readingDirection: model.pageSurfaceProvider?.readingDirection ?? .leftToRight
        )
        guard pageTurnStateMachine.updateInteractive(progress: progress, generation: generation) else { return }
        pageTurnAnimator?.update(progress: progress)
    }

    private func finishInteractivePageTurnIfReady() {
        guard pendingPanDidEnd,
              let generation = activeTurnGeneration,
              let direction = pageTurnStateMachine.direction,
              pageTurnStateMachine.state == .interactive else { return }

        let decision: PageTurnDecision = isBoundaryResistanceTurn ? .cancel : PageTurnMetrics.decision(
            progress: pageTurnStateMachine.progress,
            velocityX: pendingPanVelocityX,
            direction: direction,
            readingDirection: model.pageSurfaceProvider?.readingDirection ?? .leftToRight
        )
        guard pageTurnStateMachine.finish(with: decision, generation: generation) else { return }

        switch decision {
        case .complete:
            animatePageTurnCompletion(generation: generation)
        case .cancel:
            pageTurnAnimator?.animateCancellation { [weak self] in
                guard let self else { return }
                _ = self.pageTurnStateMachine.finishCancellation(generation: generation)
                self.cleanupPageTurn(cancelPreparedSurface: true)
            }
        }
    }

    private func animatePageTurnCompletion(generation: UInt) {
        pageTurnAnimator?.animateCompletion { [weak self] finished in
            guard let self, self.pageTurnStateMachine.accepts(generation) else { return }
            guard finished else {
                self.pageTurnStateMachine.invalidate()
                self.cleanupPageTurn(cancelPreparedSurface: true)
                return
            }
            guard self.pageTurnStateMachine.beginCommitting(generation: generation),
                  let provider = self.model.pageSurfaceProvider,
                  let surface = self.activePageSurface else {
                self.cancelPageTurn(animated: false)
                return
            }

            self.pageTurnTask = Task { @MainActor [weak self] in
                let committed = await provider.commit(surface: surface)
                guard let self, self.pageTurnStateMachine.accepts(generation) else { return }
                if committed {
                    let committedComposite = self.activeTargetComposite
                    self.activePageSurface = nil
                    _ = self.pageTurnStateMachine.finish(generation: generation)
                    self.cleanupPageTurn(cancelPreparedSurface: false)
                    self.cachedCurrentComposite = committedComposite
                    self.schedulePageTurnPrewarm()
                } else {
                    self.pageTurnStateMachine.invalidate()
                    self.cleanupPageTurn(cancelPreparedSurface: false)
                    self.invalidatePageTurnCache()
                    self.schedulePageTurnPrewarm()
                }
            }
        }
    }

    private func cancelPageTurn(animated: Bool) {
        pageTurnTask?.cancel()
        pageTurnTask = nil

        guard pageTurnStateMachine.state != .idle else {
            cleanupPageTurn(cancelPreparedSurface: true)
            return
        }

        if animated, pageTurnStateMachine.state == .interactive,
           let generation = activeTurnGeneration {
            _ = pageTurnStateMachine.finish(with: .cancel, generation: generation)
            pageTurnAnimator?.animateCancellation { [weak self] in
                guard let self else { return }
                _ = self.pageTurnStateMachine.finishCancellation(generation: generation)
                self.cleanupPageTurn(cancelPreparedSurface: true)
                self.schedulePageTurnPrewarm()
            }
            return
        }

        pageTurnStateMachine.invalidate()
        cleanupPageTurn(cancelPreparedSurface: true)
    }

    private func cleanupPageTurn(cancelPreparedSurface: Bool) {
        pageTurnTask?.cancel()
        pageTurnTask = nil
        if cancelPreparedSurface, let surface = activePageSurface {
            model.pageSurfaceProvider?.cancel(surface: surface)
        }
        activePageSurface = nil
        activeTargetComposite = nil
        pageTurnAnimator?.remove()
        pageTurnAnimator = nil
        chromeView.setPageHeaderHiddenForTransition(false)
        activeTurnGeneration = nil
        pendingPanTranslationX = 0
        pendingPanVelocityX = 0
        pendingPanDidEnd = false
        panHasStartedTurn = false
        isBoundaryResistanceTurn = false
    }

    private func startPageTurnFromPanIfNeeded() {
        guard !panHasStartedTurn else { return }
        let horizontalIntent = abs(pendingPanTranslationX) > 2
            ? pendingPanTranslationX
            : pendingPanVelocityX
        guard abs(horizontalIntent) > 0 else { return }
        panHasStartedTurn = true
        let edge: PageTurnEdge = horizontalIntent < 0 ? .right : .left
        let direction = PageTurnMetrics.pageDirection(
            for: edge,
            readingDirection: model.pageSurfaceProvider?.readingDirection ?? .leftToRight
        )
        startPageTurn(direction: direction, interactive: true)
    }

    private func schedulePageTurnPrewarm() {
        guard isViewLoaded, view.window != nil, isCustomPageTurnEnabled,
              pageTurnStateMachine.state == .idle,
              !adjacentSurfaceCacheIsWarm,
              pageTurnPrewarmTask == nil,
              let provider = model.pageSurfaceProvider,
              snapshotHostView.bounds.width > 0,
              snapshotHostView.bounds.height > 0 else { return }

        pageTurnPrewarmTask?.cancel()
        pageTurnPrewarmRevision &+= 1
        let revision = pageTurnPrewarmRevision
        pageTurnPrewarmTask = Task { @MainActor [weak self, weak provider] in
            await Task.yield()
            guard let self, let provider, !Task.isCancelled else { return }
            await provider.prewarmAdjacentSurfaces()
            guard revision == self.pageTurnPrewarmRevision else { return }
            self.pageTurnPrewarmTask = nil
            guard !Task.isCancelled, self.pageTurnStateMachine.state == .idle else { return }
            self.adjacentSurfaceCacheIsWarm = true
            if self.cachedCurrentComposite == nil,
               let currentContent = self.makeCurrentContentSnapshot() {
                self.cachedCurrentComposite = self.makeCompositeSurface(content: currentContent)
            }
        }
    }

    private func invalidatePageTurnCache() {
        pageTurnPrewarmRevision &+= 1
        pageTurnPrewarmTask?.cancel()
        pageTurnPrewarmTask = nil
        cachedCurrentComposite = nil
        adjacentSurfaceCacheIsWarm = false
        model.pageSurfaceProvider?.invalidatePreparedSurfaces()
    }

    private func performAfterCancellingPageTurn(
        _ action: @escaping (ReaderViewController) -> Void
    ) {
        if pageTurnStateMachine.state == .committing, let committingTask = pageTurnTask {
            committingTask.cancel()
            pageTurnStateMachine.invalidate()
            cleanupPageTurn(cancelPreparedSurface: true)
            Task { @MainActor [weak self] in
                await committingTask.value
                guard let self else { return }
                self.invalidatePageTurnCache()
                action(self)
            }
            return
        }
        cancelPageTurn(animated: false)
        action(self)
    }

    private func makeCurrentContentSnapshot() -> UIView? {
        guard let contentView = contentHostController?.view else { return nil }
        contentView.layoutIfNeeded()
        return contentView.snapshotView(afterScreenUpdates: false)
    }

    private func makeCompositeSurface(content: UIView) -> UIView {
        let composite = UIView(frame: snapshotHostView.bounds)
        composite.backgroundColor = latestReaderBackground
        composite.isOpaque = true
        composite.isUserInteractionEnabled = false
        composite.accessibilityElementsHidden = true
        composite.isAccessibilityElement = false

        content.frame = composite.bounds
        content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        composite.addSubview(content)
        if let header = chromeView.makePageHeaderSnapshot(in: snapshotHostView) {
            composite.addSubview(header)
        }
        return composite
    }

    private var isDarkPageBackground: Bool {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        guard latestReaderBackground.getRed(&red, green: &green, blue: &blue, alpha: nil) else {
            return traitCollection.userInterfaceStyle == .dark
        }
        return red * 0.2126 + green * 0.7152 + blue * 0.0722 < 0.35
    }

    private func makeContentRoot() -> ReaderContentHostView {
        ReaderContentHostView(
            content: model.makeContentView(
                onToggleControls: { [weak self] in self?.handleContentToggle() },
                onSwipeStart: { [weak self] in self?.chromeView.hideControlsForSwipe() },
                onPageTurnRequested: { [weak self] direction in
                    self?.startPageTurn(direction: direction, interactive: false)
                }
            )
        )
    }

    private func makeContentSignature() -> ReaderContentSignature {
        ReaderContentSignature(
            isContentReady: model.isContentReady,
            errorMessage: model.errorMessage
        )
    }

    private func refreshContentIfNeeded() {
        let nextSignature = makeContentSignature()
        guard contentSignature?.matches(nextSignature) != true else { return }

        contentSignature = nextSignature
        contentHostController?.rootView = makeContentRoot()
    }
}

private struct ReaderContentHostView: View {
    let content: AnyView

    var body: some View {
        content
        .ignoresSafeArea(.container, edges: .all)
    }
}

private struct ReaderContentSignature {
    let isContentReady: Bool
    let errorMessage: String?

    func matches(_ other: ReaderContentSignature) -> Bool {
        isContentReady == other.isContentReady
            && errorMessage == other.errorMessage
    }
}
