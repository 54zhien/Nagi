//
//  NagiNavigationSearchView.swift
//  Nagi
//
//  持久化的搜索 surface。搜索从圆形入口展开为同一个 UITextField，
//  不通过 SwiftUI searchable 或删除/创建子视图来切换状态。
//

import UIKit

struct NagiSearchParams: Equatable {
    var size: CGSize
    var isActive: Bool
    var isExpanded: Bool
    var isDark: Bool
    var reduceTransparency: Bool
}

final class NagiNavigationSearchView: UIView, UITextFieldDelegate, UIGestureRecognizerDelegate {
    private let backgroundView: NagiGlassBackgroundView
    private let iconView: UIImageView
    private let placeholderLabel: UILabel
    private let textField: UITextField
    private let clearButton: UIButton
    private let closeButton: UIButton
    private var previousParams: NagiSearchParams?

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
        self.closeButton = UIButton(type: .system)
        super.init(frame: frame)

        clipsToBounds = false
        isUserInteractionEnabled = true
        addSubview(backgroundView)

        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        iconView.isUserInteractionEnabled = false
        addSubview(iconView)

        placeholderLabel.text = "搜索书名"
        placeholderLabel.textColor = .secondaryLabel
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.isUserInteractionEnabled = false
        addSubview(placeholderLabel)

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
        addSubview(textField)

        clearButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        clearButton.tintColor = .secondaryLabel
        clearButton.accessibilityLabel = "清除搜索"
        clearButton.addTarget(self, action: #selector(clearQuery), for: .primaryActionTriggered)
        addSubview(clearButton)

        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .secondaryLabel
        closeButton.accessibilityLabel = "关闭搜索"
        closeButton.addTarget(self, action: #selector(cancelSearch), for: .primaryActionTriggered)
        addSubview(closeButton)

        let recognizer = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        addGestureRecognizer(recognizer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let params = previousParams else {
            return
        }
        layoutControls(for: params)
    }

    func update(params: NagiSearchParams) {
        guard params != previousParams else {
            return
        }
        previousParams = params
        isActive = params.isActive

        frame.size = params.size
        let radius = params.isExpanded ? params.size.height * 0.5 : min(params.size.width, params.size.height) * 0.5
        backgroundView.frame = bounds
        backgroundView.update(params: NagiGlassParams(
            size: bounds.size,
            cornerRadius: radius,
            isDark: params.isDark,
            tintColor: params.isDark ? UIColor.white.withAlphaComponent(0.025) : UIColor.white.withAlphaComponent(0.1),
            tintKey: params.isExpanded ? "search-expanded" : "search-circle",
            isInteractive: true,
            isVisible: true,
            reduceTransparency: params.reduceTransparency
        ))
        layoutControls(for: params)
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
        let active = params.isActive && params.isExpanded
        let iconSize: CGFloat = active ? 20 : 24
        let iconX = active ? 12 : bounds.midX - iconSize * 0.5
        let iconY = bounds.midY - iconSize * 0.5
        iconView.frame = CGRect(x: iconX, y: iconY, width: iconSize, height: iconSize)
        iconView.alpha = active ? 1 : 0.9

        let fieldLeading: CGFloat = active ? 40 : 0
        let trailingControls: CGFloat = active ? 92 : 0
        let fieldWidth = max(0, bounds.width - fieldLeading - trailingControls)
        placeholderLabel.frame = CGRect(x: fieldLeading, y: 0, width: fieldWidth, height: bounds.height)
        textField.frame = placeholderLabel.frame
        clearButton.frame = active
            ? CGRect(x: max(0, bounds.width - 92), y: max(0, bounds.midY - 22), width: 44, height: 44)
            : .zero
        closeButton.frame = active
            ? CGRect(x: max(0, bounds.width - 48), y: max(0, bounds.midY - 22), width: 44, height: 44)
            : .zero

        placeholderLabel.alpha = active ? 1 : 0
        textField.alpha = active ? 1 : 0
        textField.isUserInteractionEnabled = active
        clearButton.alpha = active && !(textField.text ?? "").isEmpty ? 1 : 0
        clearButton.isUserInteractionEnabled = active
        closeButton.alpha = active ? 1 : 0
        closeButton.isUserInteractionEnabled = active
        updatePlaceholderVisibility()
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
