import QuartzCore
import UIKit

@MainActor
final class GlassControlView: UIControl {
    private let surfaceView: GlassSurfaceView
    private let fillView = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let menuButton = UIButton(type: .system)
    private let highlightLayer = CAGradientLayer()
    private let selectedStrokeLayer = CALayer()
    private let touchDriver = GlassTouchDriver()

    private var currentReduceMotion = false
    private var preferredCornerRadius: CGFloat?
    private var suppressTouchHighlight = false
    private var centersCombinedContent = false

    override init(frame: CGRect) {
        surfaceView = GlassSurfaceView(frame: .zero)
        super.init(frame: frame)

        // Initialize the performance observer before the first interaction.
        _ = ReaderPerformanceController.shared

        touchDriver.control = self
        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = false

        fillView.isUserInteractionEnabled = false
        fillView.isOpaque = false
        fillView.isHidden = true
        addSubview(fillView)

        surfaceView.isUserInteractionEnabled = false
        addSubview(surfaceView)

        highlightLayer.type = .radial
        highlightLayer.colors = [
            UIColor.white.withAlphaComponent(0.28).cgColor,
            UIColor.clear.cgColor
        ]
        highlightLayer.locations = [0, 1]
        highlightLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        highlightLayer.endPoint = CGPoint(x: 1, y: 1)
        highlightLayer.opacity = 0
        layer.addSublayer(highlightLayer)

        selectedStrokeLayer.borderWidth = 2
        selectedStrokeLayer.opacity = 0
        layer.addSublayer(selectedStrokeLayer)

        iconView.contentMode = .center
        iconView.isUserInteractionEnabled = false
        iconView.accessibilityElementsHidden = true
        addSubview(iconView)

        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.isUserInteractionEnabled = false
        titleLabel.accessibilityElementsHidden = true
        addSubview(titleLabel)

        menuButton.backgroundColor = .clear
        menuButton.isHidden = true
        menuButton.isUserInteractionEnabled = false
        menuButton.isAccessibilityElement = false
        menuButton.accessibilityElementsHidden = true
        addSubview(menuButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        image: UIImage?,
        accessibilityLabel: String,
        tintColor: UIColor?,
        isEnabled: Bool,
        reduceMotion: Bool,
        title: String? = nil,
        isSelected: Bool = false,
        cornerRadius: CGFloat? = nil,
        contentColor: UIColor? = nil,
        fillColor: UIColor? = nil,
        contentFont: UIFont? = nil,
        centersCombinedContent: Bool = false
    ) {
        let imageChanged: Bool
        if let currentImage = iconView.image {
            imageChanged = image == nil || !currentImage.isEqual(image)
        } else {
            imageChanged = image != nil
        }
        if imageChanged {
            iconView.image = image
        }
        iconView.isHidden = image == nil
        if titleLabel.text != title {
            titleLabel.text = title
        }
        titleLabel.isHidden = title == nil
        titleLabel.textColor = contentColor ?? tintColor ?? .label
        titleLabel.font = contentFont
            ?? .preferredFont(forTextStyle: title == nil ? .body : .subheadline)
        fillView.backgroundColor = fillColor
        fillView.isHidden = fillColor == nil
        preferredCornerRadius = cornerRadius
        self.centersCombinedContent = centersCombinedContent
        if self.accessibilityLabel != accessibilityLabel {
            self.accessibilityLabel = accessibilityLabel
        }

        iconView.tintColor = contentColor ?? tintColor ?? .label
        self.isEnabled = isEnabled
        var traits: UIAccessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        if isSelected {
            traits.insert(.selected)
        }
        accessibilityTraits = traits
        let contentAlpha: CGFloat = isEnabled ? 1 : 0.45
        iconView.alpha = contentAlpha
        titleLabel.alpha = contentAlpha
        if !isEnabled {
            highlightLayer.opacity = 0
        }
        currentReduceMotion = reduceMotion
        touchDriver.update(reduceMotion: reduceMotion)

        let radius = resolvedCornerRadius
        let state = GlassState(
            tint: tintColor.map(GlassColor.init),
            isInteractive: isEnabled,
            cornerRadius: radius > 0 ? radius : 24
        )
        surfaceView.update(state)

        selectedStrokeLayer.borderColor = (contentColor ?? tintColor ?? .label)
            .withAlphaComponent(0.84)
            .cgColor
        selectedStrokeLayer.opacity = isSelected ? 1 : 0
        setNeedsLayout()
    }

    /// Adds a menu without replacing the persistent glass surface.
    func setPrimaryMenu(_ menu: UIMenu?) {
        menuButton.menu = menu
        menuButton.showsMenuAsPrimaryAction = menu != nil
        menuButton.isUserInteractionEnabled = menu != nil
        menuButton.isHidden = menu == nil
        menuButton.isAccessibilityElement = menu != nil
        menuButton.accessibilityElementsHidden = menu == nil
        menuButton.accessibilityLabel = accessibilityLabel
        menuButton.accessibilityValue = accessibilityValue
        menuButton.accessibilityTraits = accessibilityTraits
        isAccessibilityElement = menu == nil
        setNeedsLayout()
    }

    private var resolvedCornerRadius: CGFloat {
        let fallback = max(0, min(bounds.width, bounds.height) / 2)
        return preferredCornerRadius ?? (fallback > 0 ? fallback : 24)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled, super.beginTracking(touch, with: event) else { return false }
        touchDriver.begin(at: touch.location(in: self))
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        touchDriver.move(to: touch.location(in: self))
        return super.continueTracking(touch, with: event)
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        guard let touch else {
            touchDriver.end()
            super.endTracking(touch, with: event)
            return
        }

        let endedInside = bounds.contains(touch.location(in: self))
        touchDriver.end()
        super.endTracking(touch, with: event)
        if endedInside, isEnabled {
            sendActions(for: .primaryActionTriggered)
        }
    }

    override func cancelTracking(with event: UIEvent?) {
        touchDriver.end()
        super.cancelTracking(with: event)
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        sendActions(for: .primaryActionTriggered)
        return true
    }

    func applyTouchBegan(at point: CGPoint, reduceMotion: Bool) {
        layer.removeAnimation(forKey: "glassTouchSpring")
        layer.removeAnimation(forKey: "glassTouchPress")
        suppressTouchHighlight = ReaderPerformanceController.shared.shouldReduceNonessentialEffects

        var transform = CATransform3DIdentity
        let scale: CGFloat = reduceMotion ? 1.02 : 1.045
        transform.m11 = scale
        transform.m22 = scale
        layer.transform = transform
        updateHighlight(
            at: point,
            opacity: suppressTouchHighlight ? 0 : (reduceMotion ? 0.45 : 0.9)
        )

        guard !reduceMotion else { return }

        let press = CASpringAnimation(keyPath: "transform")
        press.mass = 1.36
        press.stiffness = 568
        press.damping = 39.7
        press.initialVelocity = 0
        press.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        press.toValue = NSValue(caTransform3D: transform)
        press.duration = press.settlingDuration
        layer.add(press, forKey: "glassTouchPress")
    }

    func applyTouchTransform(_ transform: CATransform3D, at point: CGPoint) {
        layer.removeAnimation(forKey: "glassTouchPress")
        layer.transform = transform
        updateHighlight(
            at: point,
            opacity: suppressTouchHighlight ? 0 : (currentReduceMotion ? 0.45 : 0.9)
        )
    }

    func applyTouchEnded(
        from transform: CATransform3D,
        reduceMotion: Bool
    ) {
        layer.removeAnimation(forKey: "glassTouchPress")
        highlightLayer.opacity = 0
        suppressTouchHighlight = false

        guard !reduceMotion else {
            layer.transform = CATransform3DIdentity
            return
        }

        let spring = CASpringAnimation(keyPath: "transform")
        spring.mass = 2.0
        spring.stiffness = 460
        spring.damping = 21.8
        spring.initialVelocity = 0
        spring.fromValue = NSValue(caTransform3D: transform)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.duration = spring.settlingDuration

        layer.transform = CATransform3DIdentity
        layer.add(spring, forKey: "glassTouchSpring")
    }

    private func updateHighlight(at point: CGPoint, opacity: Float) {
        let width = max(bounds.width, 1)
        let height = max(bounds.height, 1)
        highlightLayer.startPoint = CGPoint(
            x: max(0, min(1, point.x / width)),
            y: max(0, min(1, point.y / height))
        )
        highlightLayer.opacity = opacity
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fillView.frame = bounds
        surfaceView.frame = bounds
        iconView.frame = bounds

        let radius = resolvedCornerRadius
        fillView.layer.cornerRadius = radius
        fillView.layer.cornerCurve = .continuous
        surfaceView.setCornerRadius(radius)
        highlightLayer.frame = bounds
        highlightLayer.cornerRadius = radius
        selectedStrokeLayer.frame = bounds.insetBy(dx: 1, dy: 1)
        selectedStrokeLayer.cornerRadius = max(0, radius - 1)

        if !iconView.isHidden, !titleLabel.isHidden, centersCombinedContent {
            let spacing: CGFloat = 6
            let iconWidth = ceil(iconView.image?.size.width ?? 0)
            let titleWidth = ceil(titleLabel.intrinsicContentSize.width)
            let contentWidth = min(bounds.width - 20, iconWidth + spacing + titleWidth)
            let startX = max(10, (bounds.width - contentWidth) / 2)
            iconView.frame = CGRect(
                x: startX,
                y: 0,
                width: iconWidth,
                height: bounds.height
            )
            titleLabel.frame = CGRect(
                x: iconView.frame.maxX + spacing,
                y: 0,
                width: min(titleWidth, max(0, bounds.maxX - iconView.frame.maxX - spacing - 10)),
                height: bounds.height
            )
        } else if !iconView.isHidden, !titleLabel.isHidden {
            let iconWidth: CGFloat = 22
            iconView.frame = CGRect(
                x: 10,
                y: 0,
                width: iconWidth,
                height: bounds.height
            )
            titleLabel.frame = CGRect(
                x: iconView.frame.maxX + 6,
                y: 0,
                width: max(0, bounds.width - iconView.frame.maxX - 12),
                height: bounds.height
            )
        } else if !titleLabel.isHidden {
            titleLabel.frame = bounds.insetBy(dx: 10, dy: 6)
        } else {
            iconView.frame = bounds
            titleLabel.frame = .zero
        }

        menuButton.frame = bounds
    }
}
