//
//  NagiTabBarItemView.swift
//  Nagi
//
//  持久化的主 Tab 控件。它只负责图标和触控，不创建独立的 Glass，
//  选中状态由 RootTabBar 的单一 Liquid Lens 表达。
//

import UIKit

final class NagiTabBarItemView: UIView {
    let tab: AppTab
    private let button: UIButton
    private let iconView: UIImageView

    var onActivate: (() -> Void)?

    init(tab: AppTab) {
        self.tab = tab
        self.button = UIButton(type: .system)
        self.iconView = UIImageView(frame: .zero)
        super.init(frame: .zero)

        isAccessibilityElement = false
        addSubview(button)
        button.addTarget(self, action: #selector(activate), for: .primaryActionTriggered)
        button.accessibilityTraits = [.button]
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center

        iconView.isUserInteractionEnabled = false
        iconView.contentMode = .scaleAspectFit
        button.addSubview(iconView)
        button.imageView?.isHidden = true

        switch tab {
        case .home:
            button.accessibilityLabel = "主页"
            iconView.image = UIImage(named: "homeIcon") ?? UIImage(systemName: "house")
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

        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 21, weight: .medium)
        update(isSelected: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        button.frame = bounds
        iconView.frame = CGRect(
            x: bounds.midX - 12,
            y: bounds.midY - 12,
            width: 24,
            height: 24
        )
    }

    func update(isSelected: Bool) {
        iconView.tintColor = isSelected ? .label : .secondaryLabel
        button.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
    }

    @objc private func activate() {
        onActivate?()
    }
}
