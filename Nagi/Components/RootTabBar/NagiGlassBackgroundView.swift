//
//  NagiGlassBackgroundView.swift
//  Nagi
//
//  单个持久化 native Glass surface。项目最低部署版本为 iOS 26，
//  因此这里只保留 UIGlassEffect 路径；尺寸、圆角和透明度变化不会
//  重建 effect view，也不会把内容延迟到下一轮 layout。
//

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

private protocol NagiGlassTintMaskProviding: AnyObject {
    var tintMask: UIView { get }
}

private final class NagiGlassContentLayer: CALayer {
    weak var targetLayer: CALayer?

    override init() {
        super.init()
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var position: CGPoint {
        get { return super.position }
        set {
            targetLayer?.position = newValue
            super.position = newValue
        }
    }

    override var bounds: CGRect {
        get { return super.bounds }
        set {
            targetLayer?.bounds = newValue
            super.bounds = newValue
        }
    }

    override var anchorPoint: CGPoint {
        get { return super.anchorPoint }
        set {
            targetLayer?.anchorPoint = newValue
            super.anchorPoint = newValue
        }
    }

    override var anchorPointZ: CGFloat {
        get { return super.anchorPointZ }
        set {
            targetLayer?.anchorPointZ = newValue
            super.anchorPointZ = newValue
        }
    }

    override var opacity: Float {
        get { return super.opacity }
        set {
            targetLayer?.opacity = newValue
            super.opacity = newValue
        }
    }

    override var sublayerTransform: CATransform3D {
        get { return super.sublayerTransform }
        set {
            targetLayer?.sublayerTransform = newValue
            super.sublayerTransform = newValue
        }
    }

    override var transform: CATransform3D {
        get { return super.transform }
        set {
            targetLayer?.transform = newValue
            super.transform = newValue
        }
    }

    override func add(_ animation: CAAnimation, forKey key: String?) {
        targetLayer?.add(animation, forKey: key)
        super.add(animation, forKey: key)
    }

    override func removeAllAnimations() {
        targetLayer?.removeAllAnimations()
        super.removeAllAnimations()
    }

    override func removeAnimation(forKey key: String) {
        targetLayer?.removeAnimation(forKey: key)
        super.removeAnimation(forKey: key)
    }
}

private final class NagiGlassContentContainer: UIView {
    private let maskContentView: UIView

    init(maskContentView: UIView) {
        self.maskContentView = maskContentView
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let result = super.hitTest(point, with: event) else {
            return nil
        }
        if result === self, (gestureRecognizers ?? []).isEmpty {
            return nil
        }
        return result
    }

    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        guard let tintMaskView = subview as? NagiGlassTintMaskProviding else {
            return
        }
        maskContentView.addSubview(tintMaskView.tintMask)
    }

    override func willRemoveSubview(_ subview: UIView) {
        if let tintMaskView = subview as? NagiGlassTintMaskProviding {
            tintMaskView.tintMask.removeFromSuperview()
        }
        super.willRemoveSubview(subview)
    }
}

private final class NagiGlassNativeParamsView: UIView {
    private let effectView: UIVisualEffectView

    var lumaMin: CGFloat = 0 {
        didSet { applyNativeValue(lumaMin, key: "lumaMin") }
    }

    var lumaMax: CGFloat = 1 {
        didSet { applyNativeValue(lumaMax, key: "lumaMax") }
    }

    init(effectView: UIVisualEffectView) {
        self.effectView = effectView
        super.init(frame: .zero)
        isUserInteractionEnabled = true
        clipsToBounds = false
        addSubview(effectView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        effectView.frame = bounds
    }

    private func applyNativeValue(_ value: CGFloat, key: String) {
        let setterName = "set\(key.prefix(1).uppercased())\(key.dropFirst()):"
        let setter = NSSelectorFromString(setterName)
        guard effectView.responds(to: setter) else { return }
        effectView.setValue(value, forKey: key)
    }
}

private final class NagiGlassContentProxyView: UIView {
    override class var layerClass: AnyClass {
        NagiGlassContentLayer.self
    }

    init(targetLayer: CALayer) {
        super.init(frame: .zero)
        isHidden = true
        isUserInteractionEnabled = false
        (layer as? NagiGlassContentLayer)?.targetLayer = targetLayer
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class NagiClippingShapeContext {
    private(set) var cornerRadius: CGFloat = 0

    func update(view: UIView, size: CGSize, cornerRadius: CGFloat) {
        self.cornerRadius = min(cornerRadius, min(size.width, size.height) * 0.5)
        view.layer.mask = nil
        view.layer.cornerRadius = self.cornerRadius
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
    }
}

final class NagiGlassBackgroundView: UIView {
    let contentView: UIView

    private let effectView: UIVisualEffectView
    private let nativeParamsView: NagiGlassNativeParamsView
    private let nativeContentProxy: NagiGlassContentProxyView
    private let fallbackView: UIView
    private let maskContainerView: UIView
    private let maskContentView: UIView
    private let contentContainer: NagiGlassContentContainer
    private let clippingShapeContext: NagiClippingShapeContext
    private var previousParams: NagiGlassParams?
    private var currentEffectKey: String?
    private var currentTintColor: UIColor?

    override init(frame: CGRect) {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = false
        let effectView = UIVisualEffectView(effect: effect)
        let nativeParamsView = NagiGlassNativeParamsView(effectView: effectView)
        let fallbackView = UIView(frame: .zero)
        let maskContainerView = UIView(frame: .zero)
        let maskContentView = UIView(frame: .zero)
        let contentContainer = NagiGlassContentContainer(maskContentView: maskContentView)

        self.effectView = effectView
        self.nativeParamsView = nativeParamsView
        self.nativeContentProxy = NagiGlassContentProxyView(
            targetLayer: effectView.contentView.layer
        )
        self.fallbackView = fallbackView
        self.maskContainerView = maskContainerView
        self.maskContentView = maskContentView
        self.contentContainer = contentContainer
        self.contentView = contentContainer
        self.clippingShapeContext = NagiClippingShapeContext()
        super.init(frame: frame)

        isUserInteractionEnabled = false
        clipsToBounds = false
        layer.cornerCurve = .continuous

        fallbackView.backgroundColor = .secondarySystemBackground
        fallbackView.isHidden = true
        fallbackView.isUserInteractionEnabled = false
        fallbackView.layer.cornerCurve = .continuous

        maskContainerView.isHidden = true
        maskContainerView.isUserInteractionEnabled = false
        maskContainerView.backgroundColor = .white
        maskContentView.isUserInteractionEnabled = false
        maskContainerView.addSubview(maskContentView)

        addSubview(fallbackView)
        addSubview(nativeParamsView)
        nativeParamsView.addSubview(nativeContentProxy)
        effectView.contentView.addSubview(contentContainer)
        addSubview(maskContainerView)
        contentContainer.backgroundColor = .clear
        contentContainer.isOpaque = false
        contentContainer.clipsToBounds = false
        contentContainer.layer.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fallbackView.frame = bounds
        nativeParamsView.frame = bounds
        nativeContentProxy.frame = nativeParamsView.bounds
        contentContainer.frame = effectView.contentView.bounds
        maskContainerView.frame = bounds
        maskContentView.frame = bounds
        fallbackView.layer.cornerRadius = layer.cornerRadius
        nativeParamsView.layer.cornerRadius = layer.cornerRadius
        effectView.layer.cornerRadius = layer.cornerRadius
        contentContainer.layer.cornerRadius = layer.cornerRadius
    }

    @discardableResult
    func prepare(params: NagiGlassParams) -> Bool {
        guard params != previousParams else {
            return false
        }
        let previousEffectKey = currentEffectKey
        previousParams = params

        let effectKey = "regular|\(params.isDark)|\(params.isInteractive)"
        let useFallback = params.reduceTransparency
        if !useFallback &&
            (effectKey != previousEffectKey ||
             !NagiGlassParams.colorsEqual(currentTintColor, params.tintColor) ||
             effectView.effect == nil) {
            let effect = UIGlassEffect(style: .regular)
            effect.tintColor = params.tintColor
            effect.isInteractive = params.isInteractive
            effectView.effect = effect
            effectView.overrideUserInterfaceStyle = params.isDark ? .dark : .light
            nativeParamsView.overrideUserInterfaceStyle = params.isDark ? .dark : .light
            currentEffectKey = effectKey
            currentTintColor = params.tintColor
        }

        nativeParamsView.lumaMin = params.isDark ? 0.0 : 0.8
        nativeParamsView.lumaMax = params.isDark ? 0.15 : 0.801

        fallbackView.isHidden = !useFallback
        // Keep the native content view mounted even when Reduce Transparency
        // is enabled. Removing only the effect preserves labels, controls and
        // hit testing over the solid fallback surface.
        effectView.isHidden = false
        if useFallback {
            effectView.effect = nil
        }
        return true
    }

    func applyGeometry(params: NagiGlassParams, applyVisibility: Bool = true) {
        let targetBounds = CGRect(origin: .zero, size: params.size)
        layer.cornerRadius = params.cornerRadius
        layer.cornerCurve = .continuous
        if applyVisibility {
            alpha = params.isVisible ? 1 : 0
        }

        fallbackView.frame = targetBounds
        nativeParamsView.frame = targetBounds
        nativeParamsView.layer.cornerRadius = params.cornerRadius
        effectView.frame = nativeParamsView.bounds
        effectView.layer.cornerRadius = params.cornerRadius
        nativeContentProxy.frame = nativeParamsView.bounds
        contentContainer.frame = effectView.contentView.bounds
        contentContainer.layer.cornerRadius = params.cornerRadius
        maskContainerView.frame = targetBounds
        maskContentView.frame = targetBounds
        clippingShapeContext.update(
            view: effectView,
            size: params.size,
            cornerRadius: params.cornerRadius
        )
        setNeedsLayout()
    }

    func update(params: NagiGlassParams) {
        guard prepare(params: params) else {
            return
        }
        applyGeometry(params: params)
    }
}
