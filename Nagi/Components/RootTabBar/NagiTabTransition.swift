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

private var nagiTransitionAnimationDelegatesKey: UInt8 = 0
private let nagiBlurAnimationKey = "nagi.transition.blur"
private let nagiPositionAnimationKey = "nagi.transition.position"
private let nagiBoundsAnimationKey = "nagi.transition.bounds"
private let nagiOpacityAnimationKey = "nagi.transition.opacity"
private let nagiTransformAnimationKey = "nagi.transition.transform"
private let nagiCornerRadiusAnimationKey = "nagi.transition.cornerRadius"
private let nagiTransitionContextThreadKey = "NagiTabTransition.context"

private final class NagiTransitionCompletionContext: NSObject {
    private var pendingAnimationCount = 0
    private var allAnimationsFinished = true
    private var didComplete = false
    private let completion: ((Bool) -> Void)?

    init(completion: ((Bool) -> Void)?) {
        self.completion = completion
    }

    func registerAnimation() {
        guard !didComplete else { return }
        pendingAnimationCount += 1
    }

    func animationDidStop(finished: Bool) {
        guard !didComplete else { return }
        allAnimationsFinished = allAnimationsFinished && finished
        pendingAnimationCount = max(0, pendingAnimationCount - 1)
        finishIfPossible()
    }

    func finishIfPossible() {
        guard !didComplete, pendingAnimationCount == 0 else { return }
        didComplete = true
        completion?(allAnimationsFinished)
    }
}

private final class NagiTransitionAnimationDelegate: NSObject, CAAnimationDelegate {
    private var didNotify = false
    private let context: NagiTransitionCompletionContext?
    private let completion: ((Bool) -> Void)?
    weak var layer: CALayer?
    let animationKey: String

    init(
        context: NagiTransitionCompletionContext?,
        completion: ((Bool) -> Void)?,
        layer: CALayer,
        animationKey: String
    ) {
        self.context = context
        self.completion = completion
        self.layer = layer
        self.animationKey = animationKey
        super.init()
    }

    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        removeAnimationDelegate(from: layer, forKey: animationKey)
        notify(finished: flag)
    }

    func cancel() {
        notify(finished: false)
    }

    private func notify(finished: Bool) {
        guard !didNotify else { return }
        didNotify = true
        completion?(finished)
        context?.animationDidStop(finished: finished)
    }
}

private func removeAnimationDelegate(from layer: CALayer?, forKey key: String) {
    guard let layer,
          let delegates = objc_getAssociatedObject(
              layer,
              &nagiTransitionAnimationDelegatesKey
          ) as? NSMutableDictionary else {
        return
    }
    delegates.removeObject(forKey: key as NSString)
}

enum NagiTabTransition {
    case immediate
    case easeInOut(duration: TimeInterval)
    case spring(duration: TimeInterval)
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
        case let .easeInOut(duration), let .spring(duration), let .keyboard(duration, _):
            return duration
        }
    }

    /// Apply a batch of property writes in one Core Animation transaction.
    /// The completion is held until every property animation registered by
    /// this batch has finished. Interrupted animations complete as `false`,
    /// allowing the caller to ignore stale transitions.
    func perform(_ changes: () -> Void, completion: ((Bool) -> Void)? = nil) {
        if isImmediate {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            changes()
            CATransaction.commit()
            completion?(true)
            return
        }

        let context = NagiTransitionCompletionContext(completion: completion)
        let threadDictionary = Thread.current.threadDictionary
        let previousContext = threadDictionary[nagiTransitionContextThreadKey]
        threadDictionary[nagiTransitionContextThreadKey] = context

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()

        if let previousContext {
            threadDictionary[nagiTransitionContextThreadKey] = previousContext
        } else {
            threadDictionary.removeObject(forKey: nagiTransitionContextThreadKey)
        }
        context.finishIfPossible()
    }

    /// Run geometry that belongs to a UIKit-native view in UIKit's own
    /// animation transaction. The property-based helpers below remain the
    /// source of truth for ordinary Nagi views; this adapter is specifically
    /// for UIVisualEffectView and other UIKit views whose native implementation
    /// observes the UIView animation transaction itself.
    func animateView(
        allowUserInteraction: Bool = true,
        delay: TimeInterval = 0,
        _ changes: @escaping () -> Void,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard !isImmediate else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            changes()
            CATransaction.commit()
            completion?(true)
            return
        }

        var options: UIView.AnimationOptions
        switch self {
        case .easeInOut:
            options = [.curveEaseInOut]
        case .spring:
            // Nagram uses this native UIKit curve slot for its spring
            // transaction. Nagi's existing property transition continues to
            // own its explicit 0.380/0.700/0.125/1.000 curve.
            options = UIView.AnimationOptions(rawValue: 7 << 16)
        case let .keyboard(_, curve):
            options = curve
        case .immediate:
            options = []
        }

        if allowUserInteraction {
            options.insert(.allowUserInteraction)
        }

        UIView.animate(
            withDuration: duration,
            delay: delay,
            options: options,
            animations: changes,
            completion: completion
        )
    }

    func setFrame(view: UIView, frame: CGRect) {
        let targetFrame = frame.integral
        let layer = view.layer
        let fromPosition = presentationPosition(for: layer, animationKey: nagiPositionAnimationKey)
        let fromBounds = presentationBounds(for: layer, animationKey: nagiBoundsAnimationKey)

        removeAnimation(from: layer, forKey: nagiPositionAnimationKey)
        removeAnimation(from: layer, forKey: nagiBoundsAnimationKey)
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
            addAnimation(
                makeAnimation(
                    keyPath: "position",
                    fromValue: NSValue(cgPoint: fromPosition),
                    toValue: NSValue(cgPoint: toPosition)
                ),
                to: layer,
                forKey: nagiPositionAnimationKey
            )
        }
        if fromBounds != toBounds {
            addAnimation(
                makeAnimation(
                    keyPath: "bounds",
                    fromValue: NSValue(cgRect: fromBounds),
                    toValue: NSValue(cgRect: toBounds)
                ),
                to: layer,
                forKey: nagiBoundsAnimationKey
            )
        }
    }

    func setBounds(view: UIView, bounds: CGRect) {
        let layer = view.layer
        let fromBounds = presentationBounds(for: layer, animationKey: nagiBoundsAnimationKey)
        removeAnimation(from: layer, forKey: nagiBoundsAnimationKey)
        setModelValue {
            view.bounds = bounds
        }

        guard !isImmediate else { return }
        let toBounds = layer.bounds
        guard fromBounds != toBounds else { return }
        addAnimation(
            makeAnimation(
                keyPath: "bounds",
                fromValue: NSValue(cgRect: fromBounds),
                toValue: NSValue(cgRect: toBounds)
            ),
            to: layer,
            forKey: nagiBoundsAnimationKey
        )
    }

    func setPosition(view: UIView, position: CGPoint) {
        let layer = view.layer
        let fromPosition = presentationPosition(for: layer, animationKey: nagiPositionAnimationKey)
        removeAnimation(from: layer, forKey: nagiPositionAnimationKey)
        setModelValue {
            layer.position = position
        }

        guard !isImmediate else { return }
        let toPosition = layer.position
        guard fromPosition != toPosition else { return }
        addAnimation(
            makeAnimation(
                keyPath: "position",
                fromValue: NSValue(cgPoint: fromPosition),
                toValue: NSValue(cgPoint: toPosition)
            ),
            to: layer,
            forKey: nagiPositionAnimationKey
        )
    }

    func animatePosition(
        layer: CALayer,
        from: CGPoint,
        to: CGPoint,
        additive: Bool
    ) {
        guard !isImmediate else {
            return
        }

        let animation = makeAnimation(
            keyPath: "position",
            fromValue: NSValue(cgPoint: from),
            toValue: NSValue(cgPoint: to)
        )

        if let propertyAnimation = animation as? CAPropertyAnimation {
            propertyAnimation.isAdditive = additive
        }

        let animationKey = additive
            ? "nagi.transition.position.additive"
            : nagiPositionAnimationKey
        removeAnimation(from: layer, forKey: animationKey)
        addAnimation(
            animation,
            to: layer,
            forKey: animationKey
        )
    }

    func setAlpha(view: UIView, alpha: CGFloat) {
        let layer = view.layer
        let fromOpacity = presentationOpacity(for: layer, animationKey: nagiOpacityAnimationKey)
        removeAnimation(from: layer, forKey: nagiOpacityAnimationKey)
        setModelValue {
            view.alpha = alpha
        }

        guard !isImmediate else { return }
        let toOpacity = layer.opacity
        guard abs(CGFloat(fromOpacity) - CGFloat(toOpacity)) > 0.0001 else { return }
        addAnimation(
            makeAnimation(
                keyPath: "opacity",
                fromValue: fromOpacity,
                toValue: toOpacity
            ),
            to: layer,
            forKey: nagiOpacityAnimationKey
        )
    }

    func setScale(view: UIView, scale: CGFloat) {
        let layer = view.layer
        let fromTransform = presentationTransform(for: layer, animationKey: nagiTransformAnimationKey)
        removeAnimation(from: layer, forKey: nagiTransformAnimationKey)
        setModelValue {
            view.transform = CGAffineTransform(scaleX: scale, y: scale)
        }

        guard !isImmediate else { return }
        let toTransform = layer.transform
        guard !CATransform3DEqualToTransform(fromTransform, toTransform) else { return }
        addAnimation(
            makeAnimation(
                keyPath: "transform",
                fromValue: NSValue(caTransform3D: fromTransform),
                toValue: NSValue(caTransform3D: toTransform)
            ),
            to: layer,
            forKey: nagiTransformAnimationKey
        )
    }

    func setCornerRadius(view: UIView, radius: CGFloat) {
        let layer = view.layer
        let fromRadius = presentationCornerRadius(for: layer, animationKey: nagiCornerRadiusAnimationKey)
        removeAnimation(from: layer, forKey: nagiCornerRadiusAnimationKey)
        setModelValue {
            layer.cornerRadius = radius
        }

        guard !isImmediate else { return }
        let toRadius = layer.cornerRadius
        guard abs(fromRadius - toRadius) > 0.0001 else { return }
        addAnimation(
            makeAnimation(
                keyPath: "cornerRadius",
                fromValue: fromRadius,
                toValue: toRadius
            ),
            to: layer,
            forKey: nagiCornerRadiusAnimationKey
        )
    }

    func setBlur(layer: CALayer, radius: CGFloat) {
        let fromRadius = currentBlurRadius(on: layer)
        removeAnimation(from: layer, forKey: nagiBlurAnimationKey)

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
            addAnimation(
                makeAnimation(
                    keyPath: "filters.gaussianBlur.inputRadius",
                    fromValue: fromRadius,
                    toValue: 0
                ),
                to: layer,
                forKey: nagiBlurAnimationKey
            ) { [weak layer] finished in
                if finished {
                    layer?.filters = nil
                }
            }
            return
        }

        guard let filter = makeGaussianBlurFilter(radius: radius) else { return }
        setModelValue {
            layer.filters = [filter]
        }
        guard !isImmediate, abs(fromRadius - radius) > 0.0001 else { return }
        addAnimation(
            makeAnimation(
                keyPath: "filters.gaussianBlur.inputRadius",
                fromValue: fromRadius,
                toValue: radius
            ),
            to: layer,
            forKey: nagiBlurAnimationKey
        )
    }

    private func setModelValue(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    private func addAnimation(
        _ animation: CAAnimation,
        to layer: CALayer,
        forKey key: String,
        completion: ((Bool) -> Void)? = nil
    ) {
        let context = currentContext()
        if context == nil, completion == nil {
            layer.add(animation, forKey: key)
            return
        }

        context?.registerAnimation()
        let delegate = NagiTransitionAnimationDelegate(
            context: context,
            completion: completion,
            layer: layer,
            animationKey: key
        )
        animation.delegate = delegate
        retainAnimationDelegate(delegate, on: layer, forKey: key)
        layer.add(animation, forKey: key)
    }

    private func removeAnimation(from layer: CALayer, forKey key: String) {
        guard let animation = layer.animation(forKey: key) else { return }
        if let delegate = animationDelegate(on: layer, forKey: key) {
            removeAnimationDelegate(from: layer, forKey: key)
            delegate.cancel()
        } else {
            removeAnimationDelegate(from: layer, forKey: key)
        }
        layer.removeAnimation(forKey: key)
    }

    private func retainAnimationDelegate(
        _ delegate: NagiTransitionAnimationDelegate,
        on layer: CALayer,
        forKey key: String
    ) {
        let delegates: NSMutableDictionary
        if let existing = objc_getAssociatedObject(
            layer,
            &nagiTransitionAnimationDelegatesKey
        ) as? NSMutableDictionary {
            delegates = existing
        } else {
            delegates = NSMutableDictionary()
            objc_setAssociatedObject(
                layer,
                &nagiTransitionAnimationDelegatesKey,
                delegates,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
        delegates.setObject(delegate, forKey: key as NSString)
    }

    private func animationDelegate(on layer: CALayer, forKey key: String) -> NagiTransitionAnimationDelegate? {
        let delegates = objc_getAssociatedObject(
            layer,
            &nagiTransitionAnimationDelegatesKey
        ) as? NSMutableDictionary
        return delegates?.object(forKey: key) as? NagiTransitionAnimationDelegate
    }

    private func removeAnimationDelegate(from layer: CALayer?, forKey key: String) {
        guard let layer,
              let delegates = objc_getAssociatedObject(
                  layer,
                  &nagiTransitionAnimationDelegatesKey
              ) as? NSMutableDictionary else {
            return
        }
        delegates.removeObject(forKey: key as NSString)
    }

    private func currentContext() -> NagiTransitionCompletionContext? {
        Thread.current.threadDictionary[nagiTransitionContextThreadKey]
            as? NagiTransitionCompletionContext
    }

    private func presentationPosition(for layer: CALayer, animationKey: String) -> CGPoint {
        guard layer.animation(forKey: animationKey) != nil else {
            return layer.position
        }
        return layer.presentation()?.position ?? layer.position
    }

    private func presentationBounds(for layer: CALayer, animationKey: String) -> CGRect {
        guard layer.animation(forKey: animationKey) != nil else {
            return layer.bounds
        }
        return layer.presentation()?.bounds ?? layer.bounds
    }

    private func presentationOpacity(for layer: CALayer, animationKey: String) -> Float {
        guard layer.animation(forKey: animationKey) != nil else {
            return layer.opacity
        }
        return layer.presentation()?.opacity ?? layer.opacity
    }

    private func presentationTransform(for layer: CALayer, animationKey: String) -> CATransform3D {
        guard layer.animation(forKey: animationKey) != nil else {
            return layer.transform
        }
        return layer.presentation()?.transform ?? layer.transform
    }

    private func presentationCornerRadius(for layer: CALayer, animationKey: String) -> CGFloat {
        guard layer.animation(forKey: animationKey) != nil else {
            return layer.cornerRadius
        }
        return layer.presentation()?.cornerRadius ?? layer.cornerRadius
    }

    private func makeAnimation(
        keyPath: String,
        fromValue: Any,
        toValue: Any
    ) -> CAAnimation {
        switch self {
        case let .spring(duration):
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = fromValue
            animation.toValue = toValue
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.380,
                0.700,
                0.125,
                1.000
            )
            animation.isRemovedOnCompletion = true
            animation.fillMode = .forwards
            if #available(iOS 15.0, *) {
                let maximumFPS = Float(UIScreen.main.maximumFramesPerSecond)
                if maximumFPS > 61.0 {
                    animation.preferredFrameRateRange = CAFrameRateRange(
                        minimum: 30.0,
                        maximum: maximumFPS,
                        preferred: maximumFPS
                    )
                }
            }
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
        case .immediate:
            return CAMediaTimingFunction(name: .linear)
        case .spring:
            return CAMediaTimingFunction(
                controlPoints: 0.380,
                0.700,
                0.125,
                1.000
            )
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
