//
//  NagiSearchContainerView.swift
//  Nagi
//
//  Persistent search control. Its hierarchy never changes during a morph.
//

import UIKit

@MainActor
final class NagiSearchContainerView: UIControl, UITextFieldDelegate {
    let glassView = NagiBottomBarGlassView()
    private let iconView = UIImageView(image: UIImage(systemName: "magnifyingglass"))
    private let placeholderLabel = UILabel()
    let textField = UITextField()
    private let cancelButton = UIButton(type: .system)

    var onActivate: (() -> Void)?
    var onCancel: (() -> Void)?
    var onQueryChanged: ((String) -> Void)?
    var onEditingDidEnd: (() -> Void)?

    private(set) var isSearching = false
    private var reduceMotion = false

    override init(frame: CGRect) {
        super.init(frame: frame)

        isOpaque = false
        clipsToBounds = true
        accessibilityTraits = [.button]
        accessibilityLabel = "搜索书名"

        glassView.isUserInteractionEnabled = false
        addSubview(glassView)

        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .center
        iconView.isUserInteractionEnabled = false
        addSubview(iconView)

        placeholderLabel.text = "搜索书名"
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.textColor = .secondaryLabel
        placeholderLabel.isUserInteractionEnabled = false
        addSubview(placeholderLabel)

        textField.borderStyle = .none
        textField.backgroundColor = .clear
        textField.font = .preferredFont(forTextStyle: .body)
        textField.textColor = .label
        textField.tintColor = .systemBlue
        textField.placeholder = ""
        textField.returnKeyType = .done
        textField.autocorrectionType = .default
        textField.autocapitalizationType = .none
        textField.clearButtonMode = .whileEditing
        textField.alpha = 0
        textField.isUserInteractionEnabled = false
        textField.delegate = self
        textField.accessibilityLabel = "搜索书名"
        textField.addTarget(
            self,
            action: #selector(textChanged(_:)),
            for: .editingChanged
        )
        addSubview(textField)

        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "xmark.circle.fill")
        configuration.baseForegroundColor = .secondaryLabel
        configuration.contentInsets = .zero
        cancelButton.configuration = configuration
        cancelButton.accessibilityLabel = "取消搜索"
        cancelButton.alpha = 0
        cancelButton.isUserInteractionEnabled = false
        cancelButton.addTarget(
            self,
            action: #selector(cancelPressed),
            for: .touchUpInside
        )
        addSubview(cancelButton)

        addTarget(self, action: #selector(containerPressed), for: .touchUpInside)
        updateAccessibilityElements()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(reduceMotion: Bool, reduceTransparency: Bool) {
        self.reduceMotion = reduceMotion
        glassView.setReduceTransparency(reduceTransparency)
        textField.accessibilityHint = reduceMotion ? nil : "输入书名关键词"
    }

    func setSearching(_ searching: Bool) {
        isSearching = searching
        accessibilityTraits = searching ? [] : [.button]
        accessibilityLabel = searching ? nil : "搜索书名"

        textField.alpha = searching ? 1 : 0
        textField.isUserInteractionEnabled = searching
        placeholderLabel.alpha = searching && textField.text?.isEmpty != false ? 1 : 0
        cancelButton.alpha = searching ? 1 : 0
        cancelButton.isUserInteractionEnabled = searching

        if !searching {
            textField.resignFirstResponder()
        }
        updateAccessibilityElements()
    }

    func setQuery(_ query: String) {
        guard textField.text != query else { return }
        textField.text = query
        placeholderLabel.alpha = isSearching && query.isEmpty ? 1 : 0
    }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        guard isSearching else { return false }
        return textField.becomeFirstResponder()
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        textField.resignFirstResponder()
    }

    override var canBecomeFirstResponder: Bool { isSearching }

    override func layoutSubviews() {
        super.layoutSubviews()
        glassView.frame = bounds

        let centerY = bounds.midY
        let iconSize = CGSize(width: 24, height: 24)
        iconView.frame = CGRect(
            x: 12,
            y: centerY - (iconSize.height / 2),
            width: iconSize.width,
            height: iconSize.height
        )

        let cancelSize: CGFloat = 44
        cancelButton.frame = CGRect(
            x: max(bounds.width - cancelSize - 2, 0),
            y: centerY - (cancelSize / 2),
            width: cancelSize,
            height: cancelSize
        )

        let leading = iconView.frame.maxX + 8
        let trailing = isSearching ? cancelButton.frame.minX - 4 : bounds.width - 8
        textField.frame = CGRect(
            x: leading,
            y: centerY - 24,
            width: max(trailing - leading, 0),
            height: 48
        )
        placeholderLabel.frame = textField.frame
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -4, dy: -4).contains(point)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        _ = textField
        updateAccessibilityElements()
        onEditingDidEnd?()
    }

    @objc private func containerPressed() {
        onActivate?()
    }

    @objc private func cancelPressed() {
        onCancel?()
    }

    @objc private func textChanged(_ sender: UITextField) {
        let query = sender.text ?? ""
        placeholderLabel.alpha = isSearching && query.isEmpty ? 1 : 0
        onQueryChanged?(query)
    }

    private func updateAccessibilityElements() {
        if isSearching {
            isAccessibilityElement = false
            accessibilityElements = [textField, cancelButton]
        } else {
            isAccessibilityElement = true
            accessibilityElements = nil
        }
    }
}
