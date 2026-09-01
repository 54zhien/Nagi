//
//  NagiTabTransition.swift
//  Nagi
//
//  Root、TabBar、搜索和键盘共用的 property-based transition。所有目标值
//  直接写入 model layer，再从 presentation layer 当前值建立 CA 动画，
//  这样快速反向时不会从上一轮尚未显示的 model geometry 重新起步。
//

import ObjectiveC
import QuartzCore
import UIKit

private let nagiBlurAnimationKey = "nagi.transition.blur"
private var nagiBlurAnimationDelegateKey: UInt8 = 0

private final class NagiBlurAnimationDelegate: NSObject, CAAnimationDelegate {
    weak var layer: CALayer?
    let shouldRemoveFilter: Bool

    init(layer: CALayer, shouldRemoveFilter: Bool) {
        self.layer = layer
        self.shouldRemoveFilter = shouldRemoveFilter
    }

    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        guard flag, let layer else { return }
        if shouldRemoveFilter {
            layer.filters = nil
        }
        objc_setAssociatedObject(
            layer,
            &nagiBlurAnimationDelegateKey,
            nil,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}

enum NagiTabTransition {
    case immediate
    case easeInOut(duration: TimeInterval)
    case spring(duration: TimeInterval, damping: CGFloat, velocity: CGFloat)
    case keyboard(duration: TimeInterval, curve: UIView.AnimationOptions)

    var isImmediate: Bool {
        if case .immediate = self {
            return true
        }
        return false
    }

    private var duration: TimeInterval {
        switch self {
        case .immediate:
            return 0
        case let .easeInOut(duration), let .spring(duration, _, _), let .keyboard(duration, _):
            return duration
        }
    }

    /// Apply a batch of property writes in one Core Animation transaction.
    /// This replaces the old nested UIView.animate blocks while preserving a
    /// single completion point for Root and TabBar state transitions.
    func perform(_ changes: () -> Void, completion: ((Bool) -> Void)? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock {
            completion?(true)
        }
        changes()
        CATransaction.commit()
    }

    func setFrame(view: UIView, frame: CGRect) {
        let targetFrame = frame.integral
        let layer = view.layer
        let presentation = layer.presentation()
        let fromPosition = presentation?.position ?? layer.position
        let fromBounds = presentation?.bounds ?? layer.bounds

        layer.removeAnimation(forKey: "nagi.transition.position")
        layer.removeAnimation(forKey: "nagi.transition.bounds")
        setModelValue {
            if view.transform == .identity {
                view.frame = targetFrame
            } else {
                view.bounds = CGRect(origin: view.bounds.origin, size: targetFrame.size)
                view.center = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
            }
        }

        guard !isImmediate else { return }

        let toPosition = layer.position
        let toBounds = layer.bounds
        if fromPosition != toPosition {
            layer.add(
                makeAnimation(
                    keyPath: "position",
                    fromValue: NSValue(cgPoint: fromPosition),
                    toValue: NSValue(cgPoint: toPosition)
                ),
                forKey: "nagi.transition.position"
            )
        }
        if fromBounds != toBounds {
            layer.add(
                makeAnimation(
                    keyPath: "bounds",
                    fromValue: NSValue(cgRect: fromBounds),
                    toValue: NSValue(cgRect: toBounds)
                ),
                forKey: "nagi.transition.bounds"
            )
        }
    }

    func setBounds(view: UIView, bounds: CGRect) {
        let layer = view.layer
        let presentation = layer.presentation()
        let fromBounds = presentation?.bounds ?? layer.bounds
        layer.removeAnimation(forKey: "nagi.transition.bounds")
        setModelValue {
            view.bounds = bounds
        }

        guard !isImmediate else { return }
        let toBounds = layer.bounds
        guard fromBounds != toBounds else { return }
        layer.add(
            makeAnimation(
                keyPath: "bounds",
                fromValue: NSValue(cgRect: fromBounds),
                toValue: NSValue(cgRect: toBounds)
            ),
            forKey: "nagi.transition.bounds"
        )
    }

    func setPosition(view: UIView, position: CGPoint) {
        let layer = view.layer
        let presentation = layer.presentation()
        let fromPosition = presentation?.position ?? layer.position
        layer.removeAnimation(forKey: "nagi.transition.position")
        setModelValue {
            layer.position = position
        }

        guard !isImmediate else { return }
        let toPosition = layer.position
        guard fromPosition != toPosition else { return }
        layer.add(
            makeAnimation(
                keyPath: "position",
                fromValue: NSValue(cgPoint: fromPosition),
                toValue: NSValue(cgPoint: toPosition)
            ),
            forKey: "nagi.transition.position"
        )
    }

    func setAlpha(view: UIView, alpha: CGFloat) {
        let layer = view.layer
        let presentationOpacity = layer.presentation()?.opacity ?? layer.opacity
        layer.removeAnimation(forKey: "nagi.transition.opacity")
        setModelValue {
            view.alpha = alpha
        }

        guard !isImmediate else { return }
        let toOpacity = layer.opacity
        guard abs(CGFloat(presentationOpacity) - CGFloat(toOpacity)) > 0.0001 else { return }
        layer.add(
            makeAnimation(
                keyPath: "opacity",
                fromValue: presentationOpacity,
                toValue: toOpacity
            ),
            forKey: "nagi.transition.opacity"
        )
    }

    func setScale(view: UIView, scale: CGFloat) {
        let layer = view.layer
        let fromTransform = layer.presentation()?.transform ?? layer.transform
        layer.removeAnimation(forKey: "nagi.transition.transform")
        setModelValue {
            view.transform = CGAffineTransform(scaleX: scale, y: scale)
        }

        guard !isImmediate else { return }
        let toTransform = layer.transform
        guard !CATransform3DEqualToTransform(fromTransform, toTransform) else { return }
        layer.add(
            makeAnimation(
                keyPath: "transform",
                fromValue: NSValue(caTransform3D: fromTransform),
                toValue: NSValue(caTransform3D: toTransform)
            ),
            forKey: "nagi.transition.transform"
        )
    }

    func setCornerRadius(view: UIView, radius: CGFloat) {
        let layer = view.layer
        let presentationRadius = layer.presentation()?.cornerRadius ?? layer.cornerRadius
        layer.removeAnimation(forKey: "nagi.transition.cornerRadius")
        setModelValue {
            layer.cornerRadius = radius
        }

        guard !isImmediate else { return }
        let toRadius = layer.cornerRadius
        guard abs(presentationRadius - toRadius) > 0.0001 else { return }
        layer.add(
            makeAnimation(
                keyPath: "cornerRadius",
                fromValue: presentationRadius,
                toValue: toRadius
            ),
            forKey: "nagi.transition.cornerRadius"
        )
    }

    func setBlur(layer: CALayer, radius: CGFloat) {
        let fromRadius = currentBlurRadius(on: layer)
        layer.removeAnimation(forKey: nagiBlurAnimationKey)

        guard radius > 0 else {
            if isImmediate || fromRadius <= 0.0001 {
                layer.filters = nil
                return
            }

            guard let filter = makeGaussianBlurFilter(radius: 0) else {
                layer.filters = nil
                return
            }
            setModelValue {
                layer.filters = [filter]
            }
            let animation = makeAnimation(
                keyPath: "filters.gaussianBlur.inputRadius",
                fromValue: fromRadius,
                toValue: 0
            )
            let delegate = NagiBlurAnimationDelegate(layer: layer, shouldRemoveFilter: true)
            animation.delegate = delegate
            objc_setAssociatedObject(
                layer,
                &nagiBlurAnimationDelegateKey,
                delegate,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            layer.add(animation, forKey: nagiBlurAnimationKey)
            return
        }

        guard let filter = makeGaussianBlurFilter(radius: radius) else { return }
        setModelValue {
            layer.filters = [filter]
        }
        guard !isImmediate, abs(fromRadius - radius) > 0.0001 else { return }
        layer.add(
            makeAnimation(
                keyPath: "filters.gaussianBlur.inputRadius",
                fromValue: fromRadius,
                toValue: radius
            ),
            forKey: nagiBlurAnimationKey
        )
    }

    private func setModelValue(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    private func makeAnimation(
        keyPath: String,
        fromValue: Any,
        toValue: Any
    ) -> CAAnimation {
        switch self {
        case let .spring(duration, damping, velocity):
            let animation = CASpringAnimation(keyPath: keyPath)
            let normalizedDamping = max(0.1, min(1, damping))
            let settlingDuration = max(0.1, duration)
            let naturalFrequency = 4.6 / (normalizedDamping * settlingDuration)
            animation.mass = 1
            animation.stiffness = naturalFrequency * naturalFrequency
            animation.damping = 2 * normalizedDamping * naturalFrequency
            animation.initialVelocity = velocity
            animation.fromValue = fromValue
            animation.toValue = toValue
            animation.duration = max(settlingDuration, animation.settlingDuration)
            return animation
        default:
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = fromValue
            animation.toValue = toValue
            animation.duration = duration
            animation.timingFunction = timingFunction
            return animation
        }
    }

    private var timingFunction: CAMediaTimingFunction {
        switch self {
        case .immediate, .spring:
            return CAMediaTimingFunction(name: .easeInEaseOut)
        case .easeInOut:
            return CAMediaTimingFunction(name: .easeInEaseOut)
        case let .keyboard(_, curve):
            if curve.contains(.curveEaseIn) {
                return CAMediaTimingFunction(name: .easeIn)
            }
            if curve.contains(.curveEaseOut) {
                return CAMediaTimingFunction(name: .easeOut)
            }
            if curve.contains(.curveLinear) {
                return CAMediaTimingFunction(name: .linear)
            }
            return CAMediaTimingFunction(name: .easeInEaseOut)
        }
    }

    private func currentBlurRadius(on layer: CALayer) -> CGFloat {
        let source = layer.presentation() ?? layer
        if let value = source.value(forKeyPath: "filters.gaussianBlur.inputRadius") as? NSNumber {
            return CGFloat(truncating: value)
        }
        guard let filters = source.filters else { return 0 }
        for filter in filters {
            if let value = (filter as AnyObject).value(forKey: "inputRadius") as? NSNumber {
                return CGFloat(truncating: value)
            }
        }
        return 0
    }

    private func makeGaussianBlurFilter(radius: CGFloat) -> NSObject? {
        guard let filterClass = NSClassFromString("CAFilter") as AnyObject? as? NSObjectProtocol,
              filterClass.responds(to: NSSelectorFromString("filterWithName:")) else {
            return nil
        }
        let filter = filterClass
            .perform(NSSelectorFromString("filterWithName:"), with: "gaussianBlur")
            .takeUnretainedValue() as? NSObject
        filter?.setValue(radius, forKey: "inputRadius")
        return filter
    }
}
