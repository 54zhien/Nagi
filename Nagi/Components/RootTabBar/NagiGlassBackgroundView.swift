import ObjectiveC.runtime
import QuartzCore
import UIKit

struct NagiGlassParams: Equatable {
    var size: CGSize
    var cornerRadius: CGFloat
    var isDark: Bool
    var tintColor: UIColor?
    var reduceTransparency: Bool

    static func == (lhs: NagiGlassParams, rhs: NagiGlassParams) -> Bool {
        lhs.size == rhs.size &&
        lhs.cornerRadius == rhs.cornerRadius &&
        lhs.isDark == rhs.isDark &&
        colorsEqual(lhs.tintColor, rhs.tintColor) &&
        lhs.reduceTransparency == rhs.reduceTransparency
    }

    static func colorsEqual(_ lhs: UIColor?, _ rhs: UIColor?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs.isEqual(rhs)
        default:
            return false
        }
    }
}

final class NagiEffectSettingsContainerView: UIView {
    var lumaMin: Double = 0
    var lumaMax: Double = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        if window != nil {
            NagiGlassEffectRuntime.installIfNeeded()
        }
        super.didMoveToWindow()
    }
}

enum NagiGlassEffectRuntime {
    private static var isInstalled = false

    static func installIfNeeded() {
        guard !isInstalled else { return }

        let className =
            "_TtC5UIKitP33_ACD4A08F4BE9D00246F2A9C24A80CA8817UISDFBackdropView"
        let selector = NSSelectorFromString("backdropLayer:didChangeLuma:")

        guard
            let cls = NSClassFromString(className),
            let method = class_getInstanceMethod(cls, selector)
        else {
            return
        }

        guard let typeEncodingPointer = method_getTypeEncoding(method) else {
            return
        }
        let typeEncoding = String(cString: typeEncodingPointer)
        guard typeEncoding == "v32@0:8@16d24" else {
            return
        }

        typealias OriginalIMP = @convention(c) (
            AnyObject,
            Selector,
            CALayer,
            Double
        ) -> Void

        let original = unsafeBitCast(
            method_getImplementation(method),
            to: OriginalIMP.self
        )

        let block: @convention(block) (
            AnyObject,
            CALayer,
            Double
        ) -> Void = { object, layer, luma in
            var resolvedLuma = luma

            if let view = object as? UIView,
               let container = findEffectContainer(from: view) {
                resolvedLuma = min(
                    max(luma, container.lumaMin),
                    container.lumaMax
                )
            }

            original(object, selector, layer, resolvedLuma)
        }

        let replacement = imp_implementationWithBlock(block)
        method_setImplementation(method, replacement)
        isInstalled = true
    }

    private static func findEffectContainer(
        from view: UIView
    ) -> NagiEffectSettingsContainerView? {
        var current: UIView? = view
        var depth = 0

        while let value = current, depth <= 10 {
            if let container = value as? NagiEffectSettingsContainerView {
                return container
            }
            current = value.superview
            depth += 1
        }

        return nil
    }
}

final class NagiGlassBackgroundView: UIView {
    var contentView: UIView {
        effectView.contentView
    }

    private let effectView: UIVisualEffectView
    private let nativeParamsView: NagiEffectSettingsContainerView
    private let opaqueView: UIView
    private var previousParams: NagiGlassParams?
    private var currentEffectKey: String?
    private var currentTintColor: UIColor?
    private var currentUsesNativeLiquidGlass: Bool?
    private var hasPendingEffect = false
    private var pendingEffect: UIVisualEffect?

    override init(frame: CGRect) {
        effectView = UIVisualEffectView(effect: nil)
        nativeParamsView = NagiEffectSettingsContainerView(frame: .zero)
        opaqueView = UIView(frame: .zero)
        super.init(frame: frame)

        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = false
        layer.cornerCurve = .continuous

        opaqueView.backgroundColor = .secondarySystemBackground
        opaqueView.isUserInteractionEnabled = false
        opaqueView.clipsToBounds = true
        opaqueView.layer.cornerCurve = .continuous

        effectView.backgroundColor = .clear
        effectView.isOpaque = false
        effectView.clipsToBounds = true
        effectView.layer.cornerCurve = .continuous
        effectView.contentView.backgroundColor = .clear
        effectView.contentView.isOpaque = false

        nativeParamsView.addSubview(effectView)
        addSubview(opaqueView)
        addSubview(nativeParamsView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled,
              !isHidden,
              alpha != 0 else {
            return nil
        }

        for view in contentView.subviews.reversed() {
            if let result = view.hitTest(
                convert(point, to: view),
                with: event
            ), result.isUserInteractionEnabled {
                return result
            }
        }

        guard let result = contentView.hitTest(
            convert(point, to: contentView),
            with: event
        ), result !== contentView else {
            return nil
        }
        return result
    }

    @discardableResult
    func prepare(params: NagiGlassParams) -> Bool {
        let usesNativeLiquidGlass = NagiGlassStyleStore.usesNativeLiquidGlass
        guard params != previousParams
            || usesNativeLiquidGlass != currentUsesNativeLiquidGlass else {
            return false
        }

        previousParams = params
        currentUsesNativeLiquidGlass = usesNativeLiquidGlass

        let effectKey = "\(usesNativeLiquidGlass)|\(params.reduceTransparency)|\(params.isDark)"
        let tintChanged = !NagiGlassParams.colorsEqual(
            currentTintColor,
            params.tintColor
        )
        let shouldRebuildEffect = currentEffectKey != effectKey
            || tintChanged

        if shouldRebuildEffect {
            let effect: UIVisualEffect?
            if usesNativeLiquidGlass && !params.reduceTransparency {
                let glassEffect = UIGlassEffect(style: .regular)
                glassEffect.tintColor = params.tintColor
                glassEffect.isInteractive = true
                effect = glassEffect
            } else {
                effect = nil
            }
            pendingEffect = effect
            hasPendingEffect = true
            currentEffectKey = effectKey
            currentTintColor = params.tintColor
        }

        effectView.overrideUserInterfaceStyle = params.isDark ? .dark : .light
        opaqueView.overrideUserInterfaceStyle = params.isDark ? .dark : .light

        if usesNativeLiquidGlass && !params.reduceTransparency {
            if params.isDark {
                nativeParamsView.lumaMin = 0.0
                nativeParamsView.lumaMax = 0.15
            } else {
                nativeParamsView.lumaMin = 0.8
                nativeParamsView.lumaMax = 0.801
            }
        } else {
            nativeParamsView.lumaMin = 0
            nativeParamsView.lumaMax = 1
        }

        opaqueView.isHidden = usesNativeLiquidGlass && !params.reduceTransparency
        effectView.contentView.backgroundColor = .clear

        return true
    }

    func applyGeometry(
        params: NagiGlassParams,
        transition: NagiTabTransition,
        applyVisibility: Bool = true
    ) {
        let targetFrame = CGRect(origin: .zero, size: params.size)

        transition.setFrame(view: opaqueView, frame: targetFrame)
        transition.setFrame(view: nativeParamsView, frame: targetFrame)
        if effectView.frame != targetFrame {
            transition.animateView {
                self.effectView.frame = targetFrame
            }
        }

        if hasPendingEffect {
            let effect = pendingEffect
            hasPendingEffect = false
            pendingEffect = nil
            transition.animateView {
                self.effectView.effect = effect
            }
        }

        transition.setCornerRadius(
            view: opaqueView,
            radius: params.cornerRadius
        )
        transition.setCornerRadius(
            view: effectView,
            radius: params.cornerRadius
        )
        transition.setCornerRadius(
            view: self,
            radius: params.cornerRadius
        )

        if applyVisibility {
            transition.setAlpha(view: self, alpha: 1)
        }
    }

    func update(
        params: NagiGlassParams,
        transition: NagiTabTransition
    ) {
        _ = prepare(params: params)
        applyGeometry(params: params, transition: transition)
    }
}
