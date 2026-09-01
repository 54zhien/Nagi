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
    private let backgroundView: NagiGlassBackgroundView
    private let closeBackgroundView: NagiGlassBackgroundView
    private let iconView: UIImageView
    private let placeholderLabel: UILabel
    private let textField: UITextField
    private let clearButton: UIButton
    private let closeButton: UIButton
    private var previousParams: NagiSearchParams?
    private var isContentClippedDuringTransition = false

    var onActivate: (() -> Void)?
    var onCancel: (() -> Void)?
    var onQueryChanged: ((String) -> Void)?

    private var isActive = false

    override init(frame: CGRect) {
        self.backgroundView = NagiGlassBackgroundView(frame: .zero)
        self.closeBackgroundView = NagiGlassBackgroundView(frame: .zero)
        self.iconView = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        self.placeholderLabel = UILabel(frame: .zero)
        self.textField = UITextField(frame: .zero)
        self.clearButton = UIButton(type: .system)
        self.closeButton = UIButton(type: .system)
        super.init(frame: frame)

        clipsToBounds = false
        isUserInteractionEnabled = true

        backgroundView.isUserInteractionEnabled = true
        closeBackgroundView.isUserInteractionEnabled = true
        addSubview(backgroundView)
        addSubview(closeBackgroundView)

        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
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
        textField.tintColor = .tintColor
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

        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .secondaryLabel
        closeButton.accessibilityLabel = "关闭搜索"
        closeButton.addTarget(self, action: #selector(cancelSearch), for: .primaryActionTriggered)
        closeBackgroundView.contentView.addSubview(closeButton)

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

        let backgroundSize = params.backgroundFrame.size
        let backgroundRadius = min(backgroundSize.width, backgroundSize.height) * 0.5
        let closeSize = params.closeFrame.size
        let closeRadius = min(closeSize.width, closeSize.height) * 0.5
        let backgroundChanged = backgroundView.prepare(params: NagiGlassParams(
            size: backgroundSize,
            cornerRadius: backgroundRadius,
            isDark: params.isDark,
            tintColor: glassTintColor(isDark: params.isDark),
            isInteractive: true,
            isVisible: true,
            reduceTransparency: params.reduceTransparency
        ))
        let closeChanged = closeBackgroundView.prepare(params: NagiGlassParams(
            size: closeSize,
            cornerRadius: closeRadius,
            isDark: params.isDark,
            tintColor: glassTintColor(isDark: params.isDark),
            isInteractive: true,
            isVisible: params.isActive,
            reduceTransparency: params.reduceTransparency
        ))
        return backgroundChanged || closeChanged
    }

    func applyInternalGeometry(params: NagiSearchParams) {
        let backgroundSize = params.backgroundFrame.size
        let backgroundRadius = min(backgroundSize.width, backgroundSize.height) * 0.5
        let closeSize = params.closeFrame.size
        let closeRadius = min(closeSize.width, closeSize.height) * 0.5

        backgroundView.frame = params.backgroundFrame
        closeBackgroundView.frame = params.closeFrame
        backgroundView.applyGeometry(params: NagiGlassParams(
            size: backgroundSize,
            cornerRadius: backgroundRadius,
            isDark: params.isDark,
            tintColor: glassTintColor(isDark: params.isDark),
            isInteractive: true,
            isVisible: true,
            reduceTransparency: params.reduceTransparency
        ))
        closeBackgroundView.applyGeometry(params: NagiGlassParams(
            size: closeSize,
            cornerRadius: closeRadius,
            isDark: params.isDark,
            tintColor: glassTintColor(isDark: params.isDark),
            isInteractive: true,
            isVisible: params.isActive,
            reduceTransparency: params.reduceTransparency
        ))
        backgroundView.contentView.clipsToBounds = isContentClippedDuringTransition
        closeBackgroundView.contentView.clipsToBounds = true
        layoutControls(for: params)
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

    private func layoutControls(for params: NagiSearchParams) {
        let backgroundBounds = backgroundView.bounds
        let closeBounds = closeBackgroundView.bounds
        let active = params.isActive

        let iconSize: CGFloat = active ? 20 : 24
        let iconX = active ? 12 : backgroundBounds.midX - iconSize * 0.5
        let iconY = backgroundBounds.midY - iconSize * 0.5
        iconView.frame = CGRect(x: iconX, y: iconY, width: iconSize, height: iconSize)
        iconView.alpha = active ? 1 : 0.9

        let fieldLeading: CGFloat = active ? 40 : 0
        let trailingControls: CGFloat = active ? 48 : 0
        let fieldWidth = max(0, backgroundBounds.width - fieldLeading - trailingControls)
        placeholderLabel.frame = CGRect(
            x: fieldLeading,
            y: 0,
            width: fieldWidth,
            height: backgroundBounds.height
        )
        textField.frame = placeholderLabel.frame
        clearButton.frame = active
            ? CGRect(
                x: max(0, backgroundBounds.width - 48),
                y: max(0, backgroundBounds.midY - 22),
                width: 44,
                height: 44
            )
            : .zero

        closeButton.frame = CGRect(
            x: max(0, closeBounds.midX - 22),
            y: max(0, closeBounds.midY - 22),
            width: min(44, closeBounds.width),
            height: min(44, closeBounds.height)
        )

        placeholderLabel.alpha = active ? 1 : 0
        textField.alpha = active ? 1 : 0
        textField.isUserInteractionEnabled = active
        clearButton.alpha = active && !(textField.text ?? "").isEmpty ? 1 : 0
        clearButton.isUserInteractionEnabled = active

        closeBackgroundView.alpha = active ? 1 : 0
        closeBackgroundView.transform = active
            ? .identity
            : CGAffineTransform(scaleX: 0.001, y: 0.001)
        closeBackgroundView.isUserInteractionEnabled = active
        closeButton.isUserInteractionEnabled = active
        updatePlaceholderVisibility()
    }

    private func glassTintColor(isDark: Bool) -> UIColor {
        isDark
            ? UIColor.white.withAlphaComponent(0.025)
            : UIColor.white.withAlphaComponent(0.1)
    }

    private func updatePlaceholderVisibility() {
        guard isActive else {
            placeholderLabel.alpha = 0
            clearButton.alpha = 0
            return
        }
        let isEmpty = textField.text?.isEmpty ?? true
        placeholderLabel.alpha = isEmpty ? 1 : 0
        clearButton.alpha = isEmpty ? 0 : 1
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
