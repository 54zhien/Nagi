import ReadiumNavigator
import SwiftUI
import UIKit

@MainActor
private final class PageTurnAnimationGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var pendingResult: Bool?

    func install(_ continuation: CheckedContinuation<Bool, Never>) {
        if let pendingResult {
            continuation.resume(returning: pendingResult)
        } else {
            self.continuation = continuation
        }
    }

    func resolve(_ result: Bool) {
        guard pendingResult == nil else { return }
        pendingResult = result
        continuation?.resume(returning: result)
        continuation = nil
    }
}

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
    /// Content pixels captured while idle. Keeping the source image separate
    /// from the animator's temporary views prevents any live WebKit layer
    /// from being reused during a turn.
    private var cachedCurrentSurface: NavigatorCurrentPageSurface?
    private var activeTargetImage: UIImage?
    private var activePageSurface: PageSurface?
    private var pageTurnAnimator: (any PageTurnAnimating)?
    private var externalTakeoverTask: Task<Void, Never>?
    private var isExternalTakeoverActive = false
    private var queuedExternalAction: ((ReaderViewController) -> Void)?
    private var activeTurnGeneration: UInt?
    private var pendingPanTranslationX: CGFloat = 0
    private var pendingPanVelocityX: CGFloat = 0
    private var pendingPanDidEnd = false
    private var panHasStartedTurn = false
    private var isBoundaryResistanceTurn = false
    private var isFallbackNavigationTurn = false
    private var fallbackNavigationRevision: UInt = 0
    private static let pageSurfaceResolutionBudget: UInt64 = 2_000_000_000
    private static let pageSurfaceRecoveryBudget: UInt64 = 1_200_000_000
    private static let pageSurfaceRecoveryAttempts = 3

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
        view.cornerConfiguration = .corners(radius: .containerConcentric())
        view.layer.masksToBounds = true
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
        snapshotHostView.cornerConfiguration = .corners(radius: .containerConcentric())
        snapshotHostView.layer.masksToBounds = true
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
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
        let contentInsets = readableContentInsets(for: chromeSafeAreaInsets)
        let displayScale = view.window?.screen.scale ?? UIScreen.main.scale
        guard bounds != lastViewportBounds
            || contentInsets != lastViewportContentInsets
            || displayScale != lastViewportDisplayScale else {
            return
        }

        let hadViewport = !lastViewportBounds.isNull
        let viewportChanged = hadViewport && (
            lastViewportBounds != bounds
                || lastViewportContentInsets != contentInsets
                || abs(lastViewportDisplayScale - displayScale) > 0.001
        )
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
        externalTakeoverTask?.cancel()
        externalTakeoverTask = nil
        queuedExternalAction = nil
        cancelPageTurn(animated: false)
        pageTurnPrewarmTask?.cancel()
        pageTurnPrewarmTask = nil
        cachedCurrentSurface = nil
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

    @objc private func applicationDidBecomeActive() {
        guard isViewLoaded else { return }
        cancelPageTurn(animated: false)
        invalidatePageTurnCache()
        schedulePageTurnPrewarm()
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
            && !isExternalTakeoverActive
            && model.pageSurfaceProvider?.isPageSurfaceProviderReady == true
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

    @discardableResult
    private func startPageTurn(direction: PageDirection, interactive: Bool) -> Bool {
        guard !isExternalTakeoverActive else { return false }
        guard let provider = model.pageSurfaceProvider else { return false }
        guard model.preferences.pageTransition != .scroll else {
            handleContentToggle()
            return false
        }
        guard let generation = pageTurnStateMachine.prepare(direction: direction) else { return false }
        fallbackNavigationRevision &+= 1

        if latestReduceMotion || UIAccessibility.isVoiceOverRunning {
            pageTurnStateMachine.invalidate()
            navigateWithoutCustomTransition(direction: direction, provider: provider)
            return true
        }

        guard let currentSurface = cachedCurrentSurface else {
            if !interactive {
                pageTurnStateMachine.invalidate()
                navigateWithoutCustomTransition(direction: direction, provider: provider)
                return true
            }
            return startFallbackGesture(
                direction: direction,
                generation: generation,
                currentView: UIView()
            )
        }

        // Taking a surface is deliberately synchronous. Only a confirmed edge
        // gets resistance. Preparing/failed surfaces remain visually still,
        // preserve the release threshold, and then use settled non-animated
        // navigation instead of pretending the publication has ended. No
        // WebKit work starts on the drag path.
        guard let surface = provider.takePreparedAdjacentSurface(direction: direction) else {
            let readiness = provider.adjacentSurfaceReadiness(direction: direction)
            if !interactive, readiness != .unavailable {
                pageTurnStateMachine.invalidate()
                navigateWithoutCustomTransition(direction: direction, provider: provider)
                return true
            }
            let currentView = makeCompositeSurface(
                contentImage: currentSurface.image,
                geometry: currentSurface.geometry
            )
            let fallbackAnimator: any PageTurnAnimating
            if readiness == .unavailable {
                let destinationX = PageTurnMetrics.completionTranslationX(
                    containerWidth: snapshotHostView.bounds.width,
                    direction: direction,
                    readingDirection: provider.readingDirection
                )
                fallbackAnimator = PageTurnBoundaryAnimator(
                    hostView: snapshotHostView,
                    currentView: currentView,
                    completionTranslationX: destinationX
                )
            } else {
                fallbackAnimator = PageTurnNoAnimationAnimator(
                    hostView: snapshotHostView,
                    currentView: currentView
                )
            }
            isBoundaryResistanceTurn = readiness == .unavailable
            isFallbackNavigationTurn = readiness != .unavailable
            activeTurnGeneration = generation
            pendingPanDidEnd = !interactive
            if !interactive {
                pendingPanTranslationX = 0
                pendingPanVelocityX = 0
            }
            pageTurnAnimator = fallbackAnimator
            chromeView.setPageHeaderHiddenForTransition(true)
            guard fallbackAnimator.install() else {
                pageTurnStateMachine.invalidate()
                cleanupPageTurn(cancelPreparedSurface: false)
                schedulePageTurnPrewarm()
                return false
            }
            guard pageTurnStateMachine.beginInteractive(generation: generation) else {
                pageTurnStateMachine.invalidate()
                cleanupPageTurn(cancelPreparedSurface: false)
                return false
            }
            schedulePageTurnPrewarm()
            updateInteractivePageTurn()
            finishInteractivePageTurnIfReady()
            return true
        }

        guard pageSurfaceGeometryIsCompatible(
            current: currentSurface,
            target: surface,
            viewportSize: snapshotHostView.bounds.size
        ) else {
            provider.cancel(surface: surface)
            provider.invalidatePreparedSurfaces()
            cachedCurrentSurface = nil
            if interactive {
                return startFallbackGesture(
                    direction: direction,
                    generation: generation,
                    currentView: UIView()
                )
            } else {
                pageTurnStateMachine.invalidate()
                navigateWithoutCustomTransition(direction: direction, provider: provider)
                return true
            }
        }

        activeTurnGeneration = generation
        pendingPanDidEnd = !interactive
        if !interactive {
            pendingPanTranslationX = 0
            pendingPanVelocityX = 0
        }

        let currentComposite = makeCompositeSurface(
            contentImage: currentSurface.image,
            geometry: currentSurface.geometry
        )
        let targetComposite = makeCompositeSurface(contentImage: surface.image, geometry: surface.geometry)
        activeTargetImage = surface.image
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
                    style: .fade,
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
        guard animator.install() else {
            pageTurnStateMachine.invalidate()
            cleanupPageTurn(cancelPreparedSurface: true)
            schedulePageTurnPrewarm()
            return false
        }
        guard pageTurnStateMachine.beginInteractive(generation: generation) else {
            pageTurnStateMachine.invalidate()
            cleanupPageTurn(cancelPreparedSurface: true)
            return false
        }

        if interactive {
            updateInteractivePageTurn()
            finishInteractivePageTurnIfReady()
        } else {
            _ = pageTurnStateMachine.finish(with: .complete, generation: generation)
            animatePageTurnCompletion(generation: generation)
        }
        return true
    }

    private func startFallbackGesture(
        direction: PageDirection,
        generation: UInt,
        currentView: UIView
    ) -> Bool {
        let animator = PageTurnNoAnimationAnimator(hostView: snapshotHostView, currentView: currentView)
        isFallbackNavigationTurn = true
        activeTurnGeneration = generation
        pageTurnAnimator = animator
        chromeView.setPageHeaderHiddenForTransition(true)
        guard animator.install(), pageTurnStateMachine.beginInteractive(generation: generation) else {
            pageTurnStateMachine.invalidate()
            cleanupPageTurn(cancelPreparedSurface: false)
            schedulePageTurnPrewarm()
            return false
        }
        schedulePageTurnPrewarm()
        updateInteractivePageTurn()
        finishInteractivePageTurnIfReady()
        return true
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
            if isFallbackNavigationTurn,
               let provider = model.pageSurfaceProvider {
                pageTurnStateMachine.invalidate()
                cleanupPageTurn(cancelPreparedSurface: false)
                navigateWithoutCustomTransition(direction: direction, provider: provider)
            } else {
                animatePageTurnCompletion(generation: generation)
            }
        case .cancel:
            pageTurnAnimator?.animateCancellation { [weak self] in
                guard let self else { return }
                _ = self.pageTurnStateMachine.finishCancellation(generation: generation)
                self.cleanupPageTurn(cancelPreparedSurface: true)
                self.schedulePageTurnPrewarm()
            }
        }
    }

    private func animatePageTurnCompletion(generation: UInt) {
        guard pageTurnStateMachine.beginCommitting(generation: generation),
              let provider = model.pageSurfaceProvider,
              let surface = activePageSurface else {
            cancelPageTurn(animated: false)
            return
        }

        // Navigation and visual settling are one transaction. Starting both
        // now lets WebKit move and paint behind the immutable overlay instead
        // of waiting until the user has already seen the animation finish.
        pageTurnTask = Task { @MainActor [weak self] in
            guard let self else { return }
            async let animationFinished = self.finishPageTurnAnimation()
            async let commitResult = provider.commit(surface: surface)
            let (finished, initialResult) = await (animationFinished, commitResult)
            guard !Task.isCancelled else { return }
            guard self.pageTurnStateMachine.accepts(generation) else {
                self.finishQueuedExternalTakeover()
                return
            }

            let result: PageSurfaceCommitResult
            if initialResult == .indeterminate {
                result = await self.waitForPageSurfaceReconciliation(
                    surface: surface,
                    generation: generation,
                    provider: provider
                )
            } else {
                result = initialResult
            }

            guard !Task.isCancelled else { return }
            guard self.pageTurnStateMachine.accepts(generation) else {
                self.finishQueuedExternalTakeover()
                return
            }
            guard finished else {
                self.pageTurnStateMachine.invalidate()
                self.cleanupPageTurn(cancelPreparedSurface: result != .committed)
                self.invalidatePageTurnCache()
                self.schedulePageTurnPrewarm()
                return
            }

            switch result {
            case .committed:
                self.activePageSurface = nil
                _ = self.pageTurnStateMachine.finish(generation: generation)
                self.cleanupPageTurn(cancelPreparedSurface: false)
                self.cachedCurrentSurface = nil
                self.schedulePageTurnPrewarm()
            case .restored:
                self.activePageSurface = nil
                _ = self.pageTurnStateMachine.finish(generation: generation)
                self.cleanupPageTurn(cancelPreparedSurface: false)
                self.invalidatePageTurnCache()
                self.schedulePageTurnPrewarm()
            case .indeterminate:
                _ = await self.recoverIndeterminatePageSurface(
                    surface: surface,
                    generation: generation,
                    provider: provider
                )
                guard !Task.isCancelled,
                      self.pageTurnStateMachine.accepts(generation) else { return }
                provider.invalidatePreparedSurfaces()
                self.activePageSurface = nil
                _ = self.pageTurnStateMachine.finish(generation: generation)
                self.cleanupPageTurn(cancelPreparedSurface: false)
                self.cachedCurrentSurface = nil
                self.schedulePageTurnPrewarm()
            }
        }
    }

    private func finishPageTurnAnimation() async -> Bool {
        guard let pageTurnAnimator else { return false }
        let gate = PageTurnAnimationGate()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                pageTurnAnimator.animateCompletion { finished in
                    gate.resolve(finished)
                }
            }
        }, onCancel: {
            Task { @MainActor in gate.resolve(false) }
        })
    }

    private func waitForPageSurfaceReconciliation(
        surface: PageSurface,
        generation: UInt,
        provider: any PageSurfaceProvider
    ) async -> PageSurfaceCommitResult {
        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ Self.pageSurfaceResolutionBudget
        return await performPageSurfaceReconciliation(
            surface: surface,
            generation: generation,
            provider: provider,
            deadline: deadline
        )
    }

    private func performPageSurfaceReconciliation(
        surface: PageSurface,
        generation: UInt,
        provider: any PageSurfaceProvider,
        deadline: UInt64
    ) async -> PageSurfaceCommitResult {
        func stillValid() -> Bool {
            !Task.isCancelled
                && DispatchTime.now().uptimeNanoseconds < deadline
                && pageTurnStateMachine.accepts(generation)
                && pageTurnStateMachine.state == .committing
        }

        guard stillValid() else {
            return .indeterminate
        }
        let result = await provider.reconcile(surface: surface, deadline: deadline)
        if result != .indeterminate {
            return result
        }
        // An unresolved locator is deliberately left covered. The active
        // immutable overlay remains the only safe visual fact until an
        // external owner starts a new generation.
        return .indeterminate
    }

    /// Resolves an indeterminate commit without guessing whether the target
    /// or origin won. The live navigator remains covered while its current
    /// location and pixels settle. A generation check surrounds every await so
    /// an external takeover or teardown can interrupt this bounded recovery.
    private func recoverIndeterminatePageSurface(
        surface: PageSurface,
        generation: UInt,
        provider: any PageSurfaceProvider
    ) async -> UIImage? {
        provider.discardReconciliation(for: surface)
        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ Self.pageSurfaceRecoveryBudget

        for attempt in 0 ..< Self.pageSurfaceRecoveryAttempts {
            guard !Task.isCancelled,
                  pageTurnStateMachine.accepts(generation),
                  pageTurnStateMachine.state == .committing,
                  DispatchTime.now().uptimeNanoseconds < deadline else {
                return nil
            }

            await model.waitForVisualUpdate(for: .full)
            guard !Task.isCancelled,
                  pageTurnStateMachine.accepts(generation),
                  pageTurnStateMachine.state == .committing else {
                return nil
            }
            await Task.yield()

            if let image = makeCurrentContentSnapshot(),
               model.engine.renderer.readingPosition() != nil {
                return image
            }

            if attempt == 1 {
                // Rebuild only the SwiftUI content host. The Readium
                // navigator remains the source of truth and is not moved or
                // navigated again during recovery.
                rebuildReaderContentForRecovery()
            }

            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        return nil
    }

    private func rebuildReaderContentForRecovery() {
        guard let contentHostController else { return }
        contentSignature = makeContentSignature()
        contentHostController.rootView = makeContentRoot()
    }

    private func cancelPageTurn(animated: Bool) {
        if pageTurnStateMachine.state == .committing {
            abortCommittingPageTurn()
            return
        }
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
            model.pageSurfaceProvider?.discardReconciliation(for: surface)
        }
        activePageSurface = nil
        activeTargetImage = nil
        pageTurnAnimator?.remove()
        pageTurnAnimator = nil
        chromeView.setPageHeaderHiddenForTransition(false)
        activeTurnGeneration = nil
        pendingPanTranslationX = 0
        pendingPanVelocityX = 0
        pendingPanDidEnd = false
        panHasStartedTurn = false
        isBoundaryResistanceTurn = false
        isFallbackNavigationTurn = false
    }

    private func startPageTurnFromPanIfNeeded() {
        guard !panHasStartedTurn else { return }
        let horizontalIntent = abs(pendingPanTranslationX) > 2
            ? pendingPanTranslationX
            : pendingPanVelocityX
        guard abs(horizontalIntent) > 0 else { return }
        let edge: PageTurnEdge = horizontalIntent < 0 ? .right : .left
        let direction = PageTurnMetrics.pageDirection(
            for: edge,
            readingDirection: model.pageSurfaceProvider?.readingDirection ?? .leftToRight
        )
        panHasStartedTurn = startPageTurn(direction: direction, interactive: true)
    }

    private func schedulePageTurnPrewarm() {
        guard isViewLoaded, view.window != nil, isCustomPageTurnEnabled,
              pageTurnStateMachine.state == .idle,
              pageTurnPrewarmTask == nil,
              let provider = model.pageSurfaceProvider,
              snapshotHostView.bounds.width > 0,
              snapshotHostView.bounds.height > 0,
              cachedCurrentSurface == nil
                || provider.adjacentSurfaceReadiness(direction: .forward) != .ready
                || provider.adjacentSurfaceReadiness(direction: .backward) != .ready
        else { return }

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
            if let currentSurface = provider.preparedCurrentSurface() {
                self.cachedCurrentSurface = currentSurface
            }
        }
    }

    private func invalidatePageTurnCache() {
        // A committing fork transaction owns the navigator until it reports
        // committed/restored or reconciliation proves a safe outcome.
        guard pageTurnStateMachine.state != .committing else { return }
        pageTurnPrewarmRevision &+= 1
        pageTurnPrewarmTask?.cancel()
        pageTurnPrewarmTask = nil
        cachedCurrentSurface = nil
        model.pageSurfaceProvider?.invalidatePreparedSurfaces()
    }

    private func performAfterCancellingPageTurn(
        _ action: @escaping (ReaderViewController) -> Void
    ) {
        if isExternalTakeoverActive {
            queuedExternalAction = action
            return
        }
        if pageTurnStateMachine.state == .committing {
            abortCommittingPageTurn()
            queuedExternalAction = action
            return
        }
        cancelPageTurn(animated: false)
        action(self)
    }

    /// External ownership changes invalidate the old generation immediately.
    /// Keep the last real immutable cover over the live navigator until the
    /// new owner reports a stable visual update.
    private func abortCommittingPageTurn() {
        if let surface = activePageSurface {
            model.pageSurfaceProvider?.cancel(surface: surface)
        }
        pageTurnStateMachine.invalidate()
        externalTakeoverTask?.cancel()
        externalTakeoverTask = nil
        // A commit owns the navigator until its provider reports committed or
        // restored. Keep the last immutable page mounted while cancellation,
        // layout changes, settings changes, and external actions settle; the
        // async commit task will start the takeover resolution once its state
        // is no longer accepted by this generation.
        isExternalTakeoverActive = true
        model.pageSurfaceProvider?.invalidatePreparedSurfaces()
    }

    private func finishQueuedExternalTakeover() {
        guard isExternalTakeoverActive else { return }
        let action = queuedExternalAction
        queuedExternalAction = nil
        action?(self)
        resolveExternalTakeover()
    }

    private func resolveExternalTakeover() {
        externalTakeoverTask?.cancel()
        externalTakeoverTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.model.waitForVisualUpdate(for: .full)
            guard !Task.isCancelled, self.isExternalTakeoverActive else { return }
            await Task.yield()
            guard !Task.isCancelled, self.isExternalTakeoverActive else { return }
            _ = self.makeCurrentContentSnapshot()
            self.isExternalTakeoverActive = false
            self.cleanupPageTurn(cancelPreparedSurface: false)
            self.cachedCurrentSurface = nil
            self.externalTakeoverTask = nil
            self.configurePageTurnInteraction()
            self.schedulePageTurnPrewarm()
        }
    }

    private func makeCurrentContentSnapshot() -> UIImage? {
        guard let contentView = contentHostController?.view else { return nil }
        contentView.layoutIfNeeded()
        let bounds = contentView.bounds.integral
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = view.window?.windowScene?.screen.scale ?? UIScreen.main.scale
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            latestReaderBackground.setFill()
            UIRectFill(bounds)
            contentView.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
    }

    private func makeCompositeSurface(
        contentImage: UIImage,
        geometry: NavigatorPageSurfaceGeometry
    ) -> UIView {
        let composite = UIView(frame: snapshotHostView.bounds)
        composite.backgroundColor = latestReaderBackground
        composite.isOpaque = true
        composite.isUserInteractionEnabled = false
        composite.accessibilityElementsHidden = true
        composite.isAccessibilityElement = false

        let content = UIImageView(image: contentImage)
        content.contentMode = .center
        content.frame = geometry.contentRect
        content.isUserInteractionEnabled = false
        composite.addSubview(content)
        if let header = chromeView.makePageHeaderSnapshot(in: snapshotHostView) {
            composite.addSubview(header)
        }
        return composite
    }

    private func pageSurfaceGeometryIsCompatible(
        current currentSurface: NavigatorCurrentPageSurface,
        target targetSurface: PageSurface,
        viewportSize: CGSize
    ) -> Bool {
        guard currentSurface.generation == targetSurface.generation,
              currentSurface.identity == targetSurface.originIdentity else { return false }
        let current = currentSurface.geometry
        let target = targetSurface.geometry
        let tolerance = 0.5
        func equal(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool { abs(lhs - rhs) <= tolerance }
        return equal(current.pointSize.width, target.pointSize.width)
            && equal(current.pointSize.height, target.pointSize.height)
            && equal(current.pixelSize.width, target.pixelSize.width)
            && equal(current.pixelSize.height, target.pixelSize.height)
            && equal(current.scale, target.scale)
            && equal(current.contentRect.width, target.contentRect.width)
            && equal(current.contentRect.height, target.contentRect.height)
            && equal(current.contentRect.minX, target.contentRect.minX)
            && equal(current.contentRect.minY, target.contentRect.minY)
            && equal(current.pointSize.width, current.contentRect.width)
            && equal(current.pointSize.height, current.contentRect.height)
            && current.contentRect.minX >= -tolerance
            && current.contentRect.minY >= -tolerance
            && current.contentRect.maxX <= viewportSize.width + tolerance
            && current.contentRect.maxY <= viewportSize.height + tolerance
    }

    private func navigateWithoutCustomTransition(
        direction: PageDirection,
        provider: any PageSurfaceProvider
    ) {
        pageTurnTask?.cancel()
        fallbackNavigationRevision &+= 1
        let revision = fallbackNavigationRevision
        pageTurnTask = Task { @MainActor [weak self] in
            _ = await provider.navigateWithoutCustomTransition(direction: direction)
            guard let self, !Task.isCancelled,
                  revision == self.fallbackNavigationRevision else { return }
            self.invalidatePageTurnCache()
            self.schedulePageTurnPrewarm()
        }
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
