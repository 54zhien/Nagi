
import UIKit

final class NagiTabBarItemView: UIView {
    enum VisualRole {
        case normal
        case selected
    }

    let tab: AppTab
    private let button: UIButton
    private let iconView: UIImageView
    private let titleLabel: UILabel
    private let isInteractive: Bool
    private let visualRole: VisualRole
    private var showsTitle = true
    private var isCompact = false

    var onAccessibilityActivate: (() -> Bool)?

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
        self.titleLabel = UILabel(frame: .zero)
        self.isInteractive = isInteractive
        self.visualRole = visualRole
        super.init(frame: .zero)

        isAccessibilityElement = isInteractive
        addSubview(button)
        button.isUserInteractionEnabled = false
        button.isAccessibilityElement = false
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center

        iconView.isUserInteractionEnabled = false
        iconView.contentMode = .center
        button.addSubview(iconView)
        button.imageView?.isHidden = true

        titleLabel.font = UIFont.systemFont(ofSize: 10, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.textColor = .secondaryLabel
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.isUserInteractionEnabled = false
        button.addSubview(titleLabel)

        switch tab {
        case .home:
            button.accessibilityLabel = "主页"
            titleLabel.text = "主页"
            iconView.image = UIImage(systemName: "book.closed")
        case .library:
            button.accessibilityLabel = "书库"
            titleLabel.text = "书库"
            iconView.image = UIImage(systemName: "books.vertical")
        case .settings:
            button.accessibilityLabel = "设置"
            titleLabel.text = "设置"
            iconView.image = UIImage(systemName: "gearshape")
        }

        accessibilityLabel = titleLabel.text
        accessibilityTraits = isInteractive ? [.button] : []

        iconView.preferredSymbolConfiguration = Self.tabSymbolConfiguration
        update(isSelected: false, usesPrivateLens: true)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        button.frame = bounds
    }

    override func accessibilityActivate() -> Bool {
        guard isInteractive else { return false }
        return onAccessibilityActivate?() ?? false
    }

    func update(
        isSelected: Bool,
        usesPrivateLens: Bool,
        isCompact: Bool = false,
        showsTitle: Bool = true,
        transition: NagiTabTransition = .immediate
    ) {
        self.isCompact = isCompact
        self.showsTitle = showsTitle
        button.frame = bounds

        let iconSize = iconView.image?.size ?? CGSize(width: 22, height: 22)
        let titleVisible = showsTitle && !isCompact
        let iconFrame = CGRect(
            x: floor((bounds.width - iconSize.width) * 0.5),
            y: titleVisible
                ? 3
                : floor((bounds.height - iconSize.height) * 0.5),
            width: iconSize.width,
            height: iconSize.height
        )
        let titleHeight = ceil(titleLabel.font.lineHeight)
        let titleFrame = CGRect(
            x: 0,
            y: bounds.height - 8 - titleHeight,
            width: bounds.width,
            height: titleHeight
        )

        switch visualRole {
        case .normal:
            let color = !usesPrivateLens && isSelected
                ? nagiAccentColor
                : .secondaryLabel
            iconView.tintColor = color
            titleLabel.textColor = color
        case .selected:
            let color = isCompact
                ? .secondaryLabel
                : nagiAccentColor
            iconView.tintColor = color
            titleLabel.textColor = color
        }
        accessibilityTraits = isSelected ? [.button, .selected] : [.button]
        transition.setFrame(view: iconView, frame: iconFrame)
        transition.setFrame(view: titleLabel, frame: titleFrame)
        transition.setAlpha(
            view: titleLabel,
            alpha: titleVisible ? 1 : 0
        )
    }

    private var nagiAccentColor: UIColor {
        UIColor(named: "AccentColor") ?? .tintColor
    }
}
