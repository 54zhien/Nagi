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
final class ReaderViewController: UIViewController, UIGestureRecognizerDelegate, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    private let model: ReaderViewModel
    private let readerTransitionCoordinator: ReaderTransitionCoordinator

    private let chromeView = ReaderChromeView()
    private let snapshotHostView = ReaderSnapshotHostView()
    private var pageViewController: UIPageViewController?
    private var contentHostController: UIHostingController<ReaderContentHostView>?
    private var contentSignature: ReaderContentSignature?
    private var panGestureRecognizer: UIPanGestureRecognizer?
    private let pageTurnStateMachine = PageTurnStateMachine()
    private var pageTurnTask: Task<Void, Never>?
    private var pageTurnPrewarmTask: Task<Void, Never>?
    private var pageTurnPrewarmRevision: UInt = 0
    private var preferredPrewarmDirection: PageDirection = .forward
    private var cachedCurrentSurface: NavigatorCurrentPageSurface?
    private var activePageSurface: PageSurface?
    private var pageTurnAnimator: (any PageTurnAnimating)?
    private var externalTakeoverTask: Task<Void, Never>?
    private var isExternalTakeoverActive = false
    private var queuedExternalAction: ((ReaderViewController) -> Void)?
    private var activeTurnGeneration: UInt?
    private var pendingPanTranslationX: CGFloat = 0
    private var pendingPanTranslationY: CGFloat = 0
    private var pendingPanVelocityX: CGFloat = 0
    private var pendingPanVelocityY: CGFloat = 0
    private var pendingPanDidEnd = false
    private var panHasStartedTurn = false
    private var isBoundaryResistanceTurn = false
    private var pageCurlPreparedControllers: [PageDirection: PageTurnSnapshotViewController] = [:]
    private var pageCurlCurrentHeaderSnapshot: UIView?
    private var pageCurlTransitionActive = false
    private var pageCurlProgrammatic = false
    private var fallbackNavigationRevision: UInt = 0
    private static let pageSurfaceResolutionBudget: UInt64 = 2_000_000_000
    private static let pageSurfaceRecoveryBudget: UInt64 = 1_200_000_000
    private static let pageSurfaceRecoveryAttempts = 3
    private static let pageSurfacePrewarmRetryDelay: UInt64 = 180_000_000
    private static let pageSurfacePrewarmMaxAttempts = 3

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
        let pageController = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: nil
        )
        pageController.isDoubleSided = false
        pageController.delegate = self
        pageController.dataSource = nil
        addChild(pageController)
        pageController.view.frame = view.bounds
        pageController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pageController.view.backgroundColor = .clear
        pageController.view.isOpaque = false
        view.insertSubview(pageController.view, at: 0)
        pageController.setViewControllers(
            [contentController],
            direction: .forward,
            animated: false
        )
        pageController.didMove(toParent: self)
        pageViewController = pageController
        contentHostController = contentController
        setPageCurlInternalInteractionEnabled(false)

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
        pageViewController?.view.frame = bounds
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

        if let pageViewController {
            pageViewController.dataSource = nil
            pageViewController.delegate = nil
            pageViewController.willMove(toParent: nil)
            pageViewController.view.removeFromSuperview()
            pageViewController.removeFromParent()
            self.pageViewController = nil
        }
        contentHostController = nil
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: gesture.view)
        let velocity = gesture.velocity(in: gesture.view)

        switch gesture.state {
        case .began:
            guard isCustomPageTurnEnabled else { return }
            pendingPanTranslationX = translation.x
            pendingPanTranslationY = translation.y
            pendingPanVelocityX = velocity.x
            pendingPanVelocityY = velocity.y
            pendingPanDidEnd = false
            panHasStartedTurn = false

        case .changed:
            pendingPanTranslationX = translation.x
            pendingPanTranslationY = translation.y
            pendingPanVelocityX = velocity.x
            pendingPanVelocityY = velocity.y
            startPageTurnFromPanIfNeeded()
            updateInteractivePageTurn()

        case .ended:
            pendingPanTranslationX = translation.x
            pendingPanTranslationY = translation.y
            pendingPanVelocityX = velocity.x
            pendingPanVelocityY = velocity.y
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

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panGestureRecognizer, let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return true
        }
        guard isCustomPageTurnEnabled else { return false }
        let translation = pan.translation(in: pan.view)
        let velocity = pan.velocity(in: pan.view)
        let horizontal = abs(translation.x) > 0.5 ? translation.x : velocity.x
        let vertical = abs(translation.y) > 0.5 ? translation.y : velocity.y

        // Do not claim an undecided touch. In particular, this keeps a slow
        // vertical gesture available to Readium's continuous scroll view.
        guard abs(horizontal) > 0.5 || abs(vertical) > 0.5 else { return false }
        return abs(horizontal) > abs(vertical) * 1.05
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
            && model.pageSurfaceProvider?.usesContinuousScroll == false
    }

    private var isCustomPageTurnCandidateEnabled: Bool {
        model.preferences.pageTransition != .scroll
            && !latestReduceMotion
            && !UIAccessibility.isVoiceOverRunning
            && !isExternalTakeoverActive
            && model.pageSurfaceProvider?.isPageSurfaceProviderReady == true
            && model.pageSurfaceProvider?.usesContinuousScroll == false
    }

    /// Reports whether the complete two-sided cache has finished warming.
    /// Gesture ownership no longer depends on this value: otherwise Readium's
    /// ordinary smooth swipe can replace the mode the reader selected merely
    /// because the opposite direction is still preparing.
    private var pageTurnSurfacesArePublished: Bool {
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
        guard pageTurnStateMachine.state == .idle,
              !pageCurlTransitionActive else {
            panGestureRecognizer?.isEnabled = false
            model.pageSurfaceProvider?.setBuiltInPageTurnInteractionEnabled(false)
            return
        }

        let enabled = isCustomPageTurnEnabled
        let usesSystemCurl = enabled && model.preferences.pageTransition == .pageCurl
        panGestureRecognizer?.isEnabled = enabled && !usesSystemCurl
        pageViewController?.dataSource = usesSystemCurl ? self : nil
        setPageCurlInternalInteractionEnabled(usesSystemCurl)
        model.pageSurfaceProvider?.setBuiltInPageTurnInteractionEnabled(!enabled)
        if usesSystemCurl {
            // Install the moving title before UIKit begins tracking a touch;
            // waiting for `willTransitionTo` can be too late for its curl
            // snapshot. Reader controls remain in the fixed chrome layer.
            installPageCurlCurrentHeaderSnapshot()
            chromeView.setPageHeaderHiddenForTransition(true)
        } else {
            pageCurlCurrentHeaderSnapshot?.removeFromSuperview()
            pageCurlCurrentHeaderSnapshot = nil
            chromeView.setPageHeaderHiddenForTransition(false)
            clearPreparedPageCurlControllers()
        }
        if isCustomPageTurnCandidateEnabled {
            schedulePageTurnPrewarm()
        }
    }

    private func setPageCurlInternalInteractionEnabled(_ enabled: Bool) {
        guard let pageViewController else { return }
        for gesture in pageViewController.gestureRecognizers {
            // Edge taps continue through the reader's existing adaptive hit
            // zones. Only UIKit's pan owns the interactive curl, preventing
            // its private tap recognizers from stealing center-content taps.
            gesture.isEnabled = enabled && gesture is UIPanGestureRecognizer
        }
    }

    private func clearPreparedPageCurlControllers() {
        pageCurlPreparedControllers.removeAll()
    }

    private func installPageCurlCurrentHeaderSnapshot() {
        guard let contentView = contentHostController?.view,
              let header = chromeView.makePageHeaderSnapshot(
                  title: latestTitle,
                  in: contentView
              ) as? UILabel else {
            pageCurlCurrentHeaderSnapshot?.removeFromSuperview()
            pageCurlCurrentHeaderSnapshot = nil
            return
        }
        if let current = pageCurlCurrentHeaderSnapshot as? UILabel,
           current.superview === contentView {
            current.frame = header.frame
            current.text = header.text
            current.font = header.font
            current.textColor = header.textColor
            current.textAlignment = header.textAlignment
            current.lineBreakMode = header.lineBreakMode
            return
        }
        pageCurlCurrentHeaderSnapshot?.removeFromSuperview()
        header.autoresizingMask = [.flexibleWidth, .flexibleBottomMargin]
        contentView.addSubview(header)
        pageCurlCurrentHeaderSnapshot = header
    }

    private func pageCurlNavigationDirection(
        for direction: PageDirection
    ) -> UIPageViewController.NavigationDirection {
        switch (direction, model.pageSurfaceProvider?.readingDirection ?? .leftToRight) {
        case (.forward, .leftToRight), (.backward, .rightToLeft):
            return .forward
        case (.backward, .leftToRight), (.forward, .rightToLeft):
            return .reverse
        }
    }

    private func pageDirection(
        for navigationDirection: UIPageViewController.NavigationDirection
    ) -> PageDirection {
        switch (navigationDirection, model.pageSurfaceProvider?.readingDirection ?? .leftToRight) {
        case (.forward, .leftToRight), (.reverse, .rightToLeft):
            return .forward
        case (.reverse, .leftToRight), (.forward, .rightToLeft):
            return .backward
        @unknown default:
            return .forward
        }
    }

    private func preparedPageCurlController(
        direction: PageDirection
    ) -> PageTurnSnapshotViewController? {
        guard pageTurnStateMachine.state == .idle,
              !pageCurlTransitionActive,
              let provider = model.pageSurfaceProvider,
              let currentSurface = cachedCurrentSurface,
              let surface = provider.preparedAdjacentSurface(direction: direction),
              pageSurfaceGeometryIsCompatible(
                  current: currentSurface,
                  target: surface,
                  viewportSize: snapshotHostView.bounds.size
              ) else { return nil }

        if let cached = pageCurlPreparedControllers[direction],
           cached.surfaceIdentity == surface.identity {
            return cached
        }

        let composite = makeCompositeSurface(
            contentImage: surface.image,
            geometry: surface.geometry,
            headerTitle: surface.headerTitle
        )
        let controller = PageTurnSnapshotViewController(
            view: composite,
            pageDirection: direction,
            surfaceIdentity: surface.identity
        )
        pageCurlPreparedControllers[direction] = controller
        return controller
    }

    private func rejectActivePageCurlTransition() {
        pageTurnStateMachine.invalidate()
        activeTurnGeneration = nil
        pageCurlTransitionActive = true
        model.pageSurfaceProvider?.setBuiltInPageTurnInteractionEnabled(false)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
        guard pageViewController === self.pageViewController,
              viewController === contentHostController else { return nil }
        return preparedPageCurlController(direction: pageDirection(for: .reverse))
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
        guard pageViewController === self.pageViewController,
              viewController === contentHostController else { return nil }
        return preparedPageCurlController(direction: pageDirection(for: .forward))
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        willTransitionTo pendingViewControllers: [UIViewController]
    ) {
        guard pageViewController === self.pageViewController,
              !pageCurlProgrammatic,
              !pageCurlTransitionActive else { return }
        guard let targetController = pendingViewControllers.first as? PageTurnSnapshotViewController,
              let direction = targetController.pageDirection,
              let expectedIdentity = targetController.surfaceIdentity,
              let provider = model.pageSurfaceProvider,
              let currentSurface = cachedCurrentSurface,
              let generation = pageTurnStateMachine.prepare(direction: direction) else {
            rejectActivePageCurlTransition()
            return
        }

        guard let surface = provider.takePreparedAdjacentSurface(direction: direction) else {
            rejectActivePageCurlTransition()
            return
        }
        guard surface.identity == expectedIdentity,
              pageSurfaceGeometryIsCompatible(
                  current: currentSurface,
                  target: surface,
                  viewportSize: snapshotHostView.bounds.size
              ),
              pageTurnStateMachine.beginInteractive(generation: generation) else {
            provider.cancel(surface: surface)
            rejectActivePageCurlTransition()
            return
        }

        activeTurnGeneration = generation
        activePageSurface = surface
        pageCurlTransitionActive = true
        preferredPrewarmDirection = direction
        installPageCurlCurrentHeaderSnapshot()
        chromeView.hideControlsForSwipe()
        chromeView.setPageHeaderHiddenForTransition(true)
        setPageCurlInternalInteractionEnabled(true)
        model.pageSurfaceProvider?.setBuiltInPageTurnInteractionEnabled(false)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool
    ) {
        _ = previousViewControllers
        guard pageViewController === self.pageViewController,
              !pageCurlProgrammatic else { return }
        guard pageCurlTransitionActive,
              let generation = activeTurnGeneration else {
            if completed {
                resetPageCurlToLive(animated: false)
            }
            pageCurlTransitionActive = false
            pageCurlProgrammatic = false
            clearPreparedPageCurlControllers()
            chromeView.setPageHeaderHiddenForTransition(false)
            configurePageTurnInteraction()
            schedulePageTurnPrewarm()
            return
        }

        if finished && completed {
            // UIKit has finished the visible curl, but the immutable target
            // remains on screen while Readium commits and paints it. Do not
            // let a second curl recognizer consume touches in that window.
            setPageCurlInternalInteractionEnabled(false)
            guard pageTurnStateMachine.finish(with: .complete, generation: generation) else {
                pageTurnStateMachine.invalidate()
                cleanupPageTurn(cancelPreparedSurface: true)
                return
            }
            animatePageTurnCompletion(
                generation: generation,
                animationAlreadyFinished: true
            )
        } else {
            _ = pageTurnStateMachine.finish(with: .cancel, generation: generation)
            _ = pageTurnStateMachine.finishCancellation(generation: generation)
            cleanupPageTurn(cancelPreparedSurface: true)
            schedulePageTurnPrewarm()
        }
    }

    private func startProgrammaticPageCurl(
        surface: PageSurface,
        targetView: UIView,
        generation: UInt
    ) -> Bool {
        guard let pageViewController,
              pageViewController.viewControllers?.first === contentHostController,
              pageTurnStateMachine.beginInteractive(generation: generation),
              pageTurnStateMachine.finish(with: .complete, generation: generation) else {
            return false
        }

        let targetController = PageTurnSnapshotViewController(
            view: targetView,
            pageDirection: surface.direction,
            surfaceIdentity: surface.identity
        )
        activeTurnGeneration = generation
        activePageSurface = surface
        pageCurlTransitionActive = true
        pageCurlProgrammatic = true
        preferredPrewarmDirection = surface.direction
        installPageCurlCurrentHeaderSnapshot()
        chromeView.hideControlsForSwipe()
        chromeView.setPageHeaderHiddenForTransition(true)
        pageViewController.dataSource = nil
        setPageCurlInternalInteractionEnabled(false)
        model.pageSurfaceProvider?.setBuiltInPageTurnInteractionEnabled(false)

        pageViewController.setViewControllers(
            [targetController],
            direction: pageCurlNavigationDirection(for: surface.direction),
            animated: true
        ) { [weak self] finished in
            guard let self,
                  self.pageTurnStateMachine.accepts(generation) else { return }
            if finished {
                self.animatePageTurnCompletion(
                    generation: generation,
                    animationAlreadyFinished: true
                )
            } else {
                self.pageTurnStateMachine.invalidate()
                self.cleanupPageTurn(cancelPreparedSurface: true)
                self.schedulePageTurnPrewarm()
            }
        }
        return true
    }

    private func resetPageCurlToLive(
        animated: Bool,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard let pageViewController,
              let contentHostController else {
            completion?(false)
            return
        }
        guard pageViewController.viewControllers?.first !== contentHostController else {
            completion?(true)
            return
        }
        let direction: UIPageViewController.NavigationDirection = activePageSurface.map {
            pageCurlNavigationDirection(for: $0.direction) == .forward
                ? UIPageViewController.NavigationDirection.reverse
                : UIPageViewController.NavigationDirection.forward
        } ?? UIPageViewController.NavigationDirection.reverse
        pageViewController.setViewControllers(
            [contentHostController],
            direction: direction,
            animated: animated,
            completion: completion
        )
    }

    @discardableResult
    private func startPageTurn(direction: PageDirection, interactive: Bool) -> Bool {
        guard !isExternalTakeoverActive else { return false }
        guard let provider = model.pageSurfaceProvider else { return false }
        guard !provider.usesContinuousScroll else {
            handleContentToggle()
            return false
        }
        guard model.preferences.pageTransition != .scroll else {
            // Fixed-layout EPUBs cannot join the publication-wide vertical
            // scroll. Keep their paginated fallback operable for edge taps.
            navigateWithoutCustomTransition(direction: direction, provider: provider)
            return true
        }
        guard let generation = pageTurnStateMachine.prepare(direction: direction) else { return false }
        fallbackNavigationRevision &+= 1

        if latestReduceMotion || UIAccessibility.isVoiceOverRunning {
            pageTurnStateMachine.invalidate()
            navigateWithoutCustomTransition(direction: direction, provider: provider)
            return true
        }

        guard let currentSurface = cachedCurrentSurface else {
            pageTurnStateMachine.invalidate()
            preferredPrewarmDirection = direction
            schedulePageTurnPrewarm()
            if !interactive {
                navigateWithoutCustomTransition(direction: direction, provider: provider)
                return true
            }
            if pendingPanDidEnd {
                navigateWithoutCustomTransitionIfGestureCompleted(
                    direction: direction,
                    provider: provider
                )
                return true
            }
            return false
        }

        guard let surface = provider.takePreparedAdjacentSurface(direction: direction) else {
            let readiness = provider.adjacentSurfaceReadiness(direction: direction)
            if readiness != .unavailable {
                pageTurnStateMachine.invalidate()
                preferredPrewarmDirection = direction
                schedulePageTurnPrewarm()
                if !interactive {
                    navigateWithoutCustomTransition(direction: direction, provider: provider)
                    return true
                }
                if pendingPanDidEnd {
                    navigateWithoutCustomTransitionIfGestureCompleted(
                        direction: direction,
                        provider: provider
                    )
                    return true
                }
                return false
            }
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
            let fallbackAnimator: any PageTurnAnimating = PageTurnBoundaryAnimator(
                hostView: snapshotHostView,
                currentView: currentView,
                completionTranslationX: destinationX
            )
            isBoundaryResistanceTurn = true
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
                pageTurnStateMachine.invalidate()
                preferredPrewarmDirection = direction
                schedulePageTurnPrewarm()
                if pendingPanDidEnd {
                    navigateWithoutCustomTransitionIfGestureCompleted(
                        direction: direction,
                        provider: provider
                    )
                    return true
                }
                return false
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

        if model.preferences.pageTransition == .pageCurl {
            if startProgrammaticPageCurl(
                surface: surface,
                targetView: targetComposite,
                generation: generation
            ) {
                return true
            }
            pageTurnStateMachine.invalidate()
            provider.cancel(surface: surface)
            cleanupPageTurn(cancelPreparedSurface: false)
            configurePageTurnInteraction()
            schedulePageTurnPrewarm()
            return false
        }

        let animator: any PageTurnAnimating
        switch model.preferences.pageTransition {
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
        case .slide, .scroll, .pageCurl:
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
                self.schedulePageTurnPrewarm()
            }
        }
    }

    private func animatePageTurnCompletion(
        generation: UInt,
        animationAlreadyFinished: Bool = false
    ) {
        guard let provider = model.pageSurfaceProvider,
              let surface = activePageSurface else {
            cancelPageTurn(animated: false)
            return
        }

        pageTurnTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // The target snapshot is the visual source of truth until the
            // animation has ended. Commit Readium only after that point so a
            // late WebView restore/repaint cannot flash the previous page.
            let finished: Bool
            if animationAlreadyFinished {
                finished = true
            } else {
                finished = await self.finishPageTurnAnimation()
            }
            guard !Task.isCancelled else { return }
            guard self.pageTurnStateMachine.accepts(generation) else {
                self.finishQueuedExternalTakeover()
                return
            }
            guard finished,
                  self.pageTurnStateMachine.beginCommitting(generation: generation) else {
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
                self.finishQueuedExternalTakeover()
                return
            }
            switch result {
            case .committed:
                // The system curl is already showing the immutable target.
                // Keep it in place until the live navigator has painted the
                // committed location, then swap the live controller back in
                // without another visible transition.
                if self.pageCurlTransitionActive {
                    await self.model.waitForVisualUpdate(for: .full)
                    await self.waitForRecoveryFrames()
                    guard !Task.isCancelled,
                          self.pageTurnStateMachine.accepts(generation) else { return }
                }
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
                    self.finishQueuedExternalTakeover()
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

    private func finishPageTurnRestoration() async {
        if pageCurlTransitionActive {
            let gate = PageTurnAnimationGate()
            _ = await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { continuation in
                    gate.install(continuation)
                    resetPageCurlToLive(animated: true) { finished in
                        gate.resolve(finished)
                    }
                }
            }, onCancel: {
                Task { @MainActor in gate.resolve(false) }
            })
            return
        }
        guard let pageTurnAnimator else { return }
        let gate = PageTurnAnimationGate()
        _ = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                pageTurnAnimator.animateRestoration {
                    gate.resolve(true)
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

        if pageCurlTransitionActive {
            pageTurnStateMachine.invalidate()
            cleanupPageTurn(cancelPreparedSurface: true)
            schedulePageTurnPrewarm()
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
        pageTurnAnimator?.remove()
        pageTurnAnimator = nil
        pageCurlCurrentHeaderSnapshot?.removeFromSuperview()
        pageCurlCurrentHeaderSnapshot = nil
        resetPageCurlToLive(animated: false)
        pageCurlTransitionActive = false
        pageCurlProgrammatic = false
        clearPreparedPageCurlControllers()
        chromeView.setPageHeaderHiddenForTransition(false)
        activeTurnGeneration = nil
        pendingPanTranslationX = 0
        pendingPanTranslationY = 0
        pendingPanVelocityX = 0
        pendingPanVelocityY = 0
        pendingPanDidEnd = false
        panHasStartedTurn = false
        isBoundaryResistanceTurn = false
        configurePageTurnInteraction()
    }

    private func startPageTurnFromPanIfNeeded() {
        guard !panHasStartedTurn else { return }
        let hasHorizontalTranslation = abs(pendingPanTranslationX) >= 4
            && abs(pendingPanTranslationX) > abs(pendingPanTranslationY) * 1.05
        let hasHorizontalFling = abs(pendingPanVelocityX) >= 80
            && abs(pendingPanVelocityX) > abs(pendingPanVelocityY) * 1.05
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
        guard isViewLoaded, view.window != nil, isCustomPageTurnCandidateEnabled,
              pageTurnStateMachine.state == .idle,
              pageTurnPrewarmTask == nil,
              let provider = model.pageSurfaceProvider,
              snapshotHostView.bounds.width > 0,
              snapshotHostView.bounds.height > 0,
              cachedCurrentSurface == nil
                || needsPageSurfacePrewarm(provider.adjacentSurfaceReadiness(direction: .forward))
                || needsPageSurfacePrewarm(provider.adjacentSurfaceReadiness(direction: .backward))
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
                if self.pageTurnSurfacesArePublished {
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

    private func needsPageSurfacePrewarm(_ readiness: NavigatorPageSurfaceReadiness) -> Bool {
        switch readiness {
        case .unknown, .failed:
            return true
        case .ready, .preparing, .unavailable:
            return false
        }
    }

    private func refreshPreparedPageTurnCacheIfAvailable() {
        guard pageTurnStateMachine.state == .idle,
              let provider = model.pageSurfaceProvider else { return }
        guard let currentSurface = provider.preparedCurrentSurface() else {
            cachedCurrentSurface = nil
            return
        }

        if cachedCurrentSurface?.identity != currentSurface.identity
            || cachedCurrentSurface?.generation != currentSurface.generation {
            clearPreparedPageCurlControllers()
        }
        cachedCurrentSurface = currentSurface
    }

    private func invalidatePageTurnCache() {
        guard pageTurnStateMachine.state != .committing else { return }
        pageTurnPrewarmRevision &+= 1
        pageTurnPrewarmTask?.cancel()
        pageTurnPrewarmTask = nil
        cachedCurrentSurface = nil
        clearPreparedPageCurlControllers()
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
            self.externalTakeoverTask = nil
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, self.isExternalTakeoverActive else { return }
                self.resolveExternalTakeover()
            }
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

    private func navigateWithoutCustomTransitionIfGestureCompleted(
        direction: PageDirection,
        provider: any PageSurfaceProvider
    ) {
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
        ) == .complete else { return }
        navigateWithoutCustomTransition(direction: direction, provider: provider)
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
