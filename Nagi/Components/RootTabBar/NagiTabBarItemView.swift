//
//  NagiTabBarItemView.swift
//  Nagi
//
//  持久化的主 Tab 视觉内容。它不创建独立的 Glass，也不处理触控；
//  选中状态由 RootTabBar 的单一 Liquid Lens 表达。
//

import UIKit

final class NagiTabBarItemView: UIView {
    enum VisualRole {
        case normal
        case selected
    }

    let tab: AppTab
    private let button: UIButton
    private let iconView: UIImageView
    private let isInteractive: Bool
    private let visualRole: VisualRole

    private static let tabSymbolConfiguration = UIImage.SymbolConfiguration(
        pointSize: 22,
        weight: .medium
    )

    init(
        tab: AppTab,
        visualRole: VisualRole = .normal,
        isInteractive: Bool = true
    ) {
        self.tab = tab
        self.button = UIButton(type: .system)
        self.iconView = UIImageView(frame: .zero)
        self.isInteractive = isInteractive
        self.visualRole = visualRole
        super.init(frame: .zero)

        isAccessibilityElement = false
        addSubview(button)
        // RootTab selection is owned exclusively by NagiTabSelectionRecognizer.
        // Keep this UIKit button only as a visual host; it never receives input.
        button.isUserInteractionEnabled = false
        button.isAccessibilityElement = isInteractive
        button.accessibilityTraits = isInteractive ? [.button] : []
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center

        iconView.isUserInteractionEnabled = false
        iconView.contentMode = .center
        button.addSubview(iconView)
        button.imageView?.isHidden = true

        switch tab {
        case .home:
            button.accessibilityLabel = "主页"
            // Keep Home in the same SF Symbols family as the other tabs and
            // use a symbol present on the deployment target.
            iconView.image = UIImage(systemName: "book.closed")
        case .library:
            button.accessibilityLabel = "书库"
            iconView.image = UIImage(systemName: "books.vertical")
        case .settings:
            button.accessibilityLabel = "设置"
            iconView.image = UIImage(systemName: "gearshape")
        }

        iconView.preferredSymbolConfiguration = Self.tabSymbolConfiguration
        update(isSelected: false, usesPrivateLens: true)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        button.frame = bounds
        iconView.frame = bounds
    }

    func update(
        isSelected: Bool,
        usesPrivateLens: Bool,
        isCompact: Bool = false
    ) {
        switch visualRole {
        case .normal:
            iconView.tintColor = !usesPrivateLens && isSelected
                ? nagiAccentColor
                : .secondaryLabel
        case .selected:
            iconView.tintColor = nagiAccentColor
        }
        guard isInteractive else { return }
        button.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
    }

    private var nagiAccentColor: UIColor {
        UIColor(named: "AccentColor") ?? .tintColor
    }
}
