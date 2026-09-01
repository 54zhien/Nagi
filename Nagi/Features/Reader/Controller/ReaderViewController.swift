//
//  ReaderViewController.swift
//  Nagi
//
//  UIKit host for the persistent Reader content, chrome, gestures and
//  transition cover.
//

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
    private var tapGestureRecognizer: UITapGestureRecognizer?

    private var latestStateRevision = 0
    private var latestTitle: String
    private var latestTitleColor: UIColor
    private var latestReaderBackground: UIColor
    private var latestTitleFontFamily: ReaderFontFamily
    private var latestShowsTitle: Bool
    private var latestReduceMotion: Bool
    private var latestCornerInsets: ReaderChromeCornerInsets
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
        view.addSubview(snapshotHostView)

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

        if model.handlesContentTap {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            contentController.view.addGestureRecognizer(tap)
            tapGestureRecognizer = tap
        }

        updateChrome()
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
        latestStateRevision = stateRevision
        latestTitle = title
        latestTitleColor = titleColor
        latestReaderBackground = readerBackground
        latestTitleFontFamily = titleFontFamily
        latestShowsTitle = showsTitle
        latestReduceMotion = reduceMotion
        latestCornerInsets = cornerInsets
        self.onDismiss = onDismiss
        self.onTableOfContents = onTableOfContents
        self.onSettings = onSettings

        guard isViewLoaded else { return }

        view.backgroundColor = readerBackground
        snapshotHostView.fallbackBackgroundColor = readerBackground
        updateChrome()
        if showsTitleChanged {
            view.setNeedsLayout()
        }
        if stateRevisionChanged {
            refreshContentIfNeeded()
        }
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

        lastViewportBounds = bounds
        lastViewportContentInsets = contentInsets
        lastViewportDisplayScale = displayScale
        model.updateViewport(
            size: bounds.size,
            safeAreaInsets: contentInsets,
            displayScale: displayScale
        )
    }

    func dismantle() {
        panGestureRecognizer?.removeTarget(nil, action: nil)
        tapGestureRecognizer?.removeTarget(nil, action: nil)
        panGestureRecognizer?.delegate = nil
        tapGestureRecognizer?.delegate = nil
        panGestureRecognizer = nil
        tapGestureRecognizer = nil

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
        guard gesture.state == .began else { return }

        chromeView.hideControlsForSwipe()
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }

        chromeView.noteInteraction()
        chromeView.toggleControls()
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
            || gestureRecognizer === tapGestureRecognizer
        let isOtherManagedGesture = otherGestureRecognizer === panGestureRecognizer
            || otherGestureRecognizer === tapGestureRecognizer
        guard isManagedGesture || isOtherManagedGesture,
              let contentView = contentHostController?.view else {
            return false
        }

        let peer = isManagedGesture ? otherGestureRecognizer : gestureRecognizer
        guard let peerView = peer.view else { return false }
        return peerView === contentView || peerView.isDescendant(of: contentView)
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
        if latestShowsTitle {
            contentInsets.top += CGFloat(ReaderLayoutMetrics.pageHeaderHeight)
        }
        return contentInsets
    }

    private func handleContentToggle() {
        chromeView.noteInteraction()
        chromeView.toggleControls()
    }

    private func makeContentRoot() -> ReaderContentHostView {
        ReaderContentHostView(
            content: model.makeContentView(
                onToggleControls: { [weak self] in self?.handleContentToggle() },
                onSwipeStart: { [weak self] in self?.chromeView.hideControlsForSwipe() }
            )
        )
    }

    private func makeContentSignature() -> ReaderContentSignature {
        ReaderContentSignature(
            hasDocument: model.document != nil,
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
    let hasDocument: Bool
    let errorMessage: String?

    func matches(_ other: ReaderContentSignature) -> Bool {
        hasDocument == other.hasDocument
            && errorMessage == other.errorMessage
    }
}
