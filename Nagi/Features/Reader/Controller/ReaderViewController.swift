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
    private var activePageSurface: PageSurface?
    private var pageTurnAnimator: PageTurnVisualAnimator?
    private var activeTurnGeneration: UInt?
    private var pendingPanTranslationX: CGFloat = 0
    private var pendingPanVelocityX: CGFloat = 0
    private var pendingPanDidEnd = false

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

        chromeView.onDismiss = { [weak self] in self?.onDismiss() }
        chromeView.onTableOfContents = { [weak self] in self?.onTableOfContents() }
        chromeView.onSettings = { [weak self] in self?.onSettings() }
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
        }
        if pageSurfacePreferencesChanged {
            cancelPageTurn(animated: false)
            model.pageSurfaceProvider?.invalidatePreparedSurfaces()
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

        let viewportChanged = !lastViewportBounds.isNull && lastViewportBounds != bounds
        lastViewportBounds = bounds
        lastViewportContentInsets = contentInsets
        lastViewportDisplayScale = displayScale
        if viewportChanged {
            cancelPageTurn(animated: false)
            model.pageSurfaceProvider?.invalidatePreparedSurfaces()
        }
        model.updateViewport(
            size: bounds.size,
            safeAreaInsets: contentInsets,
            displayScale: displayScale
        )
    }

    func dismantle() {
        NotificationCenter.default.removeObserver(self)
        cancelPageTurn(animated: false)
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
            chromeView.hideControlsForSwipe()
            pendingPanTranslationX = translation.x
            pendingPanVelocityX = velocity.x
            pendingPanDidEnd = false
            let edge: PageTurnEdge = velocity.x < 0 ? .right : .left
            let direction = PageTurnMetrics.pageDirection(
                for: edge,
                readingDirection: model.pageSurfaceProvider?.readingDirection ?? .leftToRight
            )
            startPageTurn(direction: direction, interactive: true)

        case .changed:
            pendingPanTranslationX = translation.x
            pendingPanVelocityX = velocity.x
            updateInteractivePageTurn()

        case .ended:
            pendingPanTranslationX = translation.x
            pendingPanVelocityX = velocity.x
            pendingPanDidEnd = true
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
        model.pageSurfaceProvider?.invalidatePreparedSurfaces()
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
    }

    private func startPageTurn(direction: PageDirection, interactive: Bool) {
        guard let provider = model.pageSurfaceProvider else { return }
        guard model.preferences.pageTransition != .scroll else {
            handleContentToggle()
            return
        }
        guard let generation = pageTurnStateMachine.prepare(direction: direction) else { return }

        activeTurnGeneration = generation
        pendingPanDidEnd = !interactive
        if !interactive {
            pendingPanTranslationX = 0
            pendingPanVelocityX = 0
            chromeView.hideControlsForSwipe()
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
                _ = pageTurnStateMachine.enterFallback(.surfaceUnavailable, generation: generation)
                _ = await provider.navigateWithoutCustomTransition(direction: direction)
                _ = pageTurnStateMachine.finish(generation: generation)
                activeTurnGeneration = nil
                return
            }

            guard !Task.isCancelled, pageTurnStateMachine.accepts(generation) else {
                provider.cancel(surface: surface)
                return
            }

            guard let currentContent = makeCurrentContentSnapshot() else {
                provider.cancel(surface: surface)
                _ = pageTurnStateMachine.enterFallback(.snapshotFailed, generation: generation)
                _ = await provider.navigateWithoutCustomTransition(direction: direction)
                _ = pageTurnStateMachine.finish(generation: generation)
                activeTurnGeneration = nil
                return
            }

            let currentComposite = makeCompositeSurface(content: currentContent)
            let targetComposite = makeCompositeSurface(content: surface.view)
            let readingDirection = provider.readingDirection
            let destinationX = PageTurnMetrics.completionTranslationX(
                containerWidth: snapshotHostView.bounds.width,
                direction: direction,
                readingDirection: readingDirection
            )
            let style: PageTurnVisualStyle = model.preferences.pageTransition == .fade ? .fade : .cover
            let animator = PageTurnVisualAnimator(
                style: style,
                hostView: snapshotHostView,
                currentView: currentComposite,
                targetView: targetComposite,
                completionTranslationX: destinationX,
                isDark: isDarkPageBackground
            )

            activePageSurface = surface
            pageTurnAnimator = animator
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

        let decision = PageTurnMetrics.decision(
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
                    self.activePageSurface = nil
                    _ = self.pageTurnStateMachine.finish(generation: generation)
                    self.cleanupPageTurn(cancelPreparedSurface: false)
                } else {
                    self.pageTurnStateMachine.invalidate()
                    self.cleanupPageTurn(cancelPreparedSurface: false)
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
        pageTurnAnimator?.remove()
        pageTurnAnimator = nil
        chromeView.setPageHeaderHiddenForTransition(false)
        activeTurnGeneration = nil
        pendingPanTranslationX = 0
        pendingPanVelocityX = 0
        pendingPanDidEnd = false
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
