//
//  NagiTabTransition.swift
//  Nagi
//
//  Root、TabBar、搜索和键盘共用的 property-based transition。
//  普通属性动画语义按 Nagram ComponentTransition / CAAnimationUtils 对齐：
//  model 已经等于目标时不重启动画；动画中的反向更新从 presentation 起步；
//  scale、tint、cornerRadius、blur 使用与 Nagram 相同的 property key。
//

import ObjectiveC
import QuartzCore
import UIKit

private let nagiPositionAnimationKey = "position"
private let nagiBoundsAnimationKey = "bounds"
private let nagiBoundsOriginAnimationKey = "bounds.origin"
private let nagiBoundsSizeAnimationKey = "bounds.size"
private let nagiOpacityAnimationKey = "opacity"
private let nagiTransformScaleAnimationKey = "transform.scale"
private let nagiCornerRadiusAnimationKey = "cornerRadius"
private let nagiTintAnimationKey = "contentsMultiplyColor"
private let nagiBlurAnimationKey = "filters.gaussianBlur.inputRadius"
private let nagiTransitionContextThreadKey = "NagiTabTransition.context"
private let nagiScreenScale = UIScreen.main.scale

func floorToScreenPixels(_ value: CGFloat) -> CGFloat {
    floor(value * nagiScreenScale) / nagiScreenScale
}

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

    init(
        context: NagiTransitionCompletionContext?,
        completion: ((Bool) -> Void)?
    ) {
        self.context = context
        self.completion = completion
        super.init()
    }

    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        guard !didNotify else { return }
        didNotify = true
        completion?(flag)
        context?.animationDidStop(finished: flag)
    }
}

// ComponentTransition.animateView(.spring) in Nagram temporarily overrides
// UIKit-created CASpringAnimation values. Keep the same scoped behaviour.
private enum NagiLayerSpringOverride {
    private static var isInstalled = false
    private static var stackDepth = 0

    static var isActive: Bool {
        isInstalled && stackDepth > 0
    }

    static func push() {
        installIfNeeded()
        guard isInstalled else { return }
        stackDepth += 1
    }

    static func pop() {
        guard isInstalled, stackDepth > 0 else { return }
        stackDepth -= 1
    }

    private static func installIfNeeded() {
        guard !isInstalled else { return }

        let originalSelector = #selector(CALayer.add(_:forKey:))
        let replacementSelector = #selector(CALayer.nagi_addAnimation(_:forKey:))

        guard
            let originalMethod = class_getInstanceMethod(CALayer.self, originalSelector),
            let replacementMethod = class_getInstanceMethod(CALayer.self, replacementSelector)
        else {
            assertionFailure("Unable to install CALayer spring animation override")
            return
        }

        method_exchangeImplementations(originalMethod, replacementMethod)
        isInstalled = true
    }
}

private extension CALayer {
    @objc func nagi_addAnimation(
        _ animation: CAAnimation,
        forKey key: String?
    ) {
        var updatedAnimation = animation

        if NagiLayerSpringOverride.isActive,
           let sourceAnimation = animation as? CASpringAnimation {
            var keepNativeSpring = false

            if #available(iOS 26.0, *),
               abs(sourceAnimation.duration - 0.3832) <= 0.0001 {
                keepNativeSpring = true
            }

            if abs(sourceAnimation.duration - 0.5) <= 0.0001 {
                keepNativeSpring = true
            }

            if !keepNativeSpring {
                let replacement = CABasicAnimation(keyPath: sourceAnimation.keyPath)
                replacement.fromValue = sourceAnimation.fromValue
                replacement.toValue = sourceAnimation.toValue
                replacement.byValue = sourceAnimation.byValue
                replacement.isAdditive = sourceAnimation.isAdditive
                replacement.duration = sourceAnimation.duration
                replacement.timingFunction = CAMediaTimingFunction(
                    controlPoints: 0.380,
                    0.700,
                    0.125,
                    1.000
                )
                replacement.isRemovedOnCompletion = sourceAnimation.isRemovedOnCompletion
                replacement.fillMode = sourceAnimation.fillMode
                replacement.speed = sourceAnimation.speed
                replacement.beginTime = sourceAnimation.beginTime
                replacement.timeOffset = sourceAnimation.timeOffset
                replacement.repeatCount = sourceAnimation.repeatCount
                replacement.autoreverses = sourceAnimation.autoreverses
                replacement.delegate = sourceAnimation.delegate

                if #available(iOS 15.0, *) {
                    replacement.preferredFrameRateRange = sourceAnimation.preferredFrameRateRange
                }

                updatedAnimation = replacement
            }
        }

        // After method_exchangeImplementations(), this selector points to the
        // original CALayer.add(_:forKey:) implementation.
        nagi_addAnimation(updatedAnimation, forKey: key)
    }
}

enum NagiTabTransition {
    case immediate
    case easeInOut(duration: TimeInterval)
    case spring(duration: TimeInterval)
    case keyboard(duration: TimeInterval, curve: UIView.AnimationOptions)

    var isImmediate: Bool {
        if case .immediate = self { return true }
        return false
    }

    private var duration: TimeInterval {
        switch self {
        case .immediate:
            return 0
        case let .easeInOut(duration),
             let .spring(duration),
             let .keyboard(duration, _):
            return duration
        }
    }

    /// Completion grouping only. Nagram's ComponentTransition does not wrap a
    /// whole component update in an outer CATransaction with actions disabled;
    /// each property setter owns its model write + explicit animation, while
    /// UIGlass/UIVisualEffect geometry is animated by UIView.animate itself.
    /// Keeping perform transaction-free avoids nesting those UIKit animations
    /// inside a disabled-actions transaction while still letting callers wait
    /// for every explicit animation started in the synchronous update.
    func perform(_ changes: () -> Void, completion: ((Bool) -> Void)? = nil) {
        if isImmediate {
            changes()
            completion?(true)
            return
        }

        let context = NagiTransitionCompletionContext(completion: completion)
        let threadDictionary = Thread.current.threadDictionary
        let previousContext = threadDictionary[nagiTransitionContextThreadKey]
        threadDictionary[nagiTransitionContextThreadKey] = context

        changes()

        if let previousContext {
            threadDictionary[nagiTransitionContextThreadKey] = previousContext
        } else {
            threadDictionary.removeObject(forKey: nagiTransitionContextThreadKey)
        }
        context.finishIfPossible()
    }

    /// UIKit-native adapter used by UIGlassEffect/UIVisualEffectView geometry.
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
            options = UIView.AnimationOptions(rawValue: 7 << 16)
        case let .keyboard(_, curve):
            options = curve
        case .immediate:
            options = []
        }

        if allowUserInteraction {
            options.insert(.allowUserInteraction)
        }

        let context = currentContext()
        context?.registerAnimation()

        var didComplete = false
        let animationCompletion: (Bool) -> Void = { finished in
            guard !didComplete else { return }
            didComplete = true
            completion?(finished)
            context?.animationDidStop(finished: finished)
        }

        switch self {
        case .spring:
            NagiLayerSpringOverride.push()
            UIView.animate(
                withDuration: duration,
                delay: delay,
                usingSpringWithDamping: 500.0,
                initialSpringVelocity: 0.0,
                options: options,
                animations: changes,
                completion: animationCompletion
            )
            NagiLayerSpringOverride.pop()
        default:
            UIView.animate(
                withDuration: duration,
                delay: delay,
                options: options,
                animations: changes,
                completion: animationCompletion
            )
        }
    }

    // MARK: - ComponentTransition-compatible property setters

    func setFrame(view: UIView, frame: CGRect) {
        guard view.frame != frame else { return }

        let layer = view.layer
        if isImmediate {
            setModelValue { view.frame = frame }
            removeAnimation(from: layer, forKey: nagiPositionAnimationKey)
            removeAnimation(from: layer, forKey: nagiBoundsAnimationKey)
            removeAnimation(from: layer, forKey: nagiBoundsSizeAnimationKey)
            return
        }

        let previousPosition: CGPoint
        let previousBounds: CGRect
        if hasAnimation(
            on: layer,
            keys: [
                nagiPositionAnimationKey,
                nagiBoundsAnimationKey,
                nagiBoundsSizeAnimationKey
            ]
        ), let presentation = layer.presentation() {
            previousPosition = presentation.position
            previousBounds = presentation.bounds
        } else {
            previousPosition = layer.position
            previousBounds = layer.bounds
        }

        setModelValue { view.frame = frame }

        let anchorPoint = layer.anchorPoint
        let updatedPosition = CGPoint(
            x: frame.minX + frame.width * anchorPoint.x,
            y: frame.minY + frame.height * anchorPoint.y
        )

        animatePositionInternal(
            layer: layer,
            from: previousPosition,
            to: updatedPosition,
            additive: false
        )

        if previousBounds.size != frame.size {
            animateBoundsSizeInternal(
                layer: layer,
                from: previousBounds.size,
                to: frame.size
            )
        }
    }

    func setBounds(view: UIView, bounds: CGRect) {
        guard view.bounds != bounds else { return }

        let layer = view.layer
        if isImmediate {
            setModelValue { view.bounds = bounds }
            removeAnimation(from: layer, forKey: nagiBoundsAnimationKey)
            removeAnimation(from: layer, forKey: nagiBoundsOriginAnimationKey)
            removeAnimation(from: layer, forKey: nagiBoundsSizeAnimationKey)
            return
        }

        let previousBounds: CGRect
        if hasAnimation(
            on: layer,
            keys: [
                nagiBoundsAnimationKey,
                nagiBoundsOriginAnimationKey,
                nagiBoundsSizeAnimationKey
            ]
        ), let presentation = layer.presentation() {
            previousBounds = presentation.bounds
        } else {
            previousBounds = layer.bounds
        }

        setModelValue { view.bounds = bounds }
        animateBoundsInternal(layer: layer, from: previousBounds, to: bounds)
    }

    func setPosition(view: UIView, position: CGPoint) {
        guard view.center != position else { return }

        let layer = view.layer
        if isImmediate {
            setModelValue { view.center = position }
            removeAnimation(from: layer, forKey: nagiPositionAnimationKey)
            return
        }

        let previousPosition: CGPoint
        if layer.animation(forKey: nagiPositionAnimationKey) != nil,
           let presentation = layer.presentation() {
            previousPosition = presentation.position
        } else {
            previousPosition = layer.position
        }

        setModelValue { view.center = position }
        animatePositionInternal(
            layer: layer,
            from: previousPosition,
            to: view.center,
            additive: false
        )
    }

    func animatePosition(
        layer: CALayer,
        from: CGPoint,
        to: CGPoint,
        additive: Bool
    ) {
        guard !isImmediate else { return }
        animatePositionInternal(
            layer: layer,
            from: from,
            to: to,
            additive: additive
        )
    }

    func setAlpha(
        view: UIView,
        alpha: CGFloat,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard view.alpha != alpha else {
            completion?(true)
            return
        }

        let layer = view.layer
        if isImmediate {
            setModelValue { view.alpha = alpha }
            removeAnimation(from: layer, forKey: nagiOpacityAnimationKey)
            completion?(true)
            return
        }

        let previousAlpha: Float
        if layer.animation(forKey: nagiOpacityAnimationKey) != nil {
            previousAlpha = layer.presentation()?.opacity ?? Float(view.alpha)
        } else {
            previousAlpha = Float(view.alpha)
        }

        setModelValue { view.alpha = alpha }
        addAnimation(
            makeAnimation(
                keyPath: nagiOpacityAnimationKey,
                fromValue: CGFloat(previousAlpha),
                toValue: alpha
            ),
            to: layer,
            forKey: nagiOpacityAnimationKey,
            completion: completion
        )
    }

    func setScale(
        view: UIView,
        scale: CGFloat,
        delay: TimeInterval = 0,
        completion: ((Bool) -> Void)? = nil
    ) {
        let layer = view.layer
        let currentScale = scaleValue(of: layer.transform)

        if currentScale == scale {
            if let animation = layer.animation(forKey: nagiTransformScaleAnimationKey) as? CABasicAnimation,
               let toValue = animation.toValue as? NSNumber {
                if toValue.doubleValue == Double(scale) {
                    completion?(true)
                    return
                }
            } else {
                completion?(true)
                return
            }
        }

        if isImmediate {
            setModelValue {
                layer.transform = CATransform3DMakeScale(scale, scale, 1.0)
            }
            completion?(true)
            return
        }

        let previousScale = currentScale
        setModelValue {
            layer.transform = CATransform3DMakeScale(scale, scale, 1.0)
        }
        addAnimation(
            makeAnimation(
                keyPath: nagiTransformScaleAnimationKey,
                fromValue: previousScale,
                toValue: scale
            ),
            to: layer,
            forKey: nagiTransformScaleAnimationKey,
            delay: delay,
            completion: completion
        )
    }

    func setCornerRadius(view: UIView, radius: CGFloat) {
        let layer = view.layer
        guard layer.cornerRadius != radius else { return }

        if isImmediate {
            setModelValue { layer.cornerRadius = radius }
            return
        }

        let fromValue: CGFloat
        if layer.animation(forKey: nagiCornerRadiusAnimationKey) != nil,
           let presentation = layer.presentation() {
            fromValue = presentation.cornerRadius
        } else {
            fromValue = layer.cornerRadius
        }

        setModelValue { layer.cornerRadius = radius }
        addAnimation(
            makeAnimation(
                keyPath: nagiCornerRadiusAnimationKey,
                fromValue: fromValue,
                toValue: radius
            ),
            to: layer,
            forKey: nagiCornerRadiusAnimationKey
        )
    }

    func setTintColor(view: UIView, color: UIColor) {
        if let current = view.tintColor, current.isEqual(color) {
            return
        }

        let previousColor = view.tintColor ?? .clear
        if isImmediate {
            setModelValue { view.tintColor = color }
            return
        }

        setModelValue { view.tintColor = color }
        addAnimation(
            makeAnimation(
                keyPath: nagiTintAnimationKey,
                fromValue: previousColor.cgColor,
                toValue: color.cgColor
            ),
            to: view.layer,
            forKey: nagiTintAnimationKey
        )
    }

    func setBlur(layer: CALayer, radius: CGFloat) {
        let currentRadius = modelBlurRadius(on: layer)
        guard currentRadius != radius else { return }
        guard let blurFilter = makeGaussianBlurFilter(radius: radius) else { return }

        setModelValue {
            layer.filters = [blurFilter]
        }

        guard !isImmediate else { return }

        addAnimation(
            makeAnimation(
                keyPath: nagiBlurAnimationKey,
                fromValue: currentRadius,
                toValue: radius
            ),
            to: layer,
            forKey: nagiBlurAnimationKey
        ) { [weak layer] finished in
            guard finished, radius <= 0 else { return }
            layer?.filters = nil
        }
    }

    // MARK: - Animation primitives

    private func animatePositionInternal(
        layer: CALayer,
        from: CGPoint,
        to: CGPoint,
        additive: Bool
    ) {
        let animation = makeAnimation(
            keyPath: nagiPositionAnimationKey,
            fromValue: NSValue(cgPoint: from),
            toValue: NSValue(cgPoint: to)
        )
        if let propertyAnimation = animation as? CAPropertyAnimation {
            propertyAnimation.isAdditive = additive
        }
        addAnimation(
            animation,
            to: layer,
            forKey: additive ? nil : nagiPositionAnimationKey
        )
    }

    private func animateBoundsInternal(
        layer: CALayer,
        from: CGRect,
        to: CGRect
    ) {
        addAnimation(
            makeAnimation(
                keyPath: nagiBoundsAnimationKey,
                fromValue: NSValue(cgRect: from),
                toValue: NSValue(cgRect: to)
            ),
            to: layer,
            forKey: nagiBoundsAnimationKey
        )
    }

    private func animateBoundsSizeInternal(
        layer: CALayer,
        from: CGSize,
        to: CGSize
    ) {
        addAnimation(
            makeAnimation(
                keyPath: nagiBoundsSizeAnimationKey,
                fromValue: NSValue(cgSize: from),
                toValue: NSValue(cgSize: to)
            ),
            to: layer,
            forKey: nagiBoundsSizeAnimationKey
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
        forKey key: String?,
        delay: TimeInterval = 0,
        completion: ((Bool) -> Void)? = nil
    ) {
        if delay > 0 {
            animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
            animation.fillMode = .both
        }

        let context = currentContext()
        if context != nil || completion != nil {
            context?.registerAnimation()
            animation.delegate = NagiTransitionAnimationDelegate(
                context: context,
                completion: completion
            )
        }

        layer.add(animation, forKey: key)
    }

    private func removeAnimation(from layer: CALayer, forKey key: String) {
        layer.removeAnimation(forKey: key)
    }

    private func currentContext() -> NagiTransitionCompletionContext? {
        Thread.current.threadDictionary[nagiTransitionContextThreadKey]
            as? NagiTransitionCompletionContext
    }

    private func hasAnimation(on layer: CALayer, keys: [String]) -> Bool {
        keys.contains { layer.animation(forKey: $0) != nil }
    }

    private func scaleValue(of transform: CATransform3D) -> CGFloat {
        sqrt(
            transform.m11 * transform.m11 +
            transform.m12 * transform.m12 +
            transform.m13 * transform.m13
        )
    }

    private func makeAnimation(
        keyPath: String,
        fromValue: Any,
        toValue: Any
    ) -> CAAnimation {
        switch self {
        case let .spring(duration):
            if duration == 0.5 {
                let animation = CASpringAnimation(keyPath: keyPath)
                animation.fromValue = fromValue
                animation.toValue = toValue

                if #available(iOS 26.0, *) {
                    animation.mass = 1.0
                    animation.stiffness = 555.027
                    animation.damping = 47.118
                    animation.duration = duration
                    animation.timingFunction = CAMediaTimingFunction(name: .linear)

                    if #available(iOS 17.0, *) {
                        animation.allowsOverdamping = false
                    }

                    animation.setValue(
                        NSNumber(value: 1048619),
                        forKey: "highFrameRateReason"
                    )

                    if #available(iOS 15.0, *) {
                        animation.preferredFrameRateRange = CAFrameRateRange(
                            minimum: 80.0,
                            maximum: 120.0,
                            preferred: 120.0
                        )
                    }
                } else {
                    animation.mass = 3.0
                    animation.stiffness = 1000.0
                    animation.damping = 500.0
                    animation.duration = 0.5
                    animation.timingFunction = CAMediaTimingFunction(name: .linear)
                }

                animation.isRemovedOnCompletion = true
                animation.fillMode = .forwards
                adjustFrameRate(animation: animation, keyPath: keyPath)
                return animation
            }

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
            adjustFrameRate(animation: animation, keyPath: keyPath)
            return animation

        default:
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = fromValue
            animation.toValue = toValue
            animation.duration = duration
            animation.timingFunction = timingFunction
            animation.isRemovedOnCompletion = true
            animation.fillMode = .forwards
            adjustFrameRate(animation: animation, keyPath: keyPath)
            return animation
        }
    }

    private func adjustFrameRate(animation: CAAnimation, keyPath: String) {
        if #available(iOS 15.0, *) {
            let maximumFPS = Float(UIScreen.main.maximumFramesPerSecond)
            guard maximumFPS > 61.0 else { return }
            guard keyPath != nagiOpacityAnimationKey else { return }

            animation.preferredFrameRateRange = CAFrameRateRange(
                minimum: 30.0,
                maximum: maximumFPS,
                preferred: maximumFPS
            )
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

    private func modelBlurRadius(on layer: CALayer) -> CGFloat {
        guard let filters = layer.filters else { return 0 }
        for filter in filters {
            if let filter = filter as? NSObject,
               filter.description.contains("gaussianBlur") {
                return filter.value(forKey: "inputRadius") as? CGFloat ?? 0
            }
        }
        return 0
    }

    private func makeGaussianBlurFilter(radius: CGFloat) -> NSObject? {
        guard
            let filterClass = NSClassFromString("CAFilter") as AnyObject? as? NSObjectProtocol,
            filterClass.responds(to: NSSelectorFromString("filterWithName:"))
        else {
            return nil
        }

        let filter = filterClass
            .perform(NSSelectorFromString("filterWithName:"), with: "gaussianBlur")
            .takeUnretainedValue() as? NSObject
        filter?.setValue(radius, forKey: "inputRadius")
        return filter
    }
}
