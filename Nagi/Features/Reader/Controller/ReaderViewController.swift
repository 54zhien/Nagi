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
    private var pendingProgrammaticPageTurnTask: Task<Void, Never>?
    private var pageTurnPrewarmRevision: UInt = 0
    private var pendingProgrammaticPageTurnRevision: UInt = 0
    private var preferredPrewarmDirection: PageDirection = .forward
    private var cachedCurrentSurface: NavigatorCurrentPageSurface?
    /// Page textures rasterised and uploaded while the reader was idle, so a
    /// curl gesture only ever looks one up.
    private let curlTextureCache = CurlTextureCache()
    /// Whether the last warm-up produced all three pages. Kept separately from
    /// the surfaces' own readiness because an upload can fail while the
    /// surfaces look perfectly ready, and the prewarm trigger has to know.
    private var curlTexturesAreWarm = false
    private var activePageSurface: PageSurface?
    private var activeCurrentComposite: UIView?
    private var activeTargetComposite: UIView?
    private var pageTurnAnimator: (any PageTurnAnimating)?
    private var externalTakeoverTask: Task<Void, Never>?
    private var isExternalTakeoverActive = false
    private var isDismantling = false
    private var queuedExternalAction: ((ReaderViewController) -> Void)?
    private var activeTurnGeneration: UInt?
    private var pendingPanTranslationX: CGFloat = 0
    private var pendingPanTranslationY: CGFloat = 0
    private var pendingPanVelocityX: CGFloat = 0
    private var pendingPanVelocityY: CGFloat = 0
    private var pendingPanDidEnd = false
    private var isTrackingPageTurnPan = false
    private var panHasStartedTurn = false
    private var isBoundaryResistanceTurn = false
    private var isSurfaceRaceResistanceTurn = false
    private var nativeNavigationRevision: UInt = 0
    private var visualCompletionRecoveryAttempts = 0
    private static let pageSurfaceResolutionBudget: UInt64 = 2_000_000_000
    private static let pageSurfaceRecoveryBudget: UInt64 = 1_200_000_000
    private static let pageSurfaceRecoveryAttempts = 3
    private static let pageSurfacePrewarmRetryDelay: UInt64 = 180_000_000
    private static let pageSurfacePrewarmMaxAttempts = 3
    private static let pendingProgrammaticPageTurnBudget: UInt64 = 2_000_000_000
    private static let pageTurnAnimationTimeout: UInt64 = 1_000_000_000

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
        contentController.view.frame = view.bounds
        contentController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
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
        pan.cancelsTouchesInView = true
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
            refreshPreparedPageTurnCacheIfAvailable()
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
        isDismantling = true
        NotificationCenter.default.removeObserver(self)
        externalTakeoverTask?.cancel()
        externalTakeoverTask = nil
        isExternalTakeoverActive = false
        queuedExternalAction = nil
        pageTurnTask?.cancel()
        pageTurnTask = nil
        pageTurnPrewarmTask?.cancel()
        pageTurnPrewarmTask = nil
        pendingProgrammaticPageTurnTask?.cancel()
        pendingProgrammaticPageTurnTask = nil
        pendingProgrammaticPageTurnRevision &+= 1
        pageTurnPrewarmRevision &+= 1
        if let surface = activePageSurface {
            model.pageSurfaceProvider?.cancel(surface: surface)
            model.pageSurfaceProvider?.discardReconciliation(for: surface)
        }
        activePageSurface = nil
        activeCurrentComposite = nil
        activeTargetComposite = nil
        visualCompletionRecoveryAttempts = 0
        pageTurnStateMachine.invalidate()
        pageTurnAnimator?.remove()
        pageTurnAnimator = nil
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
        }
        contentHostController = nil
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: gesture.view)
        let velocity = gesture.velocity(in: gesture.view)

        switch gesture.state {
        case .began:
            guard customPageTurnPreferenceIsActive,
                  pageTurnStateMachine.state == .idle else { return }
            cancelPendingProgrammaticPageTurn()
            isTrackingPageTurnPan = true
            pendingPanTranslationX = translation.x
            pendingPanTranslationY = translation.y
            pendingPanVelocityX = velocity.x
            pendingPanVelocityY = velocity.y
            pendingPanDidEnd = false
            panHasStartedTurn = false

        case .changed:
            guard isTrackingPageTurnPan else { return }
            pendingPanTranslationX = translation.x
            pendingPanTranslationY = translation.y
            pendingPanVelocityX = velocity.x
            pendingPanVelocityY = velocity.y
            startPageTurnFromPanIfNeeded()
            updateInteractivePageTurn()

        case .ended:
            guard isTrackingPageTurnPan else { return }
            isTrackingPageTurnPan = false
            pendingPanTranslationX = translation.x
            pendingPanTranslationY = translation.y
            pendingPanVelocityX = velocity.x
            pendingPanVelocityY = velocity.y
            pendingPanDidEnd = true
            startPageTurnFromPanIfNeeded()
            finishInteractivePageTurnIfReady()

        case .cancelled, .failed:
            guard isTrackingPageTurnPan else { return }
            isTrackingPageTurnPan = false
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

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panGestureRecognizer, let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return true
        }
        guard customPageTurnPreferenceIsActive,
              pageTurnStateMachine.state == .idle else { return false }
        let translation = pan.translation(in: pan.view)
        let velocity = pan.velocity(in: pan.view)
        return PageTurnMetrics.isHorizontalIntent(translation: translation, velocity: velocity)
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

    private var customPageTurnPreferenceIsActive: Bool {
        model.preferences.pageTransition != .scroll
            && !latestReduceMotion
            && !UIAccessibility.isVoiceOverRunning
            && !isExternalTakeoverActive
    }

    private var shouldOwnPaginatedPageTurns: Bool {
        customPageTurnPreferenceIsActive
            && model.pageSurfaceProvider?.isPageSurfaceProviderReady == true
            && model.pageSurfaceProvider?.usesContinuousScroll == false
            && model.pageSurfaceProvider?.supportsCustomPageTurns == true
    }

    private var pageTurnCacheIsFullyPublished: Bool {
        guard let currentSurface = cachedCurrentSurface,
              pageSurfaceGeometryIsCompatibleWithViewport(
                  currentSurface.geometry,
                  viewportSize: snapshotHostView.bounds.size
              ),
              imageMatchesGeometry(currentSurface.image, currentSurface.geometry),
              let provider = model.pageSurfaceProvider else { return false }

        return [PageDirection.forward, .backward].allSatisfy { direction in
            switch provider.adjacentSurfaceReadiness(direction: direction) {
            case .ready:
                guard let target = provider.preparedAdjacentSurface(direction: direction) else {
                    return false
                }
                return pageSurfaceGeometryIsCompatible(
                    current: currentSurface,
                    target: target,
                    viewportSize: snapshotHostView.bounds.size
                )
            case .unavailable:
                return true
            case .unknown, .preparing, .failed:
                return false
            }
        }
    }

    private func configurePageTurnInteraction() {
        guard !isDismantling else {
            setPanGestureEnabled(false)
            model.pageSurfaceProvider?.setBuiltInPageTurnInteractionEnabled(true)
            return
        }
        if isExternalTakeoverActive {
            setPanGestureEnabled(false)
            model.pageSurfaceProvider?.setBuiltInPageTurnInteractionEnabled(false)
            return
        }
        if pageTurnStateMachine.state != .idle || pendingProgrammaticPageTurnTask != nil {
            // Readiness callbacks must not cancel an in-flight pan. New pans
            // are admitted by gestureRecognizerShouldBegin, not by toggling
            // the recognizer while UIKit is dispatching its current gesture.
            setPanGestureEnabled(customPageTurnPreferenceIsActive)
            model.pageSurfaceProvider?.setBuiltInPageTurnInteractionEnabled(false)
            return
        }

        let customPreferenceIsActive = customPageTurnPreferenceIsActive
        let ownsPageTurns = shouldOwnPaginatedPageTurns
        if ownsPageTurns, model.preferences.pageTransition == .pageCurl {
            PageTurnCurlAnimator.preparePipelineIfNeeded()
        }
        // A selected custom transition owns the entire hand-off window. The
        // native pager stays disabled while surfaces are warming or a new
        // Readium presentation is settling, so the same swipe cannot become a
        // different animation.
        model.pageSurfaceProvider?.setBuiltInPageTurnInteractionEnabled(!customPreferenceIsActive)
        setPanGestureEnabled(customPreferenceIsActive)
        chromeView.setPageHeaderHiddenForTransition(false)
        if ownsPageTurns {
            schedulePageTurnPrewarm()
        }
    }

    private func setPanGestureEnabled(_ enabled: Bool) {
        guard let panGestureRecognizer,
              panGestureRecognizer.isEnabled != enabled else { return }
        panGestureRecognizer.isEnabled = enabled
    }

    @discardableResult
    private func startPageTurn(
        direction: PageDirection,
        interactive: Bool,
        allowsDeferredProgrammaticRetry: Bool = true
    ) -> Bool {
        guard !isExternalTakeoverActive,
              pageTurnStateMachine.state == .idle else { return false }
        guard let provider = model.pageSurfaceProvider else { return false }
        if pendingProgrammaticPageTurnTask != nil {
            cancelPendingProgrammaticPageTurn()
        }
        if provider.usesContinuousScroll {
            if customPageTurnPreferenceIsActive {
                if interactive, pendingPanDidEnd {
                    return queueProgrammaticPageTurnIfGestureCompleted(
                        direction: direction,
                        provider: provider
                    )
                }
                if !interactive {
                    queueProgrammaticPageTurn(direction: direction, provider: provider)
                    return true
                }
                return false
            }
            handleContentToggle()
            return false
        }
        guard provider.supportsCustomPageTurns else {
            if customPageTurnPreferenceIsActive {
                if interactive, pendingPanDidEnd {
                    return queueProgrammaticPageTurnIfGestureCompleted(
                        direction: direction,
                        provider: provider
                    )
                }
                if !interactive {
                    queueProgrammaticPageTurn(direction: direction, provider: provider)
                    return true
                }
                return false
            }
            guard !interactive else { return false }
            navigateWithoutCustomTransition(direction: direction, provider: provider)
            return true
        }
        guard model.preferences.pageTransition != .scroll else {
            // Fixed-layout EPUBs cannot join the publication-wide vertical
            // scroll. Keep their paginated fallback operable for edge taps.
            navigateWithoutCustomTransition(direction: direction, provider: provider)
            return true
        }
        guard let generation = pageTurnStateMachine.prepare(direction: direction) else { return false }
        nativeNavigationRevision &+= 1

        if latestReduceMotion || UIAccessibility.isVoiceOverRunning {
            pageTurnStateMachine.invalidate()
            navigateWithoutCustomTransition(direction: direction, provider: provider)
            return true
        }

        guard let currentSurface = cachedCurrentSurface else {
            pageTurnStateMachine.invalidate()
            preferredPrewarmDirection = direction
            if !interactive {
                if allowsDeferredProgrammaticRetry {
                    queueProgrammaticPageTurn(direction: direction, provider: provider)
                } else {
                    schedulePageTurnPrewarm()
                }
                return true
            }
            schedulePageTurnPrewarm()
            if pendingPanDidEnd {
                return queueProgrammaticPageTurnIfGestureCompleted(
                    direction: direction,
                    provider: provider
                )
            }
            return false
        }

        guard let surface = provider.takePreparedAdjacentSurface(direction: direction) else {
            let readiness = provider.adjacentSurfaceReadiness(direction: direction)
            if readiness != .unavailable {
                preferredPrewarmDirection = direction
                if !interactive {
                    pageTurnStateMachine.invalidate()
                    if allowsDeferredProgrammaticRetry {
                        queueProgrammaticPageTurn(direction: direction, provider: provider)
                    } else {
                        schedulePageTurnPrewarm()
                    }
                    return true
                }
                schedulePageTurnPrewarm()
                return startPageTurnResistance(
                    currentSurface: currentSurface,
                    direction: direction,
                    generation: generation,
                    provider: provider,
                    isConfirmedBoundary: false,
                    interactive: true
                )
            }
            return startPageTurnResistance(
                currentSurface: currentSurface,
                direction: direction,
                generation: generation,
                provider: provider,
                isConfirmedBoundary: true,
                interactive: interactive
            )
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
                preferredPrewarmDirection = direction
                return startPageTurnResistance(
                    currentSurface: currentSurface,
                    direction: direction,
                    generation: generation,
                    provider: provider,
                    isConfirmedBoundary: false,
                    interactive: true
                )
            } else {
                pageTurnStateMachine.invalidate()
                if allowsDeferredProgrammaticRetry {
                    queueProgrammaticPageTurn(direction: direction, provider: provider)
                } else {
                    schedulePageTurnPrewarm()
                }
                return true
            }
        }

        // The curl needs both textures already on the GPU, and rasterising them
        // here is the cost the off-gesture pipeline exists to remove.
        //
        // This gate applies only while the Metal pipeline is actually usable.
        // When it is not — no device, or PageCurlShaders.metal missing from the
        // app target — no gesture could ever satisfy it, so holding the turn
        // would leave the reader unable to turn a page at all. Fall through in
        // that case and let the transition degrade to cover.
        //
        // A miss here is not repaired inside the gesture: prewarming only runs
        // while the state machine is idle, so recovery happens on the release
        // path or on the next gesture.
        if model.preferences.pageTransition == .pageCurl,
           PageCurlMetalResources.shared != nil,
           curlTextureCache.curlTextures(
               currentSurface: currentSurface,
               targetSurface: surface,
               direction: direction
           ) == nil {
            provider.cancel(surface: surface)
            preferredPrewarmDirection = direction
            if interactive {
                return startPageTurnResistance(
                    currentSurface: currentSurface,
                    direction: direction,
                    generation: generation,
                    provider: provider,
                    isConfirmedBoundary: false,
                    interactive: true
                )
            }
            pageTurnStateMachine.invalidate()
            if allowsDeferredProgrammaticRetry {
                queueProgrammaticPageTurn(direction: direction, provider: provider)
            } else {
                schedulePageTurnPrewarm()
            }
            return true
        }

        activeTurnGeneration = generation
        pendingPanDidEnd = !interactive
        if !interactive {
            pendingPanTranslationX = 0
            pendingPanVelocityX = 0
        }

        let currentComposite = makeCompositeSurface(
            contentImage: currentSurface.image,
            geometry: currentSurface.geometry,
            headerTitle: latestTitle
        )
        let targetComposite = makeCompositeSurface(
            contentImage: surface.image,
            geometry: surface.geometry,
            headerTitle: surface.headerTitle
        )
        let readingDirection = provider.readingDirection
        let destinationX = PageTurnMetrics.completionTranslationX(
            containerWidth: snapshotHostView.bounds.width,
            direction: direction,
            readingDirection: readingDirection
        )

        activePageSurface = surface
        activeCurrentComposite = currentComposite
        activeTargetComposite = targetComposite
        visualCompletionRecoveryAttempts = 0
        var animator: any PageTurnAnimating
        switch model.preferences.pageTransition {
        case .pageCurl:
            animator = makeCurlAnimator(
                currentSurface: currentSurface,
                targetSurface: surface,
                direction: direction,
                destinationX: destinationX
            ) ?? makeCoverAnimator(
                currentView: currentComposite,
                targetView: targetComposite,
                destinationX: destinationX
            )
        case .fade:
            animator = PageTurnVisualAnimator(
                style: .fade,
                hostView: snapshotHostView,
                currentView: currentComposite,
                targetView: targetComposite,
                completionTranslationX: destinationX,
                isDark: isDarkPageBackground
            )
        case .slide, .scroll:
            animator = PageTurnVisualAnimator(
                style: .cover,
                hostView: snapshotHostView,
                currentView: currentComposite,
                targetView: targetComposite,
                completionTranslationX: destinationX,
                isDark: isDarkPageBackground
            )
        }

        pageTurnAnimator = animator
        chromeView.hideControlsForSwipe()
        chromeView.setPageHeaderHiddenForTransition(true)
        var animatorInstalled = animator.install()
        if !animatorInstalled, model.preferences.pageTransition == .pageCurl {
            animator.remove()
            animator = makeCoverAnimator(
                currentView: currentComposite,
                targetView: targetComposite,
                destinationX: destinationX
            )
            pageTurnAnimator = animator
            animatorInstalled = animator.install()
        }
        guard animatorInstalled else {
            return recoverFromPageTurnStartFailure(
                direction: direction,
                interactive: interactive,
                provider: provider
            )
        }
        guard pageTurnStateMachine.beginInteractive(generation: generation) else {
            return recoverFromPageTurnStartFailure(
                direction: direction,
                interactive: interactive,
                provider: provider
            )
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

        let gestureDecision = PageTurnMetrics.decision(
            progress: pageTurnStateMachine.progress,
            velocityX: pendingPanVelocityX,
            direction: direction,
            readingDirection: model.pageSurfaceProvider?.readingDirection ?? .leftToRight
        )
        if isSurfaceRaceResistanceTurn {
            guard pageTurnStateMachine.finish(with: .cancel, generation: generation) else { return }
            animatePageTurnCancellation(
                generation: generation,
                queuedDirection: gestureDecision == .complete ? direction : nil
            )
            return
        }

        let decision: PageTurnDecision = isBoundaryResistanceTurn ? .cancel : gestureDecision
        guard pageTurnStateMachine.finish(with: decision, generation: generation) else { return }

        switch decision {
        case .complete:
            animatePageTurnCompletion(generation: generation)
        case .cancel:
            animatePageTurnCancellation(generation: generation)
        }
    }

    private func animatePageTurnCompletion(generation: UInt) {
        guard let provider = model.pageSurfaceProvider,
              let surface = activePageSurface else {
            cancelPageTurn(animated: false)
            return
        }

        pageTurnTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Takeover can arrive during the final paint/restoration awaits,
            // after commit has already returned. Every exit must release it.
            defer { self.finishQueuedExternalTakeover() }
            // The target snapshot is the visual source of truth until the
            // animation has ended. Commit Readium only after that point so a
            // late WebView restore/repaint cannot flash the previous page.
            var finished = await self.finishPageTurnAnimation()
            guard !Task.isCancelled else { return }
            guard self.pageTurnStateMachine.accepts(generation) else {
                return
            }
            if !finished {
                guard self.installVisualCompletionFallback(
                    direction: surface.direction
                ) else {
                    self.pageTurnStateMachine.invalidate()
                    self.preferredPrewarmDirection = surface.direction
                    self.cleanupPageTurn(cancelPreparedSurface: true)
                    self.schedulePageTurnPrewarm()
                    return
                }
                finished = await self.finishPageTurnAnimation()
                guard !Task.isCancelled,
                      self.pageTurnStateMachine.accepts(generation) else { return }
                guard finished else {
                    self.pageTurnStateMachine.invalidate()
                    self.preferredPrewarmDirection = surface.direction
                    self.cleanupPageTurn(cancelPreparedSurface: true)
                    self.schedulePageTurnPrewarm()
                    return
                }
            }
            guard self.pageTurnStateMachine.beginCommitting(generation: generation) else {
                self.pageTurnStateMachine.invalidate()
                self.cleanupPageTurn(cancelPreparedSurface: true)
                self.schedulePageTurnPrewarm()
                return
            }

            let initialResult = await provider.commit(surface: surface)

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
                return
            }
            switch result {
            case .committed:
                // Keep the immutable target above the navigator until its live
                // WebView has painted the committed location. This gate applies
                // to every visual style, not only curl, so no style can flash
                // the previous page during the handoff.
                await self.model.waitForVisualUpdate(for: .full)
                await self.waitForRecoveryFrames()
                guard !Task.isCancelled,
                      self.pageTurnStateMachine.accepts(generation) else { return }
                self.preferredPrewarmDirection = surface.direction
                self.activePageSurface = nil
                _ = self.pageTurnStateMachine.finish(generation: generation)
                self.cleanupPageTurn(cancelPreparedSurface: false)
                self.cachedCurrentSurface = nil
                self.schedulePageTurnPrewarm()
            case .restored:
                await self.finishPageTurnRestoration()
                guard !Task.isCancelled,
                      self.pageTurnStateMachine.accepts(generation) else { return }
                self.activePageSurface = nil
                _ = self.pageTurnStateMachine.finish(generation: generation)
                self.cleanupPageTurn(cancelPreparedSurface: false)
                self.invalidatePageTurnCache()
                self.schedulePageTurnPrewarm()
            case .indeterminate:
                guard let recoveryCover = await self.recoverIndeterminatePageSurface(
                    surface: surface,
                    generation: generation,
                    provider: provider
                ) else {
                    self.abortCommittingPageTurn()
                    return
                }
                guard !Task.isCancelled,
                      self.pageTurnStateMachine.accepts(generation) else {
                    recoveryCover.removeFromSuperview()
                    return
                }

                recoveryCover.frame = self.snapshotHostView.bounds
                recoveryCover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                self.snapshotHostView.addSubview(recoveryCover)
                self.pageTurnAnimator?.remove()
                self.pageTurnAnimator = nil
                provider.invalidatePreparedSurfaces()
                self.activePageSurface = nil

                await self.model.waitForVisualUpdate(for: .full)
                await self.waitForRecoveryFrames()
                guard !Task.isCancelled,
                      self.pageTurnStateMachine.accepts(generation) else {
                    recoveryCover.removeFromSuperview()
                    return
                }

                _ = self.pageTurnStateMachine.finish(generation: generation)
                self.cleanupPageTurn(cancelPreparedSurface: false)
                recoveryCover.removeFromSuperview()
                self.cachedCurrentSurface = nil
                self.schedulePageTurnPrewarm()
            }
        }
    }

    private func finishPageTurnAnimation() async -> Bool {
        guard let pageTurnAnimator else { return false }
        return await waitForPageTurnAnimation { completion in
            pageTurnAnimator.animateCompletion(completion: completion)
        }
    }

    private func waitForPageTurnAnimation(
        _ animate: (@escaping (Bool) -> Void) -> Void
    ) async -> Bool {
        let gate = PageTurnAnimationGate()
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.pageTurnAnimationTimeout)
            guard !Task.isCancelled else { return }
            gate.resolve(false)
        }
        let result = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                animate { gate.resolve($0) }
            }
        }, onCancel: {
            Task { @MainActor in gate.resolve(false) }
        })
        timeoutTask.cancel()
        return result
    }

    @discardableResult
    private func installVisualCompletionFallback(direction: PageDirection) -> Bool {
        guard visualCompletionRecoveryAttempts == 0,
              let currentView = activeCurrentComposite,
              let targetView = activeTargetComposite else {
            return false
        }

        visualCompletionRecoveryAttempts += 1
        pageTurnAnimator?.remove()

        let animator = PageTurnVisualAnimator(
            style: .cover,
            hostView: snapshotHostView,
            currentView: currentView,
            targetView: targetView,
            completionTranslationX: PageTurnMetrics.completionTranslationX(
                containerWidth: snapshotHostView.bounds.width,
                direction: direction,
                readingDirection: model.pageSurfaceProvider?.readingDirection ?? .leftToRight
            ),
            isDark: isDarkPageBackground
        )
        pageTurnAnimator = animator
        guard animator.install() else {
            animator.remove()
            pageTurnAnimator = nil
            return false
        }
        return true
    }

    private func finishPageTurnRestoration() async {
        guard let pageTurnAnimator else { return }
        _ = await waitForPageTurnAnimation { completion in
            pageTurnAnimator.animateRestoration { completion(true) }
        }
    }

    private func animatePageTurnCancellation(
        generation: UInt,
        queuedDirection: PageDirection? = nil
    ) {
        pageTurnTask?.cancel()
        pageTurnTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if let animator = self.pageTurnAnimator {
                _ = await self.waitForPageTurnAnimation { completion in
                    animator.animateCancellation { completion(true) }
                }
            }
            guard !Task.isCancelled,
                  self.pageTurnStateMachine.accepts(generation),
                  self.pageTurnStateMachine.finishCancellation(generation: generation) else { return }
            let provider = self.model.pageSurfaceProvider
            self.cleanupPageTurn(cancelPreparedSurface: true)
            if let queuedDirection, let provider {
                self.queueProgrammaticPageTurn(direction: queuedDirection, provider: provider)
            } else {
                self.schedulePageTurnPrewarm()
            }
        }
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
        return await provider.reconcile(surface: surface, deadline: deadline)
    }

    private func recoverIndeterminatePageSurface(
        surface: PageSurface,
        generation: UInt,
        provider: any PageSurfaceProvider
    ) async -> UIView? {
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

            if model.engine.renderer.readingPosition() != nil,
               let cover = makeLiveRecoveryCover() {
                return cover
            }

            if attempt == 1 {
                rebuildReaderContentForRecovery()
            }

            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        return model.engine.renderer.readingPosition() != nil
            ? makeLiveRecoveryCover()
            : nil
    }

    private func rebuildReaderContentForRecovery() {
        guard let contentHostController else { return }
        contentSignature = makeContentSignature()
        contentHostController.rootView = makeContentRoot()
    }

    private func makeLiveRecoveryCover() -> UIView? {
        guard let contentView = contentHostController?.view else { return nil }
        contentView.layoutIfNeeded()
        let bounds = snapshotHostView.bounds.integral
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let cover = UIView(frame: bounds)
        cover.backgroundColor = latestReaderBackground
        cover.isOpaque = true
        cover.isUserInteractionEnabled = false
        cover.accessibilityElementsHidden = true

        if let image = makeCurrentContentSnapshot(afterScreenUpdates: true) {
            let imageView = UIImageView(image: image)
            imageView.frame = bounds
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            imageView.contentMode = .center
            cover.addSubview(imageView)
        } else if let snapshot = contentView.snapshotView(afterScreenUpdates: true) {
            snapshot.frame = bounds
            snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            cover.addSubview(snapshot)
        } else {
            return nil
        }

        if let header = chromeView.makePageHeaderSnapshot(title: latestTitle, in: snapshotHostView) {
            cover.addSubview(header)
        }
        return cover
    }

    private func waitForRecoveryFrames() async {
        await Task.yield()
        for _ in 0 ..< 2 {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
    }

    private func cancelPageTurn(animated: Bool) {
        cancelPendingProgrammaticPageTurn()
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
            animatePageTurnCancellation(generation: generation)
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
        activeCurrentComposite = nil
        activeTargetComposite = nil
        visualCompletionRecoveryAttempts = 0
        pageTurnAnimator?.remove()
        pageTurnAnimator = nil
        chromeView.setPageHeaderHiddenForTransition(false)
        activeTurnGeneration = nil
        pendingPanTranslationX = 0
        pendingPanTranslationY = 0
        pendingPanVelocityX = 0
        pendingPanVelocityY = 0
        pendingPanDidEnd = false
        isTrackingPageTurnPan = false
        panHasStartedTurn = false
        isBoundaryResistanceTurn = false
        isSurfaceRaceResistanceTurn = false
        configurePageTurnInteraction()
    }

    @discardableResult
    private func startPageTurnResistance(
        currentSurface: NavigatorCurrentPageSurface,
        direction: PageDirection,
        generation: UInt,
        provider: any PageSurfaceProvider,
        isConfirmedBoundary: Bool,
        interactive: Bool
    ) -> Bool {
        let currentView = makeCompositeSurface(
            contentImage: currentSurface.image,
            geometry: currentSurface.geometry,
            headerTitle: latestTitle
        )
        let destinationX = PageTurnMetrics.completionTranslationX(
            containerWidth: snapshotHostView.bounds.width,
            direction: direction,
            readingDirection: provider.readingDirection
        )
        let animator: any PageTurnAnimating = PageTurnBoundaryAnimator(
            hostView: snapshotHostView,
            currentView: currentView,
            completionTranslationX: destinationX
        )
        isBoundaryResistanceTurn = isConfirmedBoundary
        isSurfaceRaceResistanceTurn = !isConfirmedBoundary
        activeTurnGeneration = generation
        pendingPanDidEnd = !interactive
        if !interactive {
            pendingPanTranslationX = 0
            pendingPanVelocityX = 0
        }
        pageTurnAnimator = animator
        chromeView.hideControlsForSwipe()
        chromeView.setPageHeaderHiddenForTransition(true)
        guard animator.install() else {
            if !isConfirmedBoundary {
                return recoverFromPageTurnStartFailure(
                    direction: direction,
                    interactive: interactive,
                    provider: provider
                )
            }
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

    private func startPageTurnFromPanIfNeeded() {
        guard !panHasStartedTurn else { return }
        let hasHorizontalTranslation = abs(pendingPanTranslationX) >= 4
            && abs(pendingPanTranslationX) >= abs(pendingPanTranslationY) * 1.02
        let hasHorizontalFling = abs(pendingPanVelocityX) >= 80
            && abs(pendingPanVelocityX) >= abs(pendingPanVelocityY) * 1.02
        guard hasHorizontalTranslation || hasHorizontalFling else { return }
        let horizontalIntent = hasHorizontalTranslation
            ? pendingPanTranslationX
            : pendingPanVelocityX
        let edge: PageTurnEdge = horizontalIntent < 0 ? .right : .left
        let direction = PageTurnMetrics.pageDirection(
            for: edge,
            readingDirection: model.pageSurfaceProvider?.readingDirection ?? .leftToRight
        )
        panHasStartedTurn = startPageTurn(direction: direction, interactive: true)
    }

    private func schedulePageTurnPrewarm() {
        guard !isDismantling, isViewLoaded, view.window != nil, shouldOwnPaginatedPageTurns,
              pageTurnStateMachine.state == .idle,
              pageTurnPrewarmTask == nil,
              let provider = model.pageSurfaceProvider,
              snapshotHostView.bounds.width > 0,
              snapshotHostView.bounds.height > 0,
              cachedCurrentSurface == nil
                || needsPageSurfacePrewarm(provider.adjacentSurfaceReadiness(direction: .forward))
                || needsPageSurfacePrewarm(provider.adjacentSurfaceReadiness(direction: .backward))
                || needsCurlTexturePrewarm
        else { return }

        pageTurnPrewarmRevision &+= 1
        let revision = pageTurnPrewarmRevision
        let preferred = preferredPrewarmDirection
        pageTurnPrewarmTask = Task { @MainActor [weak self, weak provider] in
            guard let self, let provider else { return }
            defer {
                if revision == self.pageTurnPrewarmRevision {
                    self.pageTurnPrewarmTask = nil
                }
            }
            await Task.yield()

            for attempt in 0 ..< Self.pageSurfacePrewarmMaxAttempts {
                guard !Task.isCancelled,
                      revision == self.pageTurnPrewarmRevision,
                      self.pageTurnStateMachine.state == .idle else { return }

                await provider.prewarmAdjacentSurfaces(preferredDirection: preferred)
                guard !Task.isCancelled,
                      revision == self.pageTurnPrewarmRevision,
                      self.pageTurnStateMachine.state == .idle else { return }

                self.refreshPreparedPageTurnCacheIfAvailable()
                if self.pageTurnCacheIsFullyPublished {
                    self.configurePageTurnInteraction()
                    return
                }

                if attempt + 1 < Self.pageSurfacePrewarmMaxAttempts {
                    try? await Task.sleep(nanoseconds: Self.pageSurfacePrewarmRetryDelay)
                }
            }
            self.configurePageTurnInteraction()
        }
    }

    private func cancelPageTurnPrewarm() {
        pageTurnPrewarmRevision &+= 1
        pageTurnPrewarmTask?.cancel()
        pageTurnPrewarmTask = nil
    }

    /// A tap or a completed drag must not silently fall through to Readium's
    /// built-in smooth paging because a detached target is still warming. Hold
    /// gesture ownership, finish preparation, then launch the selected visual
    /// transition from a stable pair of immutable surfaces.
    private func queueProgrammaticPageTurn(
        direction: PageDirection,
        provider: any PageSurfaceProvider
    ) {
        cancelPendingProgrammaticPageTurn()
        preferredPrewarmDirection = direction
        pendingProgrammaticPageTurnRevision &+= 1
        let revision = pendingProgrammaticPageTurnRevision
        let selectedTransition = model.preferences.pageTransition
        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ Self.pendingProgrammaticPageTurnBudget

        pendingProgrammaticPageTurnTask = Task { @MainActor [weak self, weak provider] in
            guard let self, let provider else { return }
            defer {
                if revision == self.pendingProgrammaticPageTurnRevision {
                    self.pendingProgrammaticPageTurnTask = nil
                    self.configurePageTurnInteraction()
                    self.schedulePageTurnPrewarm()
                }
            }

            while DispatchTime.now().uptimeNanoseconds < deadline {
                guard !Task.isCancelled,
                      revision == self.pendingProgrammaticPageTurnRevision,
                      self.pageTurnStateMachine.state == .idle,
                      self.model.preferences.pageTransition == selectedTransition,
                      self.customPageTurnPreferenceIsActive else { return }

                guard provider.isPageSurfaceProviderReady,
                      !provider.usesContinuousScroll,
                      provider.supportsCustomPageTurns else {
                    try? await Task.sleep(nanoseconds: Self.pageSurfacePrewarmRetryDelay)
                    continue
                }

                await provider.prewarmAdjacentSurfaces(
                    preferredDirection: direction,
                    deadline: deadline
                )
                guard !Task.isCancelled,
                      revision == self.pendingProgrammaticPageTurnRevision,
                      self.pageTurnStateMachine.state == .idle else { return }

                self.refreshPreparedPageTurnCacheIfAvailable()
                let readiness = provider.adjacentSurfaceReadiness(direction: direction)
                if readiness == .unavailable {
                    return
                }
                if readiness == .ready, self.cachedCurrentSurface != nil {
                    self.pendingProgrammaticPageTurnTask = nil
                    _ = self.startPageTurn(
                        direction: direction,
                        interactive: false,
                        allowsDeferredProgrammaticRetry: false
                    )
                    return
                }

                try? await Task.sleep(nanoseconds: Self.pageSurfacePrewarmRetryDelay)
            }
        }
        configurePageTurnInteraction()
    }

    private func cancelPendingProgrammaticPageTurn() {
        pendingProgrammaticPageTurnRevision &+= 1
        pendingProgrammaticPageTurnTask?.cancel()
        pendingProgrammaticPageTurnTask = nil
    }

    private func needsPageSurfacePrewarm(_ readiness: NavigatorPageSurfaceReadiness) -> Bool {
        switch readiness {
        case .unknown, .failed:
            return true
        case .ready, .preparing, .unavailable:
            return false
        }
    }

    /// True when the curl is selected and usable, but its textures are not all
    /// uploaded. Without this the prewarm trigger would consider the cache
    /// published as soon as the surfaces were ready and never retry a failed
    /// upload — leaving the curl permanently without anything to draw.
    private var needsCurlTexturePrewarm: Bool {
        model.preferences.pageTransition == .pageCurl
            && PageCurlMetalResources.shared != nil
            && !curlTexturesAreWarm
    }

    private func refreshPreparedPageTurnCacheIfAvailable() {
        guard pageTurnStateMachine.state == .idle,
              let provider = model.pageSurfaceProvider else { return }
        guard let currentSurface = provider.preparedCurrentSurface() else {
            cachedCurrentSurface = nil
            return
        }

        cachedCurrentSurface = currentSurface
        warmCurlTexturesIfNeeded(currentSurface: currentSurface, provider: provider)
    }

    /// Rasterises and uploads the three pages the curl may need, while the
    /// reader is settled.
    ///
    /// This is the whole point of the Metal path: converting a page into a
    /// texture is the expensive half, and doing it on the first `.changed` of a
    /// pan is what made the curl feel late. Once the textures are here, the
    /// gesture path contains no rasterising, no layer rendering and no upload.
    ///
    /// Peeking (`preparedAdjacentSurface`) rather than consuming, so the
    /// surfaces themselves stay available for the gesture that follows.
    private func warmCurlTexturesIfNeeded(
        currentSurface: NavigatorCurrentPageSurface,
        provider: PageSurfaceProvider
    ) {
        guard shouldOwnPaginatedPageTurns,
              model.preferences.pageTransition == .pageCurl,
              let resources = PageCurlMetalResources.shared else {
            curlTexturesAreWarm = false
            return
        }

        var complete = storeCurlTexture(
            image: currentSurface.image,
            geometry: currentSurface.geometry,
            headerTitle: latestTitle,
            key: .current(currentSurface),
            resources: resources
        )

        for direction in [PageDirection.forward, .backward] {
            guard let surface = provider.preparedAdjacentSurface(direction: direction) else {
                complete = false
                continue
            }
            let stored = storeCurlTexture(
                image: surface.image,
                geometry: surface.geometry,
                headerTitle: surface.headerTitle,
                key: .adjacent(surface, direction: direction),
                resources: resources
            )
            complete = complete && stored
        }

        curlTexturesAreWarm = complete
    }

    /// Returns whether the texture is on the GPU afterwards. A false result is
    /// what lets prewarming retry: an upload that fails leaves the *surfaces*
    /// looking ready while the curl still has nothing to draw.
    @discardableResult
    private func storeCurlTexture(
        image: UIImage,
        geometry: NavigatorPageSurfaceGeometry,
        headerTitle: String?,
        key: CurlTextureKey,
        resources: PageCurlMetalResources
    ) -> Bool {
        guard curlTextureCache.texture(for: key, matching: geometry) == nil else {
            return true
        }

        let composite = makeCompositeSurface(
            contentImage: image,
            geometry: geometry,
            headerTitle: headerTitle
        )
        guard let compositeImage = makeCompositeImage(from: composite, scale: geometry.scale),
              let texture = CurlTextureCache.makeTexture(
                  from: compositeImage,
                  device: resources.device
              ) else {
            return false
        }
        curlTextureCache.store(texture, geometry: geometry, for: key)
        return true
    }

    private func makeCoverAnimator(
        currentView: UIView,
        targetView: UIView,
        destinationX: CGFloat
    ) -> any PageTurnAnimating {
        PageTurnVisualAnimator(
            style: .cover,
            hostView: snapshotHostView,
            currentView: currentView,
            targetView: targetView,
            completionTranslationX: destinationX,
            isDark: isDarkPageBackground
        )
    }

    /// Returns nil when the curl textures are not on the GPU, so the caller can
    /// fall back to the cover transition.
    ///
    /// There is deliberately no rasterise-on-demand path here. Uploading a page
    /// mid-gesture is the exact cost this pipeline exists to remove, and a
    /// fallback that quietly did it would also hide whether prewarming works.
    private func makeCurlAnimator(
        currentSurface: NavigatorCurrentPageSurface,
        targetSurface: PageSurface,
        direction: PageDirection,
        destinationX: CGFloat
    ) -> (any PageTurnAnimating)? {
        guard let textures = curlTextureCache.curlTextures(
            currentSurface: currentSurface,
            targetSurface: targetSurface,
            direction: direction
        ) else {
            return nil
        }

        return PageTurnCurlAnimator(
            hostView: snapshotHostView,
            currentTexture: textures.current,
            targetTexture: textures.target,
            completionTranslationX: destinationX,
            isDark: isDarkPageBackground
        )
    }

    private func invalidatePageTurnCache() {
        guard pageTurnStateMachine.state != .committing else { return }
        cancelPageTurnPrewarm()
        cachedCurrentSurface = nil
        // The uploaded textures describe the same surfaces this invalidates, so
        // they have to go together — otherwise a rotated viewport could be
        // served a texture rasterised at the old size.
        curlTextureCache.removeAll()
        curlTexturesAreWarm = false
        model.pageSurfaceProvider?.invalidatePreparedSurfaces()
        configurePageTurnInteraction()
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

    private func abortCommittingPageTurn() {
        if let surface = activePageSurface {
            model.pageSurfaceProvider?.cancel(surface: surface)
        }
        pageTurnStateMachine.invalidate()
        externalTakeoverTask?.cancel()
        externalTakeoverTask = nil
        isExternalTakeoverActive = true
        model.pageSurfaceProvider?.invalidatePreparedSurfaces()
    }

    private func finishQueuedExternalTakeover() {
        guard isExternalTakeoverActive, externalTakeoverTask == nil else { return }
        let action = queuedExternalAction
        queuedExternalAction = nil
        action?(self)
        resolveExternalTakeover()
    }

    private func resolveExternalTakeover() {
        externalTakeoverTask?.cancel()
        externalTakeoverTask = Task { @MainActor [weak self] in
            guard let self else { return }

            for attempt in 0 ..< 12 {
                guard !Task.isCancelled, self.isExternalTakeoverActive else { return }
                await self.model.waitForVisualUpdate(for: .full)
                guard !Task.isCancelled, self.isExternalTakeoverActive else { return }
                await Task.yield()

                if let recoveryCover = self.makeLiveRecoveryCover() {
                    recoveryCover.frame = self.snapshotHostView.bounds
                    recoveryCover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    self.snapshotHostView.addSubview(recoveryCover)
                    self.pageTurnAnimator?.remove()
                    self.pageTurnAnimator = nil
                    await self.waitForRecoveryFrames()
                    guard !Task.isCancelled, self.isExternalTakeoverActive else {
                        recoveryCover.removeFromSuperview()
                        return
                    }
                    self.isExternalTakeoverActive = false
                    self.cleanupPageTurn(cancelPreparedSurface: false)
                    recoveryCover.removeFromSuperview()
                    self.cachedCurrentSurface = nil
                    self.externalTakeoverTask = nil
                    self.configurePageTurnInteraction()
                    self.schedulePageTurnPrewarm()
                    return
                }

                if attempt == 5 {
                    self.rebuildReaderContentForRecovery()
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            guard !Task.isCancelled, self.isExternalTakeoverActive else { return }
            // Recovery has a finite visual budget. If no drawable live cover
            // can be captured, release gesture ownership instead of retrying
            // forever and leaving the reader permanently unresponsive.
            self.isExternalTakeoverActive = false
            self.pageTurnStateMachine.invalidate()
            self.cleanupPageTurn(cancelPreparedSurface: false)
            self.cachedCurrentSurface = nil
            self.model.pageSurfaceProvider?.invalidatePreparedSurfaces()
            self.externalTakeoverTask = nil
            self.configurePageTurnInteraction()
            self.schedulePageTurnPrewarm()
        }
    }

    private func makeCurrentContentSnapshot(afterScreenUpdates: Bool = false) -> UIImage? {
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
            contentView.drawHierarchy(in: bounds, afterScreenUpdates: afterScreenUpdates)
        }
    }

    private func makeCompositeSurface(
        contentImage: UIImage,
        geometry: NavigatorPageSurfaceGeometry,
        headerTitle: String?
    ) -> UIView {
        let composite = UIView(frame: snapshotHostView.bounds)
        composite.backgroundColor = latestReaderBackground
        composite.isOpaque = true
        composite.clipsToBounds = true
        composite.isUserInteractionEnabled = false
        composite.accessibilityElementsHidden = true
        composite.isAccessibilityElement = false

        let content = UIImageView(image: contentImage)
        content.contentMode = .scaleAspectFit
        content.clipsToBounds = true
        content.frame = geometry.contentRect
        content.isUserInteractionEnabled = false
        composite.addSubview(content)
        if let header = chromeView.makePageHeaderSnapshot(title: headerTitle, in: snapshotHostView) {
            composite.addSubview(header)
        }
        return composite
    }

    private func makeCompositeImage(from composite: UIView, scale: CGFloat) -> UIImage? {
        let bounds = snapshotHostView.bounds.integral
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return nil }

        composite.frame = bounds
        composite.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        let screenScale = view.window?.windowScene?.screen.scale ?? UIScreen.main.scale
        format.scale = scale.isFinite && scale > 0 ? scale : screenScale
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            context.cgContext.setFillColor(latestReaderBackground.cgColor)
            context.cgContext.fill(bounds)
            composite.layer.render(in: context.cgContext)
        }
    }

    @discardableResult
    private func recoverFromPageTurnStartFailure(
        direction: PageDirection,
        interactive: Bool,
        provider: any PageSurfaceProvider
    ) -> Bool {
        let shouldNavigate: Bool
        if !interactive {
            shouldNavigate = true
        } else if pendingPanDidEnd {
            let progress = PageTurnMetrics.progress(
                forTranslationX: pendingPanTranslationX,
                containerWidth: snapshotHostView.bounds.width,
                direction: direction,
                readingDirection: provider.readingDirection
            )
            shouldNavigate = PageTurnMetrics.decision(
                progress: progress,
                velocityX: pendingPanVelocityX,
                direction: direction,
                readingDirection: provider.readingDirection
            ) == .complete
        } else {
            shouldNavigate = false
        }

        pageTurnStateMachine.invalidate()
        preferredPrewarmDirection = direction
        cleanupPageTurn(cancelPreparedSurface: true)
        if shouldNavigate {
            if customPageTurnPreferenceIsActive {
                queueProgrammaticPageTurn(direction: direction, provider: provider)
            } else {
                navigateWithoutCustomTransition(direction: direction, provider: provider)
            }
        } else {
            schedulePageTurnPrewarm()
        }
        return shouldNavigate
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
        guard imageMatchesGeometry(currentSurface.image, current),
              imageMatchesGeometry(targetSurface.image, target) else { return false }
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
            && equal(current.contentRect.minX, 0)
            && equal(current.contentRect.width, viewportSize.width)
            && current.contentRect.minY >= -tolerance
            && current.contentRect.maxY <= viewportSize.height + tolerance
    }

    private func imageMatchesGeometry(
        _ image: UIImage,
        _ geometry: NavigatorPageSurfaceGeometry
    ) -> Bool {
        guard geometry.pointSize.width.isFinite,
              geometry.pointSize.height.isFinite,
              geometry.pixelSize.width.isFinite,
              geometry.pixelSize.height.isFinite,
              geometry.scale.isFinite,
              geometry.pointSize.width > 0,
              geometry.pointSize.height > 0,
              geometry.pixelSize.width > 0,
              geometry.pixelSize.height > 0,
              geometry.scale > 0,
              image.size.width.isFinite,
              image.size.height.isFinite,
              image.size.width > 0,
              image.size.height > 0,
              image.scale.isFinite,
              image.scale > 0,
              let cgImage = image.cgImage,
              cgImage.width > 0,
              cgImage.height > 0 else { return false }

        let imagePointSize = image.size
        let imagePixelSize = CGSize(
            width: CGFloat(cgImage.width),
            height: CGFloat(cgImage.height)
        )
        let pointTolerance: CGFloat = 1.0
        let pixelTolerance: CGFloat = 2.0
        let pointSizeMatches = abs(imagePointSize.width - geometry.pointSize.width) <= pointTolerance
            && abs(imagePointSize.height - geometry.pointSize.height) <= pointTolerance
        let pixelSizeMatches = abs(imagePixelSize.width - geometry.pixelSize.width) <= pixelTolerance
            && abs(imagePixelSize.height - geometry.pixelSize.height) <= pixelTolerance
        let actualScale = imagePixelSize.width / imagePointSize.width
        let scaleTolerance = max(0.05, geometry.scale * 0.02)
        return pointSizeMatches
            && pixelSizeMatches
            && abs(actualScale - geometry.scale) <= scaleTolerance
    }

    private func pageSurfaceGeometryIsCompatibleWithViewport(
        _ geometry: NavigatorPageSurfaceGeometry,
        viewportSize: CGSize
    ) -> Bool {
        guard viewportSize.width.isFinite, viewportSize.height.isFinite,
              viewportSize.width > 0, viewportSize.height > 0,
              geometry.contentRect.minX.isFinite,
              geometry.contentRect.minY.isFinite,
              geometry.contentRect.width.isFinite,
              geometry.contentRect.height.isFinite,
              geometry.contentRect.width > 0,
              geometry.contentRect.height > 0 else { return false }
        let tolerance: CGFloat = 0.5
        return abs(geometry.contentRect.minX) <= tolerance
            && abs(geometry.contentRect.width - viewportSize.width) <= tolerance
            && geometry.contentRect.minY >= -tolerance
            && geometry.contentRect.maxY <= viewportSize.height + tolerance
    }

    private func navigateWithoutCustomTransition(
        direction: PageDirection,
        provider: any PageSurfaceProvider
    ) {
        pageTurnTask?.cancel()
        nativeNavigationRevision &+= 1
        let revision = nativeNavigationRevision
        pageTurnTask = Task { @MainActor [weak self] in
            _ = await provider.navigateWithoutCustomTransition(direction: direction)
            guard let self, !Task.isCancelled,
                  revision == self.nativeNavigationRevision else { return }
            self.invalidatePageTurnCache()
            self.schedulePageTurnPrewarm()
        }
    }

    @discardableResult
    private func queueProgrammaticPageTurnIfGestureCompleted(
        direction: PageDirection,
        provider: any PageSurfaceProvider
    ) -> Bool {
        let readingDirection = provider.readingDirection
        let progress = PageTurnMetrics.progress(
            forTranslationX: pendingPanTranslationX,
            containerWidth: snapshotHostView.bounds.width,
            direction: direction,
            readingDirection: readingDirection
        )
        guard PageTurnMetrics.decision(
            progress: progress,
            velocityX: pendingPanVelocityX,
            direction: direction,
            readingDirection: readingDirection
        ) == .complete else { return false }
        queueProgrammaticPageTurn(direction: direction, provider: provider)
        return true
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
                    // Leave Readium's tap callback stack before changing its
                    // interaction state or consuming an adjacent surface.
                    DispatchQueue.main.async { [weak self] in
                        self?.startPageTurn(direction: direction, interactive: false)
                    }
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
