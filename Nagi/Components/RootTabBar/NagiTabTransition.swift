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
private let nagiPositionAnimationKey = "position"
private let nagiBoundsAnimationKey = "bounds.size"
private let nagiFullBoundsAnimationKey = "bounds"
private let nagiOpacityAnimationKey = "opacity"
private let nagiTransformAnimationKey = "transform"
private let nagiCornerRadiusAnimationKey = "nagi.transition.cornerRadius"
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

private enum NagiLayerSpringOverride {
    private static var isInstalled = false
    private static var stackDepth = 0

    static var isActive: Bool {
        isInstalled && stackDepth > 0
    }

    static func push() {
        installIfNeeded()

        guard isInstalled else {
            return
        }

        stackDepth += 1
    }

    static func pop() {
        guard isInstalled, stackDepth > 0 else {
            return
        }

        stackDepth -= 1
    }

    private static func installIfNeeded() {
        guard !isInstalled else {
            return
        }

        let originalSelector = #selector(CALayer.add(_:forKey:))
        let replacementSelector =
            #selector(CALayer.nagi_addAnimation(_:forKey:))

        guard
            let originalMethod = class_getInstanceMethod(
                CALayer.self,
                originalSelector
            ),
            let replacementMethod = class_getInstanceMethod(
                CALayer.self,
                replacementSelector
            )
        else {
            assertionFailure(
                "Unable to install CALayer spring animation override"
            )
            return
        }

        method_exchangeImplementations(
            originalMethod,
            replacementMethod
        )

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

            // Match Nagram UIKitRuntimeUtils:
            // iOS 26's special 0.3832-second native glass spring must
            // remain untouched.
            if #available(iOS 26.0, *) {
                if abs(sourceAnimation.duration - 0.3832) <= 0.0001 {
                    keepNativeSpring = true
                }
            }

            // Nagram also deliberately preserves the 0.5-second spring.
            if abs(sourceAnimation.duration - 0.5) <= 0.0001 {
                keepNativeSpring = true
            }

            if !keepNativeSpring {
                let replacement = CABasicAnimation(
                    keyPath: sourceAnimation.keyPath
                )

                replacement.fromValue = sourceAnimation.fromValue
                replacement.toValue = sourceAnimation.toValue
                replacement.byValue = sourceAnimation.byValue

                replacement.isAdditive = sourceAnimation.isAdditive

                replacement.duration = sourceAnimation.duration
                replacement.timingFunction =
                    CAMediaTimingFunction(
                        controlPoints:
                            0.380,
                            0.700,
                            0.125,
                            1.000
                    )

                replacement.isRemovedOnCompletion =
                    sourceAnimation.isRemovedOnCompletion
                replacement.fillMode =
                    sourceAnimation.fillMode

                replacement.speed =
                    sourceAnimation.speed
                replacement.beginTime =
                    sourceAnimation.beginTime
                replacement.timeOffset =
                    sourceAnimation.timeOffset
                replacement.repeatCount =
                    sourceAnimation.repeatCount
                replacement.autoreverses =
                    sourceAnimation.autoreverses

                updatedAnimation = replacement
            }
        }

        // After method_exchangeImplementations(), this selector points
        // to CALayer's original addAnimation:forKey: implementation.
        nagi_addAnimation(
            updatedAnimation,
            forKey: key
        )
    }
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
            // Match Nagram ComponentTransition exactly:
            // enter the CALayer spring-override scope before UIKit creates
            // its spring animations, then leave the scope immediately after
            // UIView.animate has synchronously installed them.
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

    func setFrame(view: UIView, frame: CGRect) {
        let targetFrame = frame
        let layer = view.layer
        let fromPosition = presentationPosition(
            for: layer,
            animationKeys: [
                nagiPositionAnimationKey,
                nagiFullBoundsAnimationKey,
                nagiBoundsAnimationKey
            ]
        )
        let fromBounds = presentationBounds(
            for: layer,
            animationKeys: [nagiBoundsAnimationKey, nagiFullBoundsAnimationKey]
        )

        setModelValue {
            if view.transform == .identity {
                view.frame = targetFrame
            } else {
                view.bounds = CGRect(origin: view.bounds.origin, size: targetFrame.size)
                view.center = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
            }
        }

        guard !isImmediate else {
            removeAnimation(from: layer, forKey: nagiPositionAnimationKey)
            removeAnimation(from: layer, forKey: nagiBoundsAnimationKey)
            removeAnimation(from: layer, forKey: nagiFullBoundsAnimationKey)
            return
        }

        let toPosition = layer.position
        let toBoundsSize = layer.bounds.size
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
        if fromBounds.size != toBoundsSize {
            addAnimation(
                makeAnimation(
                    keyPath: nagiBoundsAnimationKey,
                    fromValue: NSValue(cgSize: fromBounds.size),
                    toValue: NSValue(cgSize: toBoundsSize)
                ),
                to: layer,
                forKey: nagiBoundsAnimationKey
            )
        }
    }

    func setBounds(view: UIView, bounds: CGRect) {
        let layer = view.layer
        let fromBounds = presentationBounds(
            for: layer,
            animationKeys: [nagiBoundsAnimationKey, nagiFullBoundsAnimationKey]
        )
        setModelValue {
            view.bounds = bounds
        }

        guard !isImmediate else {
            removeAnimation(from: layer, forKey: nagiBoundsAnimationKey)
            removeAnimation(from: layer, forKey: nagiFullBoundsAnimationKey)
            return
        }

        let toBounds = layer.bounds
        guard fromBounds != toBounds else { return }
        let boundsAnimationKey = fromBounds.origin == toBounds.origin
            ? nagiBoundsAnimationKey
            : nagiFullBoundsAnimationKey
        let fromValue: NSValue
        let toValue: NSValue
        if boundsAnimationKey == nagiBoundsAnimationKey {
            fromValue = NSValue(cgSize: fromBounds.size)
            toValue = NSValue(cgSize: toBounds.size)
        } else {
            fromValue = NSValue(cgRect: fromBounds)
            toValue = NSValue(cgRect: toBounds)
        }
        addAnimation(
            makeAnimation(
                keyPath: boundsAnimationKey,
                fromValue: fromValue,
                toValue: toValue
            ),
            to: layer,
            forKey: boundsAnimationKey
        )
    }

    func setPosition(view: UIView, position: CGPoint) {
        let layer = view.layer
        let fromPosition = presentationPosition(
            for: layer,
            animationKeys: [nagiPositionAnimationKey]
        )
        setModelValue {
            layer.position = position
        }

        guard !isImmediate else {
            removeAnimation(from: layer, forKey: nagiPositionAnimationKey)
            return
        }

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
        if additive {
            removeAnimation(from: layer, forKey: animationKey)
        }
        addAnimation(
            animation,
            to: layer,
            forKey: animationKey
        )
    }

    func setAlpha(
        view: UIView,
        alpha: CGFloat,
        completion: ((Bool) -> Void)? = nil
    ) {
        let layer = view.layer
        let fromOpacity = presentationOpacity(
            for: layer,
            animationKeys: [nagiOpacityAnimationKey]
        )
        setModelValue {
            view.alpha = alpha
        }

        guard !isImmediate else {
            removeAnimation(from: layer, forKey: nagiOpacityAnimationKey)
            completion?(true)
            return
        }
        let toOpacity = layer.opacity
        guard abs(CGFloat(fromOpacity) - CGFloat(toOpacity)) > 0.0001 else {
            completion?(true)
            return
        }
        addAnimation(
            makeAnimation(
                keyPath: "opacity",
                fromValue: fromOpacity,
                toValue: toOpacity
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
        let fromTransform = presentationTransform(
            for: layer,
            animationKeys: [nagiTransformAnimationKey]
        )
        setModelValue {
            view.transform = CGAffineTransform(scaleX: scale, y: scale)
        }

        guard !isImmediate else {
            removeAnimation(from: layer, forKey: nagiTransformAnimationKey)
            completion?(true)
            return
        }
        let toTransform = layer.transform
        guard !CATransform3DEqualToTransform(fromTransform, toTransform) else {
            completion?(true)
            return
        }
        addAnimation(
            makeAnimation(
                keyPath: "transform",
                fromValue: NSValue(caTransform3D: fromTransform),
                toValue: NSValue(caTransform3D: toTransform)
            ),
            to: layer,
            forKey: nagiTransformAnimationKey,
            delay: delay,
            completion: completion
        )
    }

    func setCornerRadius(view: UIView, radius: CGFloat) {
        let layer = view.layer
        let fromRadius = presentationCornerRadius(
            for: layer,
            animationKeys: [nagiCornerRadiusAnimationKey, "cornerRadius"]
        )
        removeAnimation(from: layer, forKey: nagiCornerRadiusAnimationKey)
        removeAnimation(from: layer, forKey: "cornerRadius")
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

    func setTintColor(view: UIView, color: UIColor) {
        guard !view.tintColor.isEqual(color) else {
            return
        }

        if isImmediate {
            setModelValue {
                view.tintColor = color
            }
        } else {
            animateView {
                view.tintColor = color
            }
        }
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
        delay: TimeInterval = 0,
        completion: ((Bool) -> Void)? = nil
    ) {
        let context = currentContext()
        if delay > 0 {
            animation.beginTime = layer.convertTime(
                CACurrentMediaTime(),
                from: nil
            ) + delay
            animation.fillMode = .both
        }

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

    private func presentationPosition(
        for layer: CALayer,
        animationKeys: [String]
    ) -> CGPoint {
        guard hasAnimation(on: layer, keys: animationKeys),
              let presentation = layer.presentation() else {
            return layer.position
        }
        return presentation.position
    }

    private func presentationBounds(
        for layer: CALayer,
        animationKeys: [String]
    ) -> CGRect {
        guard hasAnimation(on: layer, keys: animationKeys),
              let presentation = layer.presentation() else {
            return layer.bounds
        }
        return presentation.bounds
    }

    private func presentationOpacity(
        for layer: CALayer,
        animationKeys: [String]
    ) -> Float {
        guard hasAnimation(on: layer, keys: animationKeys),
              let presentation = layer.presentation() else {
            return layer.opacity
        }
        return presentation.opacity
    }

    private func presentationTransform(
        for layer: CALayer,
        animationKeys: [String]
    ) -> CATransform3D {
        guard hasAnimation(on: layer, keys: animationKeys),
              let presentation = layer.presentation() else {
            return layer.transform
        }
        return presentation.transform
    }

    private func presentationCornerRadius(
        for layer: CALayer,
        animationKeys: [String]
    ) -> CGFloat {
        guard hasAnimation(on: layer, keys: animationKeys),
              let presentation = layer.presentation() else {
            return layer.cornerRadius
        }
        return presentation.cornerRadius
    }

    private func hasAnimation(on layer: CALayer, keys: [String]) -> Bool {
        keys.contains { layer.animation(forKey: $0) != nil }
    }

    private func makeAnimation(
        keyPath: String,
        fromValue: Any,
        toValue: Any
    ) -> CAAnimation {
        switch self {
        case let .spring(duration):
            // Nagram has a dedicated 0.5-second spring path.
            //
            // This must be checked before the ordinary cubic spring path.
            if duration == 0.5 {
                let animation = CASpringAnimation(keyPath: keyPath)
                animation.fromValue = fromValue
                animation.toValue = toValue

                if #available(iOS 26.0, *) {
                    // Exact values from Nagram/UIKitRuntimeUtils.
                    animation.mass = 1.0
                    animation.stiffness = 555.027
                    animation.damping = 47.118
                    animation.duration = duration
                    animation.timingFunction = CAMediaTimingFunction(name: .linear)

                    if #available(iOS 17.0, *) {
                        animation.allowsOverdamping = false
                    }

                    // Nagram's make26SpringAnimationImpl applies this
                    // private high-frame-rate reason.
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
                    // Nagram pre-iOS-26 makeSpringAnimationImpl.
                    animation.mass = 3.0
                    animation.stiffness = 1000.0
                    animation.damping = 500.0
                    animation.duration = 0.5
                    animation.timingFunction = CAMediaTimingFunction(name: .linear)
                }

                animation.isRemovedOnCompletion = true
                animation.fillMode = .forwards

                // Match Nagram CAAnimationUtils.adjustFrameRate(). Opacity
                // is intentionally excluded so iOS 26 keeps its 80/120/120
                // range and pre-iOS-26 receives no explicit range.
                if #available(iOS 15.0, *) {
                    let maximumFPS = Float(UIScreen.main.maximumFramesPerSecond)
                    if maximumFPS > 61.0, keyPath != "opacity" {
                        animation.preferredFrameRateRange = CAFrameRateRange(
                            minimum: 30.0,
                            maximum: maximumFPS,
                            preferred: maximumFPS
                        )
                    }
                }

                return animation
            }

            // Ordinary Nagram ComponentTransition spring.
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
