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

    private static let tabSymbolConfiguration = UIImage.SymbolConfiguration(
        pointSize: 22,
        weight: .medium
    )
    private static let tabTitleFont = UIFont.systemFont(
        ofSize: 10,
        weight: .semibold
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

        isAccessibilityElement = false
        addSubview(button)
        // Selection is handled by NagiTabSelectionRecognizer.
        button.isUserInteractionEnabled = false
        button.isAccessibilityElement = isInteractive
        button.accessibilityTraits = isInteractive ? [.button] : []
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center

        iconView.isUserInteractionEnabled = false
        iconView.contentMode = .center
        button.addSubview(iconView)
        button.imageView?.isHidden = true

        titleLabel.text = tab.title
        titleLabel.font = Self.tabTitleFont
        titleLabel.textAlignment = .center
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.isUserInteractionEnabled = false
        button.addSubview(titleLabel)

        button.accessibilityLabel = tab.title
        iconView.image = UIImage(systemName: tab.symbolName)

        iconView.preferredSymbolConfiguration = Self.tabSymbolConfiguration
        update(isSelected: false, usesPrivateLens: true)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        button.frame = bounds

        let titleHeight: CGFloat = 12
        let titleY = max(0, bounds.height - 8 - titleHeight)
        titleLabel.frame = CGRect(
            x: 0,
            y: titleY,
            width: bounds.width,
            height: titleHeight
        )
        iconView.frame = CGRect(
            x: 0,
            y: 3,
            width: bounds.width,
            height: max(0, titleY - 3)
        )
    }

    func update(
        isSelected: Bool,
        usesPrivateLens: Bool,
        isCompact: Bool = false,
        titleTransition: NagiTabTransition? = nil
    ) {
        let tintColor: UIColor
        switch visualRole {
        case .normal:
            tintColor = !usesPrivateLens && isSelected
                ? nagiAccentColor
                : .secondaryLabel
        case .selected:
            tintColor = isCompact
                ? .secondaryLabel
                : nagiAccentColor
        }
        iconView.tintColor = tintColor
        titleLabel.textColor = tintColor
        let titleAlpha: CGFloat = isCompact ? 0 : 1
        if let titleTransition {
            titleTransition.setAlpha(view: titleLabel, alpha: titleAlpha)
        } else {
            titleLabel.alpha = titleAlpha
        }

        guard isInteractive else { return }
        button.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
    }

    private var nagiAccentColor: UIColor {
        UIColor(named: "AccentColor") ?? .tintColor
    }
}
