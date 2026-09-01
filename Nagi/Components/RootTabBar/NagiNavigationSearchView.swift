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
    private static let normalSearchSymbolConfiguration = UIImage.SymbolConfiguration(
        pointSize: 22,
        weight: .medium
    )
    private static let activeSearchSymbolConfiguration = UIImage.SymbolConfiguration(
        pointSize: 18,
        weight: .regular
    )

    private let backgroundView: NagiGlassBackgroundView
    private let iconView: UIImageView
    private let placeholderLabel: UILabel
    private let textField: UITextField
    private let clearButton: UIButton
    private var close: (background: NagiGlassBackgroundView, button: UIButton)?
    private var previousParams: NagiSearchParams?
    private var isContentClippedDuringTransition = false

    var onActivate: (() -> Void)?
    var onCancel: (() -> Void)?
    var onQueryChanged: ((String) -> Void)?

    private var isActive = false

    override init(frame: CGRect) {
        self.backgroundView = NagiGlassBackgroundView(frame: .zero)
        self.iconView = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        self.placeholderLabel = UILabel(frame: .zero)
        self.textField = UITextField(frame: .zero)
        self.clearButton = UIButton(type: .system)
        self.close = nil
        super.init(frame: frame)

        clipsToBounds = false
        isUserInteractionEnabled = true

        backgroundView.isUserInteractionEnabled = true
        addSubview(backgroundView)

        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .center
        iconView.preferredSymbolConfiguration = Self.normalSearchSymbolConfiguration
        iconView.isUserInteractionEnabled = false
        backgroundView.contentView.addSubview(iconView)

        placeholderLabel.text = "搜索书名"
        placeholderLabel.textColor = .secondaryLabel
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.isUserInteractionEnabled = false
        backgroundView.contentView.addSubview(placeholderLabel)

        textField.delegate = self
        textField.backgroundColor = .clear
        textField.borderStyle = .none
        textField.clearButtonMode = .never
        textField.font = .preferredFont(forTextStyle: .body)
        textField.textColor = .label
        textField.tintColor = nagiAccentColor
        textField.returnKeyType = .search
        textField.autocorrectionType = .no
        textField.adjustsFontForContentSizeCategory = true
        textField.accessibilityLabel = "搜索书名"
        textField.addTarget(self, action: #selector(textDidChange), for: .editingChanged)
        backgroundView.contentView.addSubview(textField)

        clearButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        clearButton.tintColor = .secondaryLabel
        clearButton.accessibilityLabel = "清除搜索"
        clearButton.addTarget(self, action: #selector(clearQuery), for: .primaryActionTriggered)
        backgroundView.contentView.addSubview(clearButton)

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
            let closeSize = params.closeFrame.size
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
        let closeSize = params.closeFrame.size
        let closeRadius = min(closeSize.width, closeSize.height) * 0.5

        transition.setFrame(view: backgroundView, frame: params.backgroundFrame)
        backgroundView.applyGeometry(params: NagiGlassParams(
            size: backgroundSize,
            cornerRadius: backgroundRadius,
            isDark: params.isDark,
            tintColor: glassTintColor(isDark: params.isDark),
            isInteractive: true,
            isVisible: true,
            reduceTransparency: params.reduceTransparency
        ))

        if let close {
            transition.setBounds(
                view: close.background,
                bounds: CGRect(origin: .zero, size: closeSize)
            )
            transition.setPosition(
                view: close.background,
                position: CGPoint(x: params.closeFrame.midX, y: params.closeFrame.midY)
            )
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
                applyVisibility: false
            )
            transition.setCornerRadius(view: close.background, radius: closeRadius)
            transition.setScale(view: close.background, scale: params.isActive ? 1 : 0.001)
            transition.setAlpha(view: close.background, alpha: params.isActive ? 1 : 0)
            close.background.isUserInteractionEnabled = params.isActive
            close.button.isUserInteractionEnabled = params.isActive
        }

        backgroundView.contentView.clipsToBounds = isContentClippedDuringTransition
        close?.background.contentView.clipsToBounds = true
        layoutControls(for: params, transition: transition)
    }

    func finishTransition(params: NagiSearchParams, completed: Bool) {
        guard completed, !params.isActive else {
            return
        }
        close?.background.removeFromSuperview()
        close = nil
    }

    private func ensureCloseSurface(for params: NagiSearchParams) {
        guard close == nil else { return }

        let background = NagiGlassBackgroundView(frame: .zero)
        let button = UIButton(type: .system)
        background.isUserInteractionEnabled = true
        button.setImage(UIImage(systemName: "xmark"), for: .normal)
        button.tintColor = .secondaryLabel
        button.accessibilityLabel = "关闭搜索"
        button.addTarget(self, action: #selector(cancelSearch), for: .primaryActionTriggered)
        background.contentView.addSubview(button)
        addSubview(background)

        background.bounds = CGRect(origin: .zero, size: params.closeFrame.size)
        background.center = CGPoint(
            x: params.closeFrame.midX,
            y: params.closeFrame.midY
        )
        background.transform = CGAffineTransform(scaleX: 0.001, y: 0.001)
        background.alpha = 0
        close = (background: background, button: button)
    }

    func setContentClipping(_ clipped: Bool) {
        isContentClippedDuringTransition = clipped
        backgroundView.contentView.clipsToBounds = clipped
    }

    func setQuery(_ query: String) {
        guard textField.text != query else {
            return
        }
        textField.text = query
        updatePlaceholderVisibility()
    }

    @discardableResult
    func becomeSearchFirstResponder() -> Bool {
        textField.becomeFirstResponder()
    }

    func resignSearchFirstResponder() {
        textField.resignFirstResponder()
    }

    private func layoutControls(for params: NagiSearchParams, transition: NagiTabTransition) {
        let backgroundBounds = backgroundView.bounds
        let active = params.isActive

        let iconSize: CGFloat = active ? 18 : 22
        let iconX = active ? 12 : backgroundBounds.midX - iconSize * 0.5
        let iconY = backgroundBounds.midY - iconSize * 0.5
        iconView.preferredSymbolConfiguration = active
            ? Self.activeSearchSymbolConfiguration
            : Self.normalSearchSymbolConfiguration
        transition.setFrame(
            view: iconView,
            frame: CGRect(x: iconX, y: iconY, width: iconSize, height: iconSize)
        )
        iconView.tintColor = active ? nagiAccentColor : .secondaryLabel
        transition.setAlpha(view: iconView, alpha: 1)

        let fieldLeading: CGFloat = active ? 40 : 0
        let trailingControls: CGFloat = active ? 48 : 0
        let fieldWidth = max(0, backgroundBounds.width - fieldLeading - trailingControls)
        let fieldFrame = CGRect(
            x: fieldLeading,
            y: 0,
            width: fieldWidth,
            height: backgroundBounds.height
        )
        transition.setFrame(view: placeholderLabel, frame: fieldFrame)
        transition.setFrame(view: textField, frame: fieldFrame)
        let clearFrame = active
            ? CGRect(
                x: max(0, backgroundBounds.width - 48),
                y: max(0, backgroundBounds.midY - 22),
                width: 44,
                height: 44
            )
            : .zero
        transition.setFrame(view: clearButton, frame: clearFrame)

        if let close {
            let closeBounds = close.background.bounds
            transition.setFrame(
                view: close.button,
                frame: CGRect(
                    x: max(0, closeBounds.midX - 22),
                    y: max(0, closeBounds.midY - 22),
                    width: min(44, closeBounds.width),
                    height: min(44, closeBounds.height)
                )
            )
            close.button.isUserInteractionEnabled = active
        }

        transition.setAlpha(view: placeholderLabel, alpha: active ? 1 : 0)
        transition.setAlpha(view: textField, alpha: active ? 1 : 0)
        transition.setAlpha(
            view: clearButton,
            alpha: active && !(textField.text ?? "").isEmpty ? 1 : 0
        )

        textField.isUserInteractionEnabled = active
        clearButton.isUserInteractionEnabled = active
        updatePlaceholderVisibility(using: transition)
    }

    private func glassTintColor(isDark: Bool) -> UIColor {
        isDark
            ? UIColor.white.withAlphaComponent(0.025)
            : UIColor.white.withAlphaComponent(0.1)
    }

    private var nagiAccentColor: UIColor {
        UIColor(named: "AccentColor") ?? .tintColor
    }

    private func updatePlaceholderVisibility() {
        updatePlaceholderVisibility(using: .immediate)
    }

    private func updatePlaceholderVisibility(using transition: NagiTabTransition) {
        guard isActive else {
            transition.setAlpha(view: placeholderLabel, alpha: 0)
            transition.setAlpha(view: clearButton, alpha: 0)
            return
        }
        let isEmpty = textField.text?.isEmpty ?? true
        transition.setAlpha(view: placeholderLabel, alpha: isEmpty ? 1 : 0)
        transition.setAlpha(view: clearButton, alpha: isEmpty ? 0 : 1)
    }

    @objc private func backgroundTapped() {
        if isActive {
            textField.becomeFirstResponder()
        } else {
            onActivate?()
        }
    }

    @objc private func textDidChange() {
        updatePlaceholderVisibility()
        onQueryChanged?(textField.text ?? "")
    }

    @objc private func clearQuery() {
        textField.text = ""
        updatePlaceholderVisibility()
        onQueryChanged?("")
        textField.becomeFirstResponder()
    }

    @objc private func cancelSearch() {
        onCancel?()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var candidate = touch.view
        while let view = candidate {
            if view is UIControl || view === textField {
                return false
            }
            candidate = view.superview
        }
        return true
    }
}
