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
    private var close: (background: NagiGlassBackgroundView, button: UIButton)?
    private var activeInput: ActiveInput?
    private var previousParams: NagiSearchParams?
    private var pendingQuery = ""

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

        previousParams = params
        isActive = params.isActive

        if params.isActive {
            ensureCloseSurface(for: params)
            ensureActiveInput()
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
            transition.setCornerRadius(view: close.background, radius: closeRadius)
            transition.setScale(view: close.background, scale: 1.0)
            transition.setAlpha(view: close.background, alpha: params.isActive ? 1.0 : 0.0)
            close.background.isUserInteractionEnabled = params.isActive
            close.button.isUserInteractionEnabled = params.isActive
        }

        backgroundView.contentView.clipsToBounds = true
        close?.background.contentView.clipsToBounds = true
        layoutControls(for: params, transition: transition)
    }

    func finishTransition(params: NagiSearchParams, completed: Bool) {
        guard completed, !params.isActive else {
            return
        }

        close?.background.removeFromSuperview()
        close = nil

        if let activeInput {
            activeInput.container.removeFromSuperview()
            self.activeInput = nil
        }
    }

    private func ensureCloseSurface(for params: NagiSearchParams) {
        guard close == nil else { return }

        let background = NagiGlassBackgroundView(frame: .zero)
        let button = UIButton(type: .system)
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
        button.setImage(UIImage(systemName: "xmark"), for: .normal)
        button.tintColor = .secondaryLabel
        button.accessibilityLabel = "关闭搜索"
        button.addTarget(self, action: #selector(cancelSearch), for: .primaryActionTriggered)
        button.frame = CGRect(
            x: max(0, closeSize.width * 0.5 - 22),
            y: max(0, closeSize.height * 0.5 - 22),
            width: min(44, closeSize.width),
            height: min(44, closeSize.height)
        )
        background.contentView.addSubview(button)

        background.bounds = CGRect(origin: .zero, size: closeSize)
        background.center = CGPoint(
            x: params.closeFrame.midX,
            y: params.closeFrame.midY
        )
        background.transform = CGAffineTransform(scaleX: 0.001, y: 0.001)
        background.alpha = 1
        insertSubview(background, at: 0)
        close = (background: background, button: button)
    }

    private func ensureActiveInput() {
        guard activeInput == nil else {
            return
        }

        let container = UIView(frame: .zero)
        container.backgroundColor = .clear
        container.alpha = 0

        let textField = UITextField(frame: .zero)
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
        iconView.tintColor = active
            ? (UIColor(named: "AccentColor") ?? .tintColor)
            : .secondaryLabel
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
            transition.setFrame(
                view: input.container,
                frame: backgroundBounds
            )

            let fieldLeading: CGFloat = 36
            let fieldFrame = CGRect(
                x: fieldLeading,
                y: 0,
                width: max(0, backgroundBounds.width - 40),
                height: backgroundBounds.height
            )
            transition.setFrame(view: input.textField, frame: fieldFrame)

            let inputAlphaTransition: NagiTabTransition = transition.isImmediate
                ? .immediate
                : .easeInOut(duration: 0.25)
            inputAlphaTransition.setAlpha(
                view: input.container,
                alpha: params.isActive ? 1 : 0
            )

            input.container.isUserInteractionEnabled = params.isActive
            input.textField.isUserInteractionEnabled = params.isActive
        }

        if let close {
            if active {
                let closeBounds = CGRect(
                    origin: .zero,
                    size: params.closeFrame.size
                )
                transition.setFrame(
                    view: close.button,
                    frame: CGRect(
                        x: max(0, closeBounds.midX - 22),
                        y: max(0, closeBounds.midY - 22),
                        width: min(44, closeBounds.width),
                        height: min(44, closeBounds.height)
                    )
                )
            }
            close.button.isUserInteractionEnabled = active
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

    @objc private func cancelSearch() {
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
