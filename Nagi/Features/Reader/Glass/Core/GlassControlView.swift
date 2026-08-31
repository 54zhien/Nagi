//
//  GlassControlView.swift
//  Nagi
//
//  Persistent UIKit control used by the Reader Chrome.
//

import QuartzCore
import UIKit

@MainActor
final class GlassControlView: UIControl {
    private let surfaceView: GlassSurfaceView
    private let iconView = UIImageView()
    private let highlightLayer = CAGradientLayer()
    private let touchDriver = GlassTouchDriver()

    private var currentState: GlassState?
    private var currentReduceMotion = false

    override init(frame: CGRect) {
        surfaceView = GlassSurfaceView()
        super.init(frame: frame)

        touchDriver.control = self
        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = false

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

        iconView.contentMode = .center
        iconView.isUserInteractionEnabled = false
        iconView.accessibilityElementsHidden = true
        addSubview(iconView)
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
        reduceMotion: Bool
    ) {
        if iconView.image !== image {
            iconView.image = image
        }
        if self.accessibilityLabel != accessibilityLabel {
            self.accessibilityLabel = accessibilityLabel
        }

        iconView.tintColor = tintColor ?? .label
        self.isEnabled = isEnabled
        accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        currentReduceMotion = reduceMotion
        touchDriver.update(reduceMotion: reduceMotion)

        let radius = max(0, min(bounds.width, bounds.height) / 2)
        let state = GlassState(
            tint: tintColor.map(GlassColor.init),
            isEnabled: isEnabled,
            isInteractive: isEnabled,
            cornerRadius: radius > 0 ? radius : 24
        )
        if currentState != state {
            surfaceView.update(state)
            currentState = state
        }
        alpha = isEnabled ? 1 : 0.45
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
            touchDriver.end(at: startPointForCancelledTouch, cancelled: true)
            super.endTracking(touch, with: event)
            return
        }

        let point = touch.location(in: self)
        let endedInside = bounds.contains(point)
        touchDriver.end(at: point, cancelled: false)
        super.endTracking(touch, with: event)
        if endedInside, isEnabled {
            sendActions(for: .primaryActionTriggered)
        }
    }

    override func cancelTracking(with event: UIEvent?) {
        touchDriver.end(at: startPointForCancelledTouch, cancelled: true)
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

        var transform = CATransform3DIdentity
        let scale: CGFloat = reduceMotion ? 1.02 : 1.045
        transform.m11 = scale
        transform.m22 = scale
        layer.transform = transform
        updateHighlight(at: point, opacity: reduceMotion ? 0.45 : 0.9)

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
        updateHighlight(at: point, opacity: currentReduceMotion ? 0.45 : 0.9)
    }

    func applyTouchEnded(
        from transform: CATransform3D,
        at point: CGPoint,
        cancelled: Bool,
        reduceMotion: Bool
    ) {
        _ = point
        _ = cancelled
        layer.removeAnimation(forKey: "glassTouchPress")
        highlightLayer.opacity = 0

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

    private var startPointForCancelledTouch: CGPoint {
        CGPoint(x: bounds.midX, y: bounds.midY)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        surfaceView.frame = bounds
        iconView.frame = bounds

        let radius = max(0, min(bounds.width, bounds.height) / 2)
        surfaceView.setCornerRadius(radius)
        highlightLayer.frame = bounds
        highlightLayer.cornerRadius = radius
    }
}
