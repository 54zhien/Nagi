//
//  NagiLiquidLensView.swift
//  Nagi
//
//  持久化的选中态 Lens。Main Glass、normal/selected content、resting
//  background 和 private _UILiquidLensView 都由这里统一管理。
//

import UIKit

struct NagiLensParams: Equatable {
    var size: CGSize
    var containerOrigin: CGPoint
    var selectionOrigin: CGPoint
    var selectionSize: CGSize
    var inset: CGFloat
    var liftedInset: CGFloat
    var isLifted: Bool
    var isCollapsed: Bool
    var reduceTransparency: Bool
}

private final class NagiLensRestingBackgroundView: UIView {
    private let blurView: UIVisualEffectView
    private let colorMatrixView: UIView

    override init(frame: CGRect) {
        self.blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        self.colorMatrixView = UIView(frame: .zero)
        super.init(frame: frame)

        isUserInteractionEnabled = false
        clipsToBounds = true
        layer.cornerCurve = .continuous
        blurView.isUserInteractionEnabled = false
        colorMatrixView.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
        colorMatrixView.isUserInteractionEnabled = false
        addSubview(blurView)
        addSubview(colorMatrixView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        blurView.frame = bounds
        colorMatrixView.frame = bounds
        blurView.layer.cornerRadius = layer.cornerRadius
        colorMatrixView.layer.cornerRadius = layer.cornerRadius
    }

    func apply(cornerRadius: CGFloat, reduceTransparency: Bool) {
        layer.cornerRadius = cornerRadius
        blurView.isHidden = reduceTransparency
        colorMatrixView.backgroundColor = reduceTransparency
            ? UIColor.systemBlue.withAlphaComponent(0.18)
            : UIColor.systemBlue.withAlphaComponent(0.12)
        setNeedsLayout()
    }
}

final class NagiLiquidLensView: UIView {
    private enum PrivateSelector {
        static let initWithRestingBackground = NSSelectorFromString("initWithRestingBackground:")
        static let setLiftedContainerView = NSSelectorFromString("setLiftedContainerView:")
        static let setLiftedContentView = NSSelectorFromString("setLiftedContentView:")
        static let setOverridePunchoutView = NSSelectorFromString("setOverridePunchoutView:")
        static let setLiftedContentMode = NSSelectorFromString("setLiftedContentMode:")
        static let setStyle = NSSelectorFromString("setStyle:")
        static let setWarpsContentBelow = NSSelectorFromString("setWarpsContentBelow:")
        static let setLifted = NSSelectorFromString("setLifted:animated:alongsideAnimations:completion:")
        static let setCollapsed = NSSelectorFromString("setCollapsed:")
        static let setRestingBackgroundColor = NSSelectorFromString("setRestingBackgroundColor:")
    }

    let contentView: UIView
    let selectedContentView: UIView
    let dedicatedMainGlassContainer: UIView

    private let mainSurface: NagiGlassBackgroundView
    private let selectionSurface: NagiGlassBackgroundView
    private let restingBackgroundView: NagiLensRestingBackgroundView
    private let nativeLensView: UIView?
    private var currentParams: NagiLensParams?
    private var isApplyingParams = false
    private var pendingParams: NagiLensParams?

    var usesPrivateLens: Bool {
        nativeLensView != nil
    }

    static var supportsNativeLiquidLens: Bool {
        guard #available(iOS 26.0, *) else {
            return false
        }
        return makePrivateLensView(restingBackground: UIView()) != nil
    }

    override init(frame: CGRect) {
        self.contentView = UIView(frame: .zero)
        self.selectedContentView = UIView(frame: .zero)
        self.dedicatedMainGlassContainer = UIView(frame: .zero)
        self.mainSurface = NagiGlassBackgroundView(frame: .zero)
        self.selectionSurface = NagiGlassBackgroundView(frame: .zero)
        self.restingBackgroundView = NagiLensRestingBackgroundView(frame: .zero)
        self.nativeLensView = Self.makePrivateLensView(restingBackground: restingBackgroundView)
        super.init(frame: frame)

        isUserInteractionEnabled = true
        clipsToBounds = false

        dedicatedMainGlassContainer.backgroundColor = .clear
        dedicatedMainGlassContainer.isOpaque = false
        dedicatedMainGlassContainer.clipsToBounds = false
        dedicatedMainGlassContainer.isUserInteractionEnabled = true
        addSubview(dedicatedMainGlassContainer)

        mainSurface.isUserInteractionEnabled = false
        dedicatedMainGlassContainer.addSubview(mainSurface)
        dedicatedMainGlassContainer.addSubview(restingBackgroundView)

        selectionSurface.isUserInteractionEnabled = false
        selectionSurface.alpha = 0
        dedicatedMainGlassContainer.addSubview(selectionSurface)

        selectedContentView.backgroundColor = .clear
        selectedContentView.isOpaque = false
        selectedContentView.isUserInteractionEnabled = false
        dedicatedMainGlassContainer.addSubview(selectedContentView)

        contentView.backgroundColor = .clear
        contentView.isOpaque = false
        contentView.isUserInteractionEnabled = true
        dedicatedMainGlassContainer.addSubview(contentView)

        if let nativeLensView {
            nativeLensView.isUserInteractionEnabled = false
            nativeLensView.layer.zPosition = 10
            addSubview(nativeLensView)
            nativeLensView.isHidden = false
            invoke(PrivateSelector.setLiftedContentMode, on: nativeLensView, integer: 1)
            invoke(PrivateSelector.setStyle, on: nativeLensView, integer: 1)
            invoke(PrivateSelector.setWarpsContentBelow, on: nativeLensView, boolean: true)
            if nativeLensView.responds(to: PrivateSelector.setRestingBackgroundColor) {
                nativeLensView.setValue(
                    UIColor(white: 0, alpha: 0.1),
                    forKey: "restingBackgroundColor"
                )
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The parent update owns presentation geometry. This callback only
        // participates in UIKit's normal bounds propagation for the view.
    }

    func configure(
        liftedContainerView: UIView,
        liftedContentView: UIView,
        punchoutView: UIView
    ) {
        guard let nativeLensView else {
            return
        }
        invoke(PrivateSelector.setLiftedContainerView, on: nativeLensView, object: liftedContainerView)
        invoke(PrivateSelector.setLiftedContentView, on: nativeLensView, object: liftedContentView)
        invoke(PrivateSelector.setOverridePunchoutView, on: nativeLensView, object: punchoutView)
    }

    func apply(
        params: NagiLensParams,
        isDark: Bool,
        transition: NagiTabTransition
    ) {
        if isApplyingParams {
            pendingParams = params
            return
        }
        guard params != currentParams else {
            return
        }

        let previousParams = currentParams
        currentParams = params
        let oldLifted = previousParams?.isLifted ?? false
        let shouldClip = !transition.isImmediate && previousParams != nil
        setResizeClipping(shouldClip)

        let mainCornerRadius = min(params.size.width, params.size.height) * 0.5
        let mainGlassParams = NagiGlassParams(
            size: params.size,
            cornerRadius: mainCornerRadius,
            isDark: isDark,
            tintColor: isDark
                ? UIColor.white.withAlphaComponent(0.025)
                : UIColor.white.withAlphaComponent(0.1),
            isInteractive: true,
            isVisible: true,
            reduceTransparency: params.reduceTransparency
        )
        mainSurface.prepare(params: mainGlassParams)

        let selectionSize = params.selectionSize
        let selectionCornerRadius = min(selectionSize.width, selectionSize.height) * 0.5
        let selectionGlassParams = NagiGlassParams(
            size: selectionSize,
            cornerRadius: selectionCornerRadius,
            isDark: isDark,
            tintColor: UIColor.systemBlue.withAlphaComponent(0.18),
            isInteractive: false,
            isVisible: !usesPrivateLens,
            reduceTransparency: params.reduceTransparency
        )
        selectionSurface.prepare(params: selectionGlassParams)

        isApplyingParams = true
        let alongsideAnimations = { [weak self] in
            guard let self else { return }
            self.applyPresentationGeometry(
                params: params,
                previousParams: previousParams,
                mainGlassParams: mainGlassParams,
                selectionGlassParams: selectionGlassParams,
                animated: !transition.isImmediate
            )
        }

        guard let nativeLensView,
              oldLifted != params.isLifted,
              nativeLensView.responds(to: PrivateSelector.setLifted) else {
            transition.animate(alongsideAnimations) { [weak self] _ in
                self?.finishApplyingPendingParams(transition: transition)
            }
            return
        }

        invoke(
            setCollapsed: params.isCollapsed,
            on: nativeLensView
        )
        invokeLifted(
            params: params,
            transition: transition,
            alongsideAnimations: alongsideAnimations
        )
    }

    private func applyPresentationGeometry(
        params: NagiLensParams,
        previousParams: NagiLensParams?,
        mainGlassParams: NagiGlassParams,
        selectionGlassParams: NagiGlassParams,
        animated: Bool
    ) {
        let containerFrame = CGRect(origin: params.containerOrigin, size: params.size)
        dedicatedMainGlassContainer.frame = containerFrame
        mainSurface.frame = dedicatedMainGlassContainer.bounds
        mainSurface.applyGeometry(params: mainGlassParams)
        selectedContentView.frame = dedicatedMainGlassContainer.bounds
        contentView.frame = dedicatedMainGlassContainer.bounds

        let selectionFrame = CGRect(origin: params.selectionOrigin, size: params.selectionSize)
        let effectiveInset: CGFloat
        if params.isCollapsed {
            effectiveInset = 0
        } else {
            effectiveInset = params.isLifted ? params.liftedInset : -params.inset
        }
        let lensFrame = selectionFrame.insetBy(dx: -effectiveInset, dy: -effectiveInset)
        selectionSurface.frame = lensFrame
        selectionSurface.applyGeometry(params: selectionGlassParams)
        selectionSurface.alpha = usesPrivateLens ? 0 : 1

        restingBackgroundView.frame = lensFrame
        restingBackgroundView.apply(
            cornerRadius: min(lensFrame.width, lensFrame.height) * 0.5,
            reduceTransparency: params.reduceTransparency
        )
        restingBackgroundView.alpha = params.isLifted || params.isCollapsed ? 0 : 1

        let newNativeSize = CGSize(
            width: max(0, params.selectionSize.width + effectiveInset * 2),
            height: max(0, params.selectionSize.height + effectiveInset * 2)
        )
        if let nativeLensView {
            let newCenter = CGPoint(
                x: params.containerOrigin.x + params.selectionOrigin.x + params.selectionSize.width * 0.5,
                y: params.containerOrigin.y + params.selectionOrigin.y + params.selectionSize.height * 0.5
            )
            let oldNativeSize = previousParams.map(nativeSize(for:))
            nativeLensView.bounds = CGRect(origin: .zero, size: newNativeSize)
            nativeLensView.center = newCenter
            nativeLensView.alpha = 1

            if animated,
               let oldNativeSize,
               oldNativeSize != newNativeSize {
                animatePosition(
                    layer: nativeLensView.layer,
                    from: CGPoint(
                        x: (newNativeSize.width - oldNativeSize.width) * 0.5,
                        y: 0
                    ),
                    to: .zero,
                    additive: true,
                    duration: 0.24
                )
            }
        }
    }

    private func nativeSize(for params: NagiLensParams) -> CGSize {
        let effectiveInset: CGFloat
        if params.isCollapsed {
            effectiveInset = 0
        } else {
            effectiveInset = params.isLifted ? params.liftedInset : -params.inset
        }
        return CGSize(
            width: max(0, params.selectionSize.width + effectiveInset * 2),
            height: max(0, params.selectionSize.height + effectiveInset * 2)
        )
    }

    private func setResizeClipping(_ clipped: Bool) {
        dedicatedMainGlassContainer.clipsToBounds = clipped
        contentView.clipsToBounds = clipped
        selectedContentView.clipsToBounds = clipped
    }

    private func animatePosition(
        layer: CALayer,
        from: CGPoint,
        to: CGPoint,
        additive: Bool,
        duration: TimeInterval
    ) {
        let animation = CABasicAnimation(keyPath: "position")
        animation.fromValue = NSValue(cgPoint: from)
        animation.toValue = NSValue(cgPoint: to)
        animation.isAdditive = additive
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "nagi.lens.positionCompensation")
    }

    private func invokeLifted(
        params: NagiLensParams,
        transition: NagiTabTransition,
        alongsideAnimations: @escaping () -> Void
    ) {
        guard let nativeLensView,
              let method = nativeLensView.method(for: PrivateSelector.setLifted) else {
            transition.animate(alongsideAnimations) { [weak self] _ in
                self?.finishApplyingPendingParams(transition: transition)
            }
            return
        }

        typealias ObjCMethod = @convention(c) (
            AnyObject,
            Selector,
            Bool,
            Bool,
            @escaping () -> Void,
            (() -> Void)?
        ) -> Void
        let function = unsafeBitCast(method, to: ObjCMethod.self)
        function(
            nativeLensView,
            PrivateSelector.setLifted,
            params.isLifted,
            !transition.isImmediate,
            alongsideAnimations,
            { [weak self] in
                self?.finishApplyingPendingParams(transition: transition)
            }
        )
    }

    private func finishApplyingPendingParams(transition: NagiTabTransition) {
        guard let pendingParams else {
            isApplyingParams = false
            setResizeClipping(false)
            return
        }
        self.pendingParams = nil
        isApplyingParams = false
        apply(params: pendingParams, isDark: traitCollection.userInterfaceStyle == .dark, transition: transition)
    }

    private static func makePrivateLensView(restingBackground: UIView) -> UIView? {
        guard #available(iOS 26.0, *), NSClassFromString("_UILiquidLensView") != nil else {
            return nil
        }
        guard let viewClass = NSClassFromString("_UILiquidLensView") as AnyObject as? NSObjectProtocol else {
            return nil
        }
        let allocSelector = NSSelectorFromString("alloc")
        guard viewClass.responds(to: allocSelector) else {
            return nil
        }
        let allocated = viewClass.perform(allocSelector).takeUnretainedValue()
        guard allocated.responds(to: PrivateSelector.initWithRestingBackground) else {
            return nil
        }
        let instance = allocated
            .perform(PrivateSelector.initWithRestingBackground, with: restingBackground)
            .takeUnretainedValue()
        guard let lensView = instance as? UIView else {
            return nil
        }
        let selectors = [
            PrivateSelector.setLiftedContainerView,
            PrivateSelector.setLiftedContentView,
            PrivateSelector.setOverridePunchoutView,
            PrivateSelector.setLiftedContentMode,
            PrivateSelector.setStyle,
            PrivateSelector.setWarpsContentBelow,
            PrivateSelector.setLifted
        ]
        guard selectors.allSatisfy({ lensView.responds(to: $0) }) else {
            return nil
        }
        return lensView
    }

    private func invoke(
        _ selector: Selector,
        on object: AnyObject,
        object argument: AnyObject?
    ) {
        guard object.responds(to: selector) else { return }
        _ = object.perform(selector, with: argument)
    }

    private func invoke(
        _ selector: Selector,
        on object: AnyObject,
        integer: Int32
    ) {
        guard let method = object.method(for: selector) else { return }
        typealias ObjCMethod = @convention(c) (AnyObject, Selector, Int32) -> Void
        let function = unsafeBitCast(method, to: ObjCMethod.self)
        function(object, selector, integer)
    }

    private func invoke(
        _ selector: Selector,
        on object: AnyObject,
        boolean: Bool
    ) {
        guard let method = object.method(for: selector) else { return }
        typealias ObjCMethod = @convention(c) (AnyObject, Selector, Bool) -> Void
        let function = unsafeBitCast(method, to: ObjCMethod.self)
        function(object, selector, boolean)
    }

    private func invoke(setCollapsed collapsed: Bool, on object: AnyObject) {
        guard object.responds(to: PrivateSelector.setCollapsed) else { return }
        invoke(PrivateSelector.setCollapsed, on: object, boolean: collapsed)
    }
}
