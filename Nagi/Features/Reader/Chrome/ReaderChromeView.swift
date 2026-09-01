//
//  ReaderChromeView.swift
//  Nagi
//
//  Persistent UIKit Reader Chrome.  Its controls are created once per reader
//  session and only their state/layer properties change afterwards.
//

import UIKit

@MainActor
final class ReaderChromeView: UIView {
    var onDismiss: (() -> Void)?
    var onTableOfContents: (() -> Void)?
    var onSettings: (() -> Void)?

    private let titleLabel = UILabel()
    private let exitControl = GlassControlView()
    private let tableOfContentsControl = GlassControlView()
    private let settingsControl = GlassControlView()
    private let exitImage: UIImage?
    private let tableOfContentsImage: UIImage?
    private let settingsImage: UIImage?

    private let exitContainer = UIView()
    private lazy var animator = ReaderChromeAnimator(targets: [
        exitContainer,
        tableOfContentsControl,
        settingsControl
    ])

    private var autoHideTask: Task<Void, Never>?
    private var interactionRevision = 0
    private var reduceMotion = false
    private(set) var isControlsVisible = true
    private var containerCornerInsets: ReaderChromeCornerInsets?
    private var currentControlTint: UIColor?
    private var currentControlReduceMotion = false
    private var accessibilityActionName: String?

    private var cachedBounds = CGRect.null
    private var cachedSafeAreaInsets = UIEdgeInsets.zero
    private var cachedDisplayScale: CGFloat = 0
    private var cachedCornerInsets: ReaderChromeCornerInsets?

    init() {
        let symbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: ReaderChromeMetrics.iconPointSize,
            weight: .semibold
        )
        exitImage = UIImage(systemName: "xmark", withConfiguration: symbolConfiguration)
        tableOfContentsImage = UIImage(
            systemName: "list.bullet",
            withConfiguration: symbolConfiguration
        )
        settingsImage = UIImage(
            systemName: "xmark.triangle.circle.square",
            withConfiguration: symbolConfiguration
        )
        super.init(frame: .zero)

        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = false

        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isUserInteractionEnabled = false
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.backgroundColor = .clear
        titleLabel.isOpaque = false

        configureContainer(exitContainer, with: exitControl)

        addSubview(titleLabel)
        addSubview(exitContainer)
        addSubview(tableOfContentsControl)
        addSubview(settingsControl)

        exitControl.addTarget(self, action: #selector(didTapExit), for: .primaryActionTriggered)
        tableOfContentsControl.addTarget(
            self,
            action: #selector(didTapTableOfContents),
            for: .primaryActionTriggered
        )
        settingsControl.addTarget(
            self,
            action: #selector(didTapSettings),
            for: .primaryActionTriggered
        )

        exitControl.update(
            image: exitImage,
            accessibilityLabel: "退出阅读器",
            tintColor: .label,
            isEnabled: true,
            reduceMotion: false
        )
        tableOfContentsControl.update(
            image: tableOfContentsImage,
            accessibilityLabel: "目录",
            tintColor: .label,
            isEnabled: true,
            reduceMotion: false
        )
        settingsControl.update(
            image: settingsImage,
            accessibilityLabel: "主题与排版",
            tintColor: .label,
            isEnabled: true,
            reduceMotion: false
        )
        setControlsVisible(true, animated: false, reduceMotion: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        title: String,
        titleColor: UIColor,
        fontFamily: ReaderFontFamily,
        showsTitle: Bool,
        reduceMotion: Bool,
        cornerInsets: ReaderChromeCornerInsets?
    ) {
        if titleLabel.text != title {
            titleLabel.text = title
        }
        let titleFont = fontFamily.uiFont(ofSize: 15)
        if titleLabel.font?.isEqual(titleFont) != true {
            titleLabel.font = titleFont
        }

        let resolvedTitleColor = titleColor.withAlphaComponent(0.55)
        if titleLabel.textColor?.isEqual(resolvedTitleColor) != true {
            titleLabel.textColor = resolvedTitleColor
        }

        titleLabel.isHidden = !showsTitle
        titleLabel.isAccessibilityElement = showsTitle
        titleLabel.accessibilityElementsHidden = !showsTitle
        titleLabel.accessibilityTraits = showsTitle ? .header : []
        titleLabel.accessibilityLabel = showsTitle ? "页眉书名：\(title)" : nil

        if containerCornerInsets != cornerInsets {
            containerCornerInsets = cornerInsets
            setNeedsLayout()
        }

        self.reduceMotion = reduceMotion
        let controlAppearanceChanged = currentControlTint?.isEqual(titleColor) != true
            || currentControlReduceMotion != reduceMotion
        if controlAppearanceChanged {
            exitControl.update(
                image: exitImage,
                accessibilityLabel: "退出阅读器",
                tintColor: titleColor,
                isEnabled: true,
                reduceMotion: reduceMotion
            )
            tableOfContentsControl.update(
                image: tableOfContentsImage,
                accessibilityLabel: "目录",
                tintColor: titleColor,
                isEnabled: true,
                reduceMotion: reduceMotion
            )
            settingsControl.update(
                image: settingsImage,
                accessibilityLabel: "主题与排版",
                tintColor: titleColor,
                isEnabled: true,
                reduceMotion: reduceMotion
            )
            currentControlTint = titleColor
            currentControlReduceMotion = reduceMotion
        }
        updateAccessibilityActions()
    }

    func toggleControls() {
        setControlsVisible(
            !isControlsVisible,
            animated: true,
            reduceMotion: reduceMotion
        )
    }

    func noteInteraction() {
        interactionRevision &+= 1
        scheduleAutoHide()
    }

    func hideControlsForSwipe() {
        guard isControlsVisible else { return }
        noteInteraction()
        setControlsVisible(
            false,
            animated: true,
            reduceMotion: reduceMotion
        )
    }

    func setControlsVisible(
        _ visible: Bool,
        animated: Bool,
        reduceMotion: Bool
    ) {
        self.reduceMotion = reduceMotion
        let visibilityChanged = isControlsVisible != visible
        isControlsVisible = visible
        autoHideTask?.cancel()
        autoHideTask = nil

        exitControl.isUserInteractionEnabled = visible
        tableOfContentsControl.isUserInteractionEnabled = visible
        settingsControl.isUserInteractionEnabled = visible
        exitContainer.isUserInteractionEnabled = visible
        exitContainer.accessibilityElementsHidden = !visible
        tableOfContentsControl.accessibilityElementsHidden = !visible
        settingsControl.accessibilityElementsHidden = !visible

        guard visibilityChanged else {
            updateAccessibilityActions()
            if visible {
                scheduleAutoHide()
            }
            return
        }

        if visible {
            exitContainer.isHidden = false
            tableOfContentsControl.isHidden = false
            settingsControl.isHidden = false
        }
        animator.setVisible(
            visible,
            animated: animated,
            reduceMotion: reduceMotion
        ) { [weak self] in
            guard let self, !visible, !self.isControlsVisible else { return }
            self.exitContainer.isHidden = true
            self.tableOfContentsControl.isHidden = true
            self.settingsControl.isHidden = true
        }
        updateAccessibilityActions()

        if visible {
            scheduleAutoHide()
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, alpha > 0.01 else { return nil }
        let hitView = super.hitTest(point, with: event)
        return hitView === self ? nil : hitView
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let currentBounds = bounds
        let currentSafeAreaInsets = safeAreaInsets
        let currentDisplayScale = window?.screen.scale ?? UIScreen.main.scale
        guard currentBounds != cachedBounds
            || currentSafeAreaInsets != cachedSafeAreaInsets
            || currentDisplayScale != cachedDisplayScale
            || containerCornerInsets != cachedCornerInsets else {
            return
        }

        cachedBounds = currentBounds
        cachedSafeAreaInsets = currentSafeAreaInsets
        cachedDisplayScale = currentDisplayScale
        cachedCornerInsets = containerCornerInsets

        let controlDiameter = ReaderChromeMetrics.diameter
        let topY = min(
            max(0, currentSafeAreaInsets.top + ReaderChromeMetrics.exitTopInset),
            max(0, currentBounds.height - controlDiameter)
        )
        let exitFrame = CGRect(
            x: currentBounds.maxX - ReaderChromeMetrics.exitTrailingInset - controlDiameter,
            y: topY,
            width: controlDiameter,
            height: controlDiameter
        )
        exitContainer.frame = exitFrame
        exitControl.frame = exitContainer.bounds

        let headerHeight = CGFloat(ReaderLayoutMetrics.pageHeaderHeight)
        let headerHorizontalInset = ReaderChromeMetrics.headerHorizontalInset
        titleLabel.frame = CGRect(
            x: headerHorizontalInset,
            y: min(currentSafeAreaInsets.top, max(0, currentBounds.height - headerHeight)),
            width: max(0, currentBounds.width - headerHorizontalInset * 2),
            height: headerHeight
        )

        let radius = controlDiameter / 2
        let resolvedCornerInsets = containerCornerInsets ?? ReaderChromeCornerInsets(
            bottomLeading: CGSize(
                width: currentSafeAreaInsets.left,
                height: currentSafeAreaInsets.bottom
            ),
            bottomTrailing: CGSize(
                width: currentSafeAreaInsets.right,
                height: currentSafeAreaInsets.bottom
            )
        )
        let leadingDistance = cornerCenterDistance(
            resolvedCornerInsets.bottomLeading.width,
            maximum: max(radius, currentBounds.width - radius),
            radius: radius
        )
        let trailingDistance = cornerCenterDistance(
            resolvedCornerInsets.bottomTrailing.width,
            maximum: max(radius, currentBounds.width - radius),
            radius: radius
        )
        let leadingBottomDistance = cornerCenterDistance(
            resolvedCornerInsets.bottomLeading.height,
            maximum: max(radius, currentBounds.height - radius),
            radius: radius
        )
        let trailingBottomDistance = cornerCenterDistance(
            resolvedCornerInsets.bottomTrailing.height,
            maximum: max(radius, currentBounds.height - radius),
            radius: radius
        )

        let leadingCenter = CGPoint(
            x: leadingDistance,
            y: currentBounds.height - leadingBottomDistance
        )
        let trailingCenter = CGPoint(
            x: currentBounds.width - trailingDistance,
            y: currentBounds.height - trailingBottomDistance
        )
        tableOfContentsControl.frame = controlFrame(center: leadingCenter, in: currentBounds)
        settingsControl.frame = controlFrame(center: trailingCenter, in: currentBounds)
    }

    private func configureContainer(_ container: UIView, with control: UIView) {
        container.backgroundColor = .clear
        container.isOpaque = false
        container.addSubview(control)
    }

    private func cornerCenterDistance(
        _ measuredInset: CGFloat,
        maximum: CGFloat,
        radius: CGFloat
    ) -> CGFloat {
        let fallback = radius
        return min(max(radius, measuredInset > 0 ? measuredInset : fallback), maximum)
    }

    private func controlFrame(center: CGPoint, in bounds: CGRect) -> CGRect {
        let diameter = ReaderChromeMetrics.diameter
        let x = min(max(0, center.x - diameter / 2), max(0, bounds.width - diameter))
        let y = min(max(0, center.y - diameter / 2), max(0, bounds.height - diameter))
        return CGRect(x: x, y: y, width: diameter, height: diameter)
    }

    private func scheduleAutoHide() {
        guard isControlsVisible else { return }

        autoHideTask?.cancel()
        let revision = interactionRevision
        autoHideTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: ReaderChromeMetrics.autoHideNanoseconds)
            } catch {
                return
            }

            guard let self,
                  !Task.isCancelled,
                  self.interactionRevision == revision,
                  self.isControlsVisible else { return }
            self.setControlsVisible(
                false,
                animated: true,
                reduceMotion: self.reduceMotion
            )
        }
    }

    private func updateAccessibilityActions() {
        let actionName = isControlsVisible ? "隐藏阅读控件" : "显示阅读控件"
        guard accessibilityActionName != actionName else { return }

        accessibilityActionName = actionName
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(
                name: actionName,
                target: self,
                selector: #selector(accessibilityToggleControls(_:))
            )
        ]
    }

    @objc private func didTapExit() {
        noteInteraction()
        onDismiss?()
    }

    @objc private func didTapTableOfContents() {
        noteInteraction()
        onTableOfContents?()
    }

    @objc private func didTapSettings() {
        noteInteraction()
        onSettings?()
    }

    @objc private func accessibilityToggleControls(
        _ action: UIAccessibilityCustomAction
    ) -> Bool {
        _ = action
        toggleControls()
        return true
    }
}

private enum ReaderChromeMetrics {
    static let diameter: CGFloat = 48
    static let iconPointSize: CGFloat = 20
    static let headerHorizontalInset: CGFloat = 72
    static let exitTopInset: CGFloat = 0
    static let exitTrailingInset: CGFloat = 24
    static let autoHideNanoseconds: UInt64 = 7_000_000_000
}
