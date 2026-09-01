//
//  NagiTabBarItemView.swift
//  Nagi
//
//  持久化的主 Tab 控件。它只负责图标和触控，不创建独立的 Glass，
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

    var onActivate: (() -> Void)?

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
        button.isUserInteractionEnabled = isInteractive
        button.isAccessibilityElement = isInteractive
        if isInteractive {
            button.addTarget(self, action: #selector(activate), for: .primaryActionTriggered)
        }
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
            iconView.image = UIImage(systemName: "apple.books") ?? UIImage(systemName: "book.closed")
        case .library:
            button.accessibilityLabel = "书库"
            iconView.image = UIImage(systemName: "books.vertical")
        case .settings:
            button.accessibilityLabel = "设置"
            iconView.image = UIImage(systemName: "gearshape")
        case .search:
            button.accessibilityLabel = "搜索"
            iconView.image = UIImage(systemName: "magnifyingglass")
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

    func update(isSelected: Bool, usesPrivateLens: Bool) {
        switch visualRole {
        case .normal:
            iconView.tintColor = (!usesPrivateLens && isSelected)
                ? nagiAccentColor
                : .secondaryLabel
        case .selected:
            iconView.tintColor = nagiAccentColor
        }
        guard isInteractive else { return }
        button.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
    }

    @objc private func activate() {
        onActivate?()
    }

    private var nagiAccentColor: UIColor {
        UIColor(named: "AccentColor") ?? .tintColor
    }
}
