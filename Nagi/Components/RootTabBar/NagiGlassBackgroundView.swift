//
//  NagiGlassBackgroundView.swift
//  Nagi
//
//  单个持久化 native Glass surface。Effect settings 通过与 Nagram 相同的
//  iOS 26 backdrop luma runtime hook 生效，surface 和 native effect 的
//  geometry 由调用方传入的同一个 NagiTabTransition 驱动。
//

import ObjectiveC.runtime
import QuartzCore
import UIKit

struct NagiGlassParams: Equatable {
    var size: CGSize
    var cornerRadius: CGFloat
    var isDark: Bool
    var tintColor: UIColor?
    var isInteractive: Bool
    var isVisible: Bool
    var reduceTransparency: Bool

    static func == (lhs: NagiGlassParams, rhs: NagiGlassParams) -> Bool {
        lhs.size == rhs.size &&
        lhs.cornerRadius == rhs.cornerRadius &&
        lhs.isDark == rhs.isDark &&
        colorsEqual(lhs.tintColor, rhs.tintColor) &&
        lhs.isInteractive == rhs.isInteractive &&
        lhs.isVisible == rhs.isVisible &&
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
        NagiGlassEffectRuntime.installIfNeeded()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private enum NagiGlassEffectRuntime {
    private static let installOnce: Void = {
        guard #available(iOS 26.0, *) else {
            return
        }

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
    }()

    static func installIfNeeded() {
        _ = installOnce
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
    private let fallbackView: UIView
    private var previousParams: NagiGlassParams?
    private var currentEffectKey: String?
    private var currentTintColor: UIColor?

    override init(frame: CGRect) {
        let glassEffect = UIGlassEffect(style: .regular)
        glassEffect.isInteractive = false

        let effectView = UIVisualEffectView(effect: glassEffect)
        let nativeParamsView = NagiEffectSettingsContainerView(frame: .zero)
        let fallbackView = UIView(frame: .zero)

        self.effectView = effectView
        self.nativeParamsView = nativeParamsView
        self.fallbackView = fallbackView
        super.init(frame: frame)

        clipsToBounds = false
        layer.cornerCurve = .continuous

        fallbackView.backgroundColor = .secondarySystemBackground
        fallbackView.isHidden = true
        fallbackView.isUserInteractionEnabled = false
        fallbackView.layer.cornerCurve = .continuous

        effectView.layer.cornerCurve = .continuous
        nativeParamsView.addSubview(effectView)

        addSubview(fallbackView)
        addSubview(nativeParamsView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @discardableResult
    func prepare(params: NagiGlassParams) -> Bool {
        guard params != previousParams else {
            return false
        }

        previousParams = params

        let effectKey = "regular|\(params.isDark)|\(params.isInteractive)"
        let useFallback = params.reduceTransparency
        let shouldRebuildEffect =
            !useFallback &&
            (
                currentEffectKey != effectKey ||
                !NagiGlassParams.colorsEqual(
                    currentTintColor,
                    params.tintColor
                ) ||
                effectView.effect == nil
            )

        if shouldRebuildEffect {
            let effect = UIGlassEffect(style: .regular)
            effect.tintColor = params.tintColor
            effect.isInteractive = params.isInteractive
            effectView.effect = effect
            currentEffectKey = effectKey
            currentTintColor = params.tintColor
        }

        effectView.overrideUserInterfaceStyle = params.isDark ? .dark : .light

        if params.isDark {
            nativeParamsView.lumaMin = 0.0
            nativeParamsView.lumaMax = 0.15
        } else {
            nativeParamsView.lumaMin = 0.8
            nativeParamsView.lumaMax = 0.801
        }

        fallbackView.isHidden = !useFallback

        if useFallback {
            effectView.effect = nil
        }

        return true
    }

    func applyGeometry(
        params: NagiGlassParams,
        transition: NagiTabTransition,
        applyVisibility: Bool = true
    ) {
        let targetFrame = CGRect(origin: .zero, size: params.size)

        transition.setFrame(view: fallbackView, frame: targetFrame)
        transition.setFrame(view: nativeParamsView, frame: targetFrame)
        transition.setFrame(view: effectView, frame: targetFrame)

        transition.setCornerRadius(
            view: fallbackView,
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
            transition.setAlpha(
                view: self,
                alpha: params.isVisible ? 1 : 0
            )
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
