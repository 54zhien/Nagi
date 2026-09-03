
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

#if targetEnvironment(simulator)
@_silgen_name("UIAnimationDragCoefficient")
private func nagiUIAnimationDragCoefficient() -> Float
#endif

private var nagiAnimationDurationFactor: Double {
    #if targetEnvironment(simulator)
    return Double(nagiUIAnimationDragCoefficient())
    #else
    return 1.0
    #endif
}

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
            assertionFailure("Unable to install CALayer spring override")
            return
        }

        method_exchangeImplementations(originalMethod, replacementMethod)
        isInstalled = true
    }
}

private extension CALayer {
    @objc func nagi_addAnimation(_ animation: CAAnimation, forKey key: String?) {
        var updatedAnimation = animation

        if NagiLayerSpringOverride.isActive,
           let sourceAnimation = animation as? CASpringAnimation {
            let keepNativeSpring: Bool
            if #available(iOS 26.0, *),
               abs(sourceAnimation.duration - 0.3832) <= 0.0001 {
                keepNativeSpring = true
            } else if abs(sourceAnimation.duration - 0.5) <= 0.0001 {
                keepNativeSpring = true
            } else {
                keepNativeSpring = false
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
                replacement.beginTime = sourceAnimation.beginTime
                replacement.timeOffset = sourceAnimation.timeOffset
                replacement.repeatCount = sourceAnimation.repeatCount
                replacement.autoreverses = sourceAnimation.autoreverses
                replacement.delegate = sourceAnimation.delegate

                var speed: Float = 1.0
                let factor = Float(nagiAnimationDurationFactor)
                if factor != 0, factor != 1 {
                    speed = 1.0 / factor
                }
                replacement.speed = speed * sourceAnimation.speed

                if #available(iOS 15.0, *) {
                    replacement.preferredFrameRateRange = sourceAnimation.preferredFrameRateRange
                }
                updatedAnimation = replacement
            }
        }

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

    func perform(_ changes: () -> Void, completion: ((Bool) -> Void)? = nil) {
        guard !isImmediate else {
            changes()
            completion?(true)
            return
        }

        let context = NagiTransitionCompletionContext(completion: completion)
        let dictionary = Thread.current.threadDictionary
        let previousContext = dictionary[nagiTransitionContextThreadKey]
        dictionary[nagiTransitionContextThreadKey] = context

        changes()

        if let previousContext {
            dictionary[nagiTransitionContextThreadKey] = previousContext
        } else {
            dictionary.removeObject(forKey: nagiTransitionContextThreadKey)
        }
        context.finishIfPossible()
    }

    func animateView(
        allowUserInteraction: Bool = true,
        delay: TimeInterval = 0,
        _ changes: @escaping () -> Void,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard !isImmediate else {
            changes()
            completion?(true)
            return
        }

        var options: UIView.AnimationOptions
        switch self {
        case .immediate:
            options = []
        case .easeInOut:
            options = [.curveEaseInOut]
        case .spring:
            options = UIView.AnimationOptions(rawValue: 7 << 16)
        case let .keyboard(_, curve):
            options = curve
        }
        if allowUserInteraction {
            options.insert(.allowUserInteraction)
        }

        let context = currentContext()
        context?.registerAnimation()
        var didFinish = false
        let finish: (Bool) -> Void = { flag in
            guard !didFinish else { return }
            didFinish = true
            completion?(flag)
            context?.animationDidStop(finished: flag)
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
                completion: finish
            )
            NagiLayerSpringOverride.pop()
        default:
            UIView.animate(
                withDuration: duration,
                delay: delay,
                options: options,
                animations: changes,
                completion: finish
            )
        }
    }

    func setFrame(
        view: UIView,
        frame: CGRect,
        completion: ((Bool) -> Void)? = nil
    ) {
        if view.frame == frame {
            completion?(true)
            return
        }

        if isImmediate {
            view.frame = frame
            view.layer.removeAnimation(forKey: nagiPositionAnimationKey)
            view.layer.removeAnimation(forKey: nagiBoundsAnimationKey)
            view.layer.removeAnimation(forKey: nagiBoundsSizeAnimationKey)
            completion?(true)
            return
        }

        let layer = view.layer
        let previousPosition: CGPoint
        let previousBounds: CGRect
        if hasAnimation(
            on: layer,
            keys: [nagiPositionAnimationKey, nagiBoundsAnimationKey, nagiBoundsSizeAnimationKey]
        ), let presentation = layer.presentation() {
            previousPosition = presentation.position
            previousBounds = presentation.bounds
        } else {
            previousPosition = layer.position
            previousBounds = layer.bounds
        }

        view.frame = frame
        let anchorPoint = layer.anchorPoint
        let updatedPosition = CGPoint(
            x: frame.minX + frame.width * anchorPoint.x,
            y: frame.minY + frame.height * anchorPoint.y
        )

        animatePositionInternal(
            layer: layer,
            from: previousPosition,
            to: updatedPosition,
            additive: false,
            completion: completion
        )
        if previousBounds.size != frame.size {
            animateBoundsSizeInternal(
                layer: layer,
                from: previousBounds.size,
                to: frame.size
            )
        }
    }

    func setBounds(
        view: UIView,
        bounds: CGRect,
        completion: ((Bool) -> Void)? = nil
    ) {
        if view.bounds == bounds {
            completion?(true)
            return
        }

        if isImmediate {
            view.bounds = bounds
            view.layer.removeAnimation(forKey: nagiBoundsAnimationKey)
            view.layer.removeAnimation(forKey: nagiBoundsOriginAnimationKey)
            view.layer.removeAnimation(forKey: nagiBoundsSizeAnimationKey)
            completion?(true)
            return
        }

        let layer = view.layer
        let previousBounds: CGRect
        if hasAnimation(
            on: layer,
            keys: [nagiBoundsAnimationKey, nagiBoundsOriginAnimationKey, nagiBoundsSizeAnimationKey]
        ), let presentation = layer.presentation() {
            previousBounds = presentation.bounds
        } else {
            previousBounds = layer.bounds
        }

        view.bounds = bounds
        animateBoundsInternal(
            layer: layer,
            from: previousBounds,
            to: bounds,
            completion: completion
        )
    }

    func setPosition(
        view: UIView,
        position: CGPoint,
        completion: ((Bool) -> Void)? = nil
    ) {
        if view.center == position {
            completion?(true)
            return
        }

        if isImmediate {
            view.center = position
            view.layer.removeAnimation(forKey: nagiPositionAnimationKey)
            completion?(true)
            return
        }

        let layer = view.layer
        let previousPosition: CGPoint
        if layer.animation(forKey: nagiPositionAnimationKey) != nil,
           let presentation = layer.presentation() {
            previousPosition = presentation.position
        } else {
            previousPosition = layer.position
        }

        view.center = position
        animatePositionInternal(
            layer: layer,
            from: previousPosition,
            to: view.center,
            additive: false,
            completion: completion
        )
    }

    func animatePosition(
        layer: CALayer,
        from: CGPoint,
        to: CGPoint,
        additive: Bool,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard !isImmediate else {
            completion?(true)
            return
        }
        animatePositionInternal(
            layer: layer,
            from: from,
            to: to,
            additive: additive,
            completion: completion
        )
    }

    func setAlpha(
        view: UIView,
        alpha: CGFloat,
        completion: ((Bool) -> Void)? = nil
    ) {
        if view.alpha == alpha {
            completion?(true)
            return
        }

        if isImmediate {
            view.alpha = alpha
            view.layer.removeAnimation(forKey: nagiOpacityAnimationKey)
            completion?(true)
            return
        }

        let layer = view.layer
        let previousAlpha: Float
        if layer.animation(forKey: nagiOpacityAnimationKey) != nil {
            previousAlpha = layer.presentation()?.opacity ?? Float(view.alpha)
        } else {
            previousAlpha = Float(view.alpha)
        }

        view.alpha = alpha
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
        let targetTransform = CATransform3DMakeScale(scale, scale, 1.0)
        if CATransform3DEqualToTransform(layer.transform, targetTransform) {
            completion?(true)
            return
        }

        if isImmediate {
            layer.transform = targetTransform
            layer.removeAnimation(forKey: nagiTransformScaleAnimationKey)
            completion?(true)
            return
        }

        let previousScale: CGFloat
        if layer.animation(forKey: nagiTransformScaleAnimationKey) != nil,
           let presentation = layer.presentation() {
            previousScale = scaleValue(of: presentation.transform)
        } else {
            previousScale = scaleValue(of: layer.transform)
        }

        layer.transform = targetTransform
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
        setCornerRadius(layer: view.layer, radius: radius)
    }

    func setCornerRadius(layer: CALayer, radius: CGFloat) {
        guard layer.cornerRadius != radius else { return }

        if isImmediate {
            layer.cornerRadius = radius
            layer.removeAnimation(forKey: nagiCornerRadiusAnimationKey)
            return
        }

        let previousValue: CGFloat
        if layer.animation(forKey: nagiCornerRadiusAnimationKey) != nil,
           let presentation = layer.presentation() {
            previousValue = presentation.cornerRadius
        } else {
            previousValue = layer.cornerRadius
        }

        layer.cornerRadius = radius
        addAnimation(
            makeAnimation(
                keyPath: nagiCornerRadiusAnimationKey,
                fromValue: previousValue,
                toValue: radius
            ),
            to: layer,
            forKey: nagiCornerRadiusAnimationKey
        )
    }

    func setTintColor(
        view: UIView,
        color: UIColor,
        completion: ((Bool) -> Void)? = nil
    ) {
        if let current = view.tintColor, current.isEqual(color) {
            completion?(true)
            return
        }

        let previous = view.tintColor ?? .clear
        view.tintColor = color
        guard !isImmediate else {
            completion?(true)
            return
        }

        addAnimation(
            makeAnimation(
                keyPath: nagiTintAnimationKey,
                fromValue: previous,
                toValue: color.cgColor
            ),
            to: view.layer,
            forKey: nagiTintAnimationKey,
            completion: completion
        )
    }

    func setBlur(layer: CALayer, radius: CGFloat) {
        let currentRadius = modelBlurRadius(on: layer)
        guard currentRadius != radius,
              let filter = makeGaussianBlurFilter(radius: radius) else {
            return
        }

        layer.filters = [filter]
        guard !isImmediate else {
            if radius <= 0 { layer.filters = nil }
            return
        }

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

    private func animatePositionInternal(
        layer: CALayer,
        from: CGPoint,
        to: CGPoint,
        additive: Bool,
        completion: ((Bool) -> Void)? = nil
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
            forKey: additive ? nil : nagiPositionAnimationKey,
            completion: completion
        )
    }

    private func animateBoundsInternal(
        layer: CALayer,
        from: CGRect,
        to: CGRect,
        completion: ((Bool) -> Void)? = nil
    ) {
        addAnimation(
            makeAnimation(
                keyPath: nagiBoundsAnimationKey,
                fromValue: NSValue(cgRect: from),
                toValue: NSValue(cgRect: to)
            ),
            to: layer,
            forKey: nagiBoundsAnimationKey,
            completion: completion
        )
    }

    private func animateBoundsSizeInternal(layer: CALayer, from: CGSize, to: CGSize) {
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

    private func makeAnimation(
        keyPath: String,
        fromValue: Any,
        toValue: Any
    ) -> CAAnimation {
        switch self {
        case let .spring(duration):
            if (#available(iOS 26.0, *) && abs(duration - 0.3832) <= 0.0001) || duration == 0.5 {
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
                    if #available(iOS 15.0, *) {
                        animation.setValue(NSNumber(value: 1048619), forKey: "highFrameRateReason")
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
                animation.speed = animationSpeed(
                    naturalDuration: animation.duration,
                    requestedDuration: duration
                )
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
            animation.speed = baseAnimationSpeed
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
            animation.speed = baseAnimationSpeed
            adjustFrameRate(animation: animation, keyPath: keyPath)
            return animation
        }
    }

    private func addAnimation(
        _ animation: CAAnimation,
        to layer: CALayer,
        forKey key: String?,
        delay: TimeInterval = 0,
        completion: ((Bool) -> Void)? = nil
    ) {
        if delay > 0 {
            animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
                + delay * nagiAnimationDurationFactor
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

    private var baseAnimationSpeed: Float {
        let factor = Float(nagiAnimationDurationFactor)
        if factor != 0, factor != 1 { return 1.0 / factor }
        return 1.0
    }

    private func animationSpeed(
        naturalDuration: TimeInterval,
        requestedDuration: TimeInterval
    ) -> Float {
        guard requestedDuration > 0 else { return baseAnimationSpeed }
        return baseAnimationSpeed * Float(naturalDuration / requestedDuration)
    }

    private func adjustFrameRate(animation: CAAnimation, keyPath: String) {
        guard #available(iOS 15.0, *) else { return }
        let maximumFPS = Float(UIScreen.main.maximumFramesPerSecond)
        guard maximumFPS > 61.0 else { return }

        if keyPath == nagiOpacityAnimationKey { return }

        animation.preferredFrameRateRange = CAFrameRateRange(
            minimum: 30.0,
            maximum: maximumFPS,
            preferred: maximumFPS
        )
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
            } else if curve.contains(.curveEaseOut) {
                return CAMediaTimingFunction(name: .easeOut)
            } else if curve.contains(.curveLinear) {
                return CAMediaTimingFunction(name: .linear)
            }
            return CAMediaTimingFunction(name: .easeInEaseOut)
        }
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
            transform.m11 * transform.m11
            + transform.m12 * transform.m12
            + transform.m13 * transform.m13
        )
    }

    private func modelBlurRadius(on layer: CALayer) -> CGFloat {
        guard let filters = layer.filters else { return 0 }
        for value in filters {
            if let object = value as? NSObject,
               object.description.contains("gaussianBlur") {
                return object.value(forKey: "inputRadius") as? CGFloat ?? 0
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
