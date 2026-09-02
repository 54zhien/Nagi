//
//  NagiNavigationSearchView.swift
//  Nagi
//
//  持久化的搜索 surface。外部 frame 由 NagiTabBarView 统一拥有，
//  本 view 只管理两个 Glass surface 内部的内容和控件 geometry。
//

import UIKit

struct NagiSearchParams: Equatable {
    var containerSize: CGSize
    var backgroundFrame: CGRect
    var closeFrame: CGRect
    var isActive: Bool
    var isExpandedStandaloneBar: Bool
    var isDark: Bool
    var reduceTransparency: Bool
}

final class NagiNavigationSearchView: UIView, UITextFieldDelegate, UIGestureRecognizerDelegate {
    private static let searchSymbolConfiguration = UIImage.SymbolConfiguration(
        pointSize: 22,
        weight: .medium
    )

    private struct ActiveInput {
        let container: UIView
        let textField: UITextField
    }

    private let backgroundView: NagiGlassBackgroundView
    private let iconView: UIImageView
    private let placeholderLabel: UILabel
    private var close: (background: NagiGlassBackgroundView, iconView: UIImageView)?
    private var closingClose: (background: NagiGlassBackgroundView, iconView: UIImageView)?
    private var activeInput: ActiveInput?
    private var previousParams: NagiSearchParams?
    private var pendingQuery = ""
    private var inputGeneration = 0
    private var closeGeneration = 0

    var onActivate: (() -> Void)?
    var onCancel: (() -> Void)?
    var onQueryChanged: ((String) -> Void)?

    private var isActive = false

    override init(frame: CGRect) {
        self.backgroundView = NagiGlassBackgroundView(frame: .zero)
        self.iconView = UIImageView(
            image: UIImage(
                systemName: "magnifyingglass",
                withConfiguration: Self.searchSymbolConfiguration
            )
        )
        self.placeholderLabel = UILabel(frame: .zero)
        self.close = nil
        self.closingClose = nil
        self.activeInput = nil
        super.init(frame: frame)

        clipsToBounds = false
        isUserInteractionEnabled = true

        backgroundView.isUserInteractionEnabled = true
        backgroundView.contentView.clipsToBounds = true
        addSubview(backgroundView)

        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .scaleToFill
        iconView.isUserInteractionEnabled = false
        backgroundView.contentView.addSubview(iconView)

        placeholderLabel.text = "搜索书名"
        placeholderLabel.textColor = .secondaryLabel
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.isUserInteractionEnabled = false
        backgroundView.contentView.addSubview(placeholderLabel)

        let recognizer = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        addGestureRecognizer(recognizer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @discardableResult
    func prepare(params: NagiSearchParams) -> Bool {
        guard params != previousParams else {
            return false
        }

        let previousIsActive = isActive
        previousParams = params
        isActive = params.isActive

        if previousIsActive != params.isActive {
            inputGeneration += 1
            closeGeneration += 1
        }

        if params.isActive {
            ensureCloseSurface(for: params)
            ensureActiveInput(for: params)
        }

        let backgroundSize = params.backgroundFrame.size
        let backgroundRadius = min(backgroundSize.width, backgroundSize.height) * 0.5
        let backgroundChanged = backgroundView.prepare(params: NagiGlassParams(
            size: backgroundSize,
            cornerRadius: backgroundRadius,
            isDark: params.isDark,
            tintColor: glassTintColor(isDark: params.isDark),
            isInteractive: true,
            isVisible: true,
            reduceTransparency: params.reduceTransparency
        ))

        let closeChanged: Bool
        if let close {
            let closeSize = params.isActive
                ? params.closeFrame.size
                : close.background.bounds.size
            let closeRadius = min(closeSize.width, closeSize.height) * 0.5
            closeChanged = close.background.prepare(params: NagiGlassParams(
                size: closeSize,
                cornerRadius: closeRadius,
                isDark: params.isDark,
                tintColor: glassTintColor(isDark: params.isDark),
                isInteractive: true,
                isVisible: params.isActive,
                reduceTransparency: params.reduceTransparency
            ))
        } else {
            closeChanged = false
        }

        return backgroundChanged || closeChanged
    }

    func applyInternalGeometry(
        params: NagiSearchParams,
        transition: NagiTabTransition
    ) {
        let backgroundSize = params.backgroundFrame.size
        let backgroundRadius = min(backgroundSize.width, backgroundSize.height) * 0.5

        transition.setFrame(view: backgroundView, frame: params.backgroundFrame)
        backgroundView.applyGeometry(
            params: NagiGlassParams(
                size: backgroundSize,
                cornerRadius: backgroundRadius,
                isDark: params.isDark,
                tintColor: glassTintColor(isDark: params.isDark),
                isInteractive: true,
                isVisible: true,
                reduceTransparency: params.reduceTransparency
            ),
            transition: transition
        )

        if let close {
            if !active {
                // Detach the logical surface now so a rapid re-entry can
                // create a fresh Close Glass while this one fades out.
                self.close = nil
                closingClose = close
            }
            let closeSize = params.isActive
                ? params.closeFrame.size
                : close.background.bounds.size
            let closeRadius = min(closeSize.width, closeSize.height) * 0.5
            let closePosition = params.isActive
                ? CGPoint(x: params.closeFrame.midX, y: params.closeFrame.midY)
                : close.background.center
            transition.setBounds(
                view: close.background,
                bounds: CGRect(origin: .zero, size: closeSize)
            )
            transition.setPosition(view: close.background, position: closePosition)
            close.background.applyGeometry(
                params: NagiGlassParams(
                    size: closeSize,
                    cornerRadius: closeRadius,
                    isDark: params.isDark,
                    tintColor: glassTintColor(isDark: params.isDark),
                    isInteractive: true,
                    isVisible: params.isActive,
                    reduceTransparency: params.reduceTransparency
                ),
                transition: transition,
                applyVisibility: false
            )
            if params.isActive {
                transition.setCornerRadius(
                    view: close.background,
                    radius: closeRadius
                )
                transition.setScale(view: close.background, scale: 1.0)
            }
            let closeAlphaTransition: NagiTabTransition = transition.isImmediate
                ? .immediate
                : .easeInOut(duration: 0.25)
            let generation = closeGeneration
            closeAlphaTransition.setAlpha(
                view: close.background,
                alpha: params.isActive ? 1.0 : 0.0,
                completion: params.isActive
                    ? nil
                    : { [weak self, weak closeBackground = close.background] completed in
                        guard completed, let closeBackground else {
                            return
                        }

                        closeBackground.removeFromSuperview()
                        guard let self,
                              !self.isActive,
                              self.closeGeneration == generation,
                              self.closingClose?.background === closeBackground else {
                            return
                        }

                        self.closingClose = nil
                    }
            )
            close.background.isUserInteractionEnabled = params.isActive
        }

        backgroundView.contentView.clipsToBounds = true
        close?.background.contentView.clipsToBounds = true
        layoutControls(for: params, transition: transition)
    }

    private func ensureCloseSurface(for params: NagiSearchParams) {
        guard close == nil else { return }

        let background = NagiGlassBackgroundView(frame: .zero)
        let iconView = UIImageView(image: Self.makeCloseImage())
        let closeSize = params.closeFrame.size
        let closeRadius = min(closeSize.width, closeSize.height) * 0.5
        let closeGlassParams = NagiGlassParams(
            size: closeSize,
            cornerRadius: closeRadius,
            isDark: params.isDark,
            tintColor: glassTintColor(isDark: params.isDark),
            isInteractive: true,
            isVisible: true,
            reduceTransparency: params.reduceTransparency
        )

        // Fully initialize the native Glass before the surface is inserted
        // into the active search hierarchy. This gives the first animated
        // frame a real 48pt effect view, content view, corner radius and luma
        // range instead of starting from the zero-sized initializer state.
        _ = background.prepare(params: closeGlassParams)
        background.applyGeometry(
            params: closeGlassParams,
            transition: .immediate,
            applyVisibility: false
        )

        background.isUserInteractionEnabled = true
        background.contentView.clipsToBounds = true
        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .center
        iconView.isUserInteractionEnabled = false
        iconView.accessibilityLabel = "关闭搜索"

        let recognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(cancelSearch(_:))
        )
        recognizer.cancelsTouchesInView = false
        background.contentView.addGestureRecognizer(recognizer)
        background.contentView.addSubview(iconView)

        background.bounds = CGRect(origin: .zero, size: closeSize)
        background.center = CGPoint(
            x: params.closeFrame.midX,
            y: params.closeFrame.midY
        )
        background.transform = CGAffineTransform(scaleX: 0.001, y: 0.001)
        background.alpha = 1
        insertSubview(background, at: 0)
        if let image = iconView.image {
            iconView.frame = CGRect(
                x: (closeSize.width - image.size.width) * 0.5,
                y: (closeSize.height - image.size.height) * 0.5,
                width: image.size.width,
                height: image.size.height
            )
        }
        close = (background: background, iconView: iconView)
    }

    private static func makeCloseImage() -> UIImage? {
        let size = CGSize(width: 40, height: 40)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { rendererContext in
            let context = rendererContext.cgContext
            context.setLineWidth(2)
            context.setLineCap(.round)
            context.setStrokeColor(UIColor.white.cgColor)
            context.move(to: CGPoint(x: 12, y: 12))
            context.addLine(to: CGPoint(x: 28, y: 28))
            context.move(to: CGPoint(x: 28, y: 12))
            context.addLine(to: CGPoint(x: 12, y: 28))
            context.strokePath()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    private func ensureActiveInput(for params: NagiSearchParams) {
        if let activeInput {
            setInputGeometry(
                activeInput,
                backgroundSize: params.backgroundFrame.size
            )
            return
        }

        let finalBackgroundBounds = CGRect(
            origin: .zero,
            size: params.backgroundFrame.size
        )
        let container = UIView(frame: finalBackgroundBounds)
        container.backgroundColor = .clear
        container.alpha = 0

        let textField = UITextField(
            frame: CGRect(
                x: 36,
                y: 0,
                width: max(0, finalBackgroundBounds.width - 40),
                height: finalBackgroundBounds.height
            )
        )
        textField.delegate = self
        textField.backgroundColor = .clear
        textField.borderStyle = .none
        textField.clearButtonMode = .whileEditing
        textField.font = .preferredFont(forTextStyle: .body)
        textField.textColor = .label
        textField.tintColor = UIColor(named: "AccentColor") ?? .tintColor
        textField.placeholder = "搜索书名"
        textField.returnKeyType = .search
        textField.autocorrectionType = .no
        textField.adjustsFontForContentSizeCategory = true
        textField.accessibilityLabel = "搜索书名"
        textField.text = pendingQuery
        textField.addTarget(
            self,
            action: #selector(textDidChange(_:)),
            for: .editingChanged
        )

        container.addSubview(textField)
        backgroundView.contentView.addSubview(container)

        activeInput = ActiveInput(
            container: container,
            textField: textField
        )
    }

    private func setInputGeometry(
        _ input: ActiveInput,
        backgroundSize: CGSize
    ) {
        let backgroundBounds = CGRect(origin: .zero, size: backgroundSize)
        input.container.frame = backgroundBounds
        input.textField.frame = CGRect(
            x: 36,
            y: 0,
            width: max(0, backgroundBounds.width - 40),
            height: backgroundBounds.height
        )
    }

    func setQuery(_ query: String) {
        pendingQuery = query

        guard let textField = activeInput?.textField,
              textField.text != query else {
            return
        }

        textField.text = query
    }

    @discardableResult
    func becomeSearchFirstResponder() -> Bool {
        activeInput?.textField.becomeFirstResponder() ?? false
    }

    func resignSearchFirstResponder() {
        activeInput?.textField.resignFirstResponder()
    }

    private func layoutControls(for params: NagiSearchParams, transition: NagiTabTransition) {
        let backgroundBounds = CGRect(
            origin: .zero,
            size: params.backgroundFrame.size
        )
        let active = params.isActive

        let baseIconSize = iconView.image?.size ?? CGSize(width: 22, height: 22)
        let targetIconSize: CGSize

        if active {
            let iconFraction: CGFloat = 0.8
            targetIconSize = CGSize(
                width: baseIconSize.width * iconFraction,
                height: baseIconSize.height * iconFraction
            )
        } else {
            targetIconSize = baseIconSize
        }

        let targetIconFrame: CGRect

        if active {
            targetIconFrame = CGRect(
                x: 12,
                y: floor((backgroundBounds.height - targetIconSize.height) * 0.5),
                width: targetIconSize.width,
                height: targetIconSize.height
            )
        } else {
            targetIconFrame = CGRect(
                x: floor((backgroundBounds.width - targetIconSize.width) * 0.5),
                y: floor((backgroundBounds.height - targetIconSize.height) * 0.5),
                width: targetIconSize.width,
                height: targetIconSize.height
            )
        }

        transition.setPosition(
            view: iconView,
            position: CGPoint(
                x: targetIconFrame.midX,
                y: targetIconFrame.midY
            )
        )
        transition.setBounds(
            view: iconView,
            bounds: CGRect(
                origin: .zero,
                size: targetIconFrame.size
            )
        )
        transition.setTintColor(
            view: iconView,
            color: active
                ? (UIColor(named: "AccentColor") ?? .tintColor)
                : .secondaryLabel
        )
        transition.setAlpha(view: iconView, alpha: 1)

        let placeholderLeading: CGFloat = params.isExpandedStandaloneBar && !active ? 40 : 0
        let placeholderFrame = CGRect(
            x: placeholderLeading,
            y: 0,
            width: max(0, backgroundBounds.width - placeholderLeading),
            height: backgroundBounds.height
        )
        transition.setFrame(view: placeholderLabel, frame: placeholderFrame)
        transition.setAlpha(
            view: placeholderLabel,
            alpha: !active && params.isExpandedStandaloneBar ? 1 : 0
        )

        if let input = activeInput {
            if active {
                setInputGeometry(
                    input,
                    backgroundSize: backgroundBounds.size
                )
            }

            let inputAlphaTransition: NagiTabTransition = transition.isImmediate
                ? .immediate
                : .easeInOut(duration: 0.25)
            let generation = inputGeneration
            inputAlphaTransition.setAlpha(
                view: input.container,
                alpha: active ? 1 : 0,
                completion: active
                    ? nil
                    : { [weak self, weak container = input.container] completed in
                        guard completed,
                              let self,
                              !self.isActive,
                              self.inputGeneration == generation else {
                            return
                        }

                        container?.removeFromSuperview()
                        if self.activeInput?.container === container {
                            self.activeInput = nil
                        }
                    }
            )

            input.container.isUserInteractionEnabled = active
            input.textField.isUserInteractionEnabled = active
        }

        if let close {
            if active {
                let closeBounds = CGRect(origin: .zero, size: params.closeFrame.size)
                transition.setFrame(
                    view: close.iconView,
                    frame: CGRect(
                        x: (closeBounds.width - close.iconView.bounds.width) * 0.5,
                        y: (closeBounds.height - close.iconView.bounds.height) * 0.5,
                        width: close.iconView.bounds.width,
                        height: close.iconView.bounds.height
                    )
                )
            }
            close.iconView.isUserInteractionEnabled = false
        }
    }

    private func glassTintColor(isDark: Bool) -> UIColor {
        isDark
            ? UIColor.white.withAlphaComponent(0.025)
            : UIColor.white.withAlphaComponent(0.1)
    }

    @objc private func backgroundTapped() {
        if isActive {
            activeInput?.textField.becomeFirstResponder()
        } else {
            onActivate?()
        }
    }

    @objc private func textDidChange(_ sender: UITextField) {
        pendingQuery = sender.text ?? ""
        onQueryChanged?(pendingQuery)
    }

    @objc private func cancelSearch(_ recognizer: UITapGestureRecognizer) {
        onCancel?()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    func textFieldShouldClear(_ textField: UITextField) -> Bool {
        pendingQuery = ""
        onQueryChanged?("")
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var candidate = touch.view
        while let view = candidate {
            if view is UIControl {
                return false
            }
            candidate = view.superview
        }
        return true
    }
}
