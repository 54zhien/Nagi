//
//  NagiLiquidLensView.swift
//  Nagi
//
//  Nagram LiquidLensView 的 Nagi 适配层。
//  外层 host 尺寸由 TabBarView 管；这里仅负责 Main Glass/content 的
//  实际 morph 尺寸以及 private _UILiquidLensView 的 selection geometry。
//

import QuartzCore
import UIKit

struct NagiLensParams: Equatable {
    /// LiquidLens 内部 Glass/content 的实际尺寸。搜索态为 48x48。
    var size: CGSize
    /// 内部 Glass 在稳定 host 坐标系中的 origin。Root TabBar 固定为 zero。
    var containerOrigin: CGPoint
    /// private Lens selection 的 origin，位于内部 content 坐标系。
    var selectionOrigin: CGPoint
    var selectionSize: CGSize
    var isDark: Bool
    var inset: CGFloat
    var liftedInset: CGFloat
    var isLifted: Bool
    var isCollapsed: Bool
    var reduceTransparency: Bool
}

private final class NagiLensRestingBackgroundView: UIVisualEffectView {
    private var isDark: Bool?

    init() {
        super.init(effect: UIBlurEffect(style: .light))

        isUserInteractionEnabled = false
        clipsToBounds = true

        // Same as Nagram RestingBackgroundView: hide the normal visual-effect
        // subview and recolor the backdrop with a color-matrix filter.
        for subview in subviews {
            if subview.description.contains("VisualEffectSubview") {
                subview.isHidden = true
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(isDark: Bool, reduceTransparency: Bool) {
        backgroundColor = reduceTransparency ? .secondarySystemBackground : .clear
        update(isDark: isDark)
    }

    private func update(isDark: Bool) {
        guard self.isDark != isDark else { return }
        self.isDark = isDark

        guard let sublayer = layer.sublayers?.first,
              sublayer.filters != nil,
              let filterClass = NSClassFromString("CAFilter") as AnyObject? as? NSObjectProtocol,
              filterClass.responds(to: NSSelectorFromString("filterWithName:")) else {
            return
        }

        sublayer.backgroundColor = nil
        sublayer.isOpaque = false

        let filter = filterClass
            .perform(NSSelectorFromString("filterWithName:"), with: "colorMatrix")
            .takeUnretainedValue() as? NSObject
        guard let filter else { return }

        var matrix = Self.colorMatrix(isDark: isDark)
        filter.setValue(
            NSValue(bytes: &matrix, objCType: "{CAColorMatrix=ffffffffffffffffffff}"),
            forKey: "inputColorMatrix"
        )
        sublayer.filters = [filter]
        sublayer.setValue(1.0, forKey: "scale")
    }

    private static func colorMatrix(isDark: Bool) -> [Float32] {
        if isDark {
            return [
                1.082, -0.113, -0.011, 0.0, 0.135,
                -0.034, 1.003, -0.011, 0.0, 0.135,
                -0.034, -0.113, 1.105, 0.0, 0.135,
                0.0, 0.0, 0.0, 1.0, 0.0
            ]
        } else {
            return [
                1.185, -0.05, -0.005, 0.0, -0.2,
                -0.015, 1.15, -0.005, 0.0, -0.2,
                -0.015, -0.05, 1.195, 0.0, -0.2,
                0.0, 0.0, 0.0, 1.0, 0.0
            ]
        }
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
        static let setRestingBackgroundColor = NSSelectorFromString("setRestingBackgroundColor:")
    }

    /// Nagram genericBackgroundContainer for .externalContainer.
    let dedicatedMainGlassContainer: UIView
    /// Nagram contentView (normal icons).
    let contentView: UIView
    /// Nagram liftedContainerView (selected icons).
    let selectedContentView: UIView

    private let mainSurface: NagiGlassBackgroundView
    /// Nagram containerView. This is inside the Glass content view and is the
    /// coordinate system shared by normal content, lifted content and Lens.
    private let lensContentContainer: UIView
    private let restingBackgroundView: NagiLensRestingBackgroundView
    private let nativeLensView: UIView?

    private var currentParams: NagiLensParams?
    private var appliedLensParams: NagiLensParams?
    private var isApplyingParams = false
    private var pendingParams: NagiLensParams?
    private var interactiveDisplayLink: CADisplayLink?

    var usesPrivateLens: Bool {
        nativeLensView != nil
    }

    static var supportsNativeLiquidLens: Bool {
        guard #available(iOS 26.0, *) else { return false }
        return makePrivateLensView() != nil
    }

    override init(frame: CGRect) {
        dedicatedMainGlassContainer = UIView(frame: .zero)
        contentView = UIView(frame: .zero)
        selectedContentView = UIView(frame: .zero)
        mainSurface = NagiGlassBackgroundView(frame: .zero)
        lensContentContainer = UIView(frame: .zero)
        restingBackgroundView = NagiLensRestingBackgroundView()
        nativeLensView = Self.makePrivateLensView()
        super.init(frame: frame)

        isUserInteractionEnabled = true
        clipsToBounds = false

        dedicatedMainGlassContainer.backgroundColor = .clear
        dedicatedMainGlassContainer.isOpaque = false
        dedicatedMainGlassContainer.clipsToBounds = false
        dedicatedMainGlassContainer.isUserInteractionEnabled = true
        addSubview(dedicatedMainGlassContainer)

        mainSurface.isUserInteractionEnabled = true
        dedicatedMainGlassContainer.addSubview(mainSurface)
        mainSurface.contentView.isUserInteractionEnabled = true
        mainSurface.contentView.clipsToBounds = false
        mainSurface.contentView.addSubview(lensContentContainer)

        lensContentContainer.backgroundColor = .clear
        lensContentContainer.isOpaque = false
        lensContentContainer.clipsToBounds = false
        lensContentContainer.isUserInteractionEnabled = false

        selectedContentView.backgroundColor = .clear
        selectedContentView.isOpaque = false
        selectedContentView.isUserInteractionEnabled = false
        selectedContentView.clipsToBounds = false
        selectedContentView.layer.cornerCurve = .continuous
        selectedContentView.addSubview(restingBackgroundView)
        lensContentContainer.addSubview(selectedContentView)

        contentView.backgroundColor = .clear
        contentView.isOpaque = false
        contentView.isUserInteractionEnabled = true
        contentView.clipsToBounds = false
        contentView.layer.cornerCurve = .continuous

        if let nativeLensView {
            nativeLensView.isUserInteractionEnabled = false
            nativeLensView.layer.zPosition = 10
            lensContentContainer.addSubview(nativeLensView)
            invoke(PrivateSelector.setLiftedContentMode, on: nativeLensView, integer: 1)
            invoke(PrivateSelector.setStyle, on: nativeLensView, integer: 1)
            invoke(PrivateSelector.setWarpsContentBelow, on: nativeLensView, boolean: true)
            if nativeLensView.responds(to: PrivateSelector.setRestingBackgroundColor) {
                nativeLensView.setValue(
                    UIColor(white: 0.0, alpha: 0.1),
                    forKey: "restingBackgroundColor"
                )
            }
        }

        // Same z-order as Nagram: lifted content, private Lens, normal content.
        lensContentContainer.addSubview(contentView)
    }

    deinit {
        interactiveDisplayLink?.invalidate()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        liftedContainerView: UIView,
        liftedContentView: UIView,
        punchoutView: UIView
    ) {
        guard let nativeLensView else { return }
        invoke(
            PrivateSelector.setLiftedContainerView,
            on: nativeLensView,
            object: liftedContainerView
        )
        invoke(
            PrivateSelector.setLiftedContentView,
            on: nativeLensView,
            object: liftedContentView
        )
        invoke(
            PrivateSelector.setOverridePunchoutView,
            on: nativeLensView,
            object: punchoutView
        )
    }

    func apply(
        params: NagiLensParams,
        transition: NagiTabTransition
    ) {
        if isApplyingParams {
            pendingParams = params
            return
        }
        guard params != currentParams else { return }

        let isFirstTime = currentParams == nil
        let effectiveTransition: NagiTabTransition = isFirstTime ? .immediate : transition
        let previousParams = appliedLensParams
        currentParams = params
        appliedLensParams = params

        updateLiftedDisplayLink(isLifted: params.isLifted)

        let oldLifted = previousParams?.isLifted ?? false
        let privateLiftChanged =
            nativeLensView?.responds(to: PrivateSelector.setLifted) == true &&
            oldLifted != params.isLifted

        let contentGeometryChanged =
            previousParams == nil ||
            previousParams?.size != params.size ||
            previousParams?.containerOrigin != params.containerOrigin

        // Nagram clips BOTH normal and lifted content only while their size is
        // changing, and the clipping view has the same animated corner radius
        // as the Glass. Missing the corner radius is what made Nagi look like a
        // rectangular crop inside an independently morphing rounded surface.
        if contentGeometryChanged {
            setResizeClipping(!effectiveTransition.isImmediate && previousParams != nil)
        }

        let cornerRadius = min(params.size.width, params.size.height) * 0.5
        let mainGlassParams = NagiGlassParams(
            size: params.size,
            cornerRadius: cornerRadius,
            isDark: params.isDark,
            tintColor: params.isDark
                ? UIColor.white.withAlphaComponent(0.025)
                : UIColor.white.withAlphaComponent(0.1),
            isInteractive: true,
            isVisible: true,
            reduceTransparency: params.reduceTransparency
        )
        let mainGlassChanged = mainSurface.prepare(params: mainGlassParams)

        let applyAnimations = { [weak self] in
            guard let self else { return }

            self.applyPresentationGeometry(
                params: params,
                mainGlassParams: mainGlassParams,
                transition: effectiveTransition,
                mainGlassChanged: mainGlassChanged,
                contentGeometryChanged: contentGeometryChanged
            )
            self.applyNativeLensGeometry(
                params: params,
                transition: effectiveTransition,
                privateLiftChanged: privateLiftChanged
            )
        }

        guard privateLiftChanged else {
            effectiveTransition.perform(applyAnimations) { [weak self] completed in
                guard let self,
                      completed,
                      self.currentParams == params else {
                    return
                }
                self.setResizeClipping(false)
            }
            return
        }

        isApplyingParams = true
        pendingParams = params
        effectiveTransition.perform(applyAnimations)

        let alongsideAnimations = { [weak self] in
            guard let self, let nativeLensView = self.nativeLensView else { return }
            nativeLensView.bounds = self.nativeLensTargetBounds(for: params)
        }

        invokeLifted(
            params: params,
            transition: effectiveTransition,
            alongsideAnimations: alongsideAnimations
        )
    }

    private func applyPresentationGeometry(
        params: NagiLensParams,
        mainGlassParams: NagiGlassParams,
        transition: NagiTabTransition,
        mainGlassChanged: Bool,
        contentGeometryChanged: Bool
    ) {
        let cornerRadius = min(params.size.width, params.size.height) * 0.5

        if contentGeometryChanged {
            // These are Nagram's genericBackgroundContainer -> backgroundView
            // -> containerView layers. The NagiLiquidLensView outer host is NOT
            // resized here; only these internal layers morph to params.size.
            let glassContainerFrame = CGRect(
                origin: params.containerOrigin,
                size: params.size
            )
            transition.setFrame(
                view: dedicatedMainGlassContainer,
                frame: glassContainerFrame
            )
            transition.setFrame(
                view: mainSurface,
                frame: CGRect(origin: .zero, size: params.size)
            )
            transition.setFrame(
                view: lensContentContainer,
                frame: CGRect(origin: .zero, size: params.size)
            )

            let contentFrame = CGRect(origin: .zero, size: params.size)
            transition.setFrame(view: contentView, frame: contentFrame)
            transition.setCornerRadius(view: contentView, radius: cornerRadius)

            transition.setFrame(view: selectedContentView, frame: contentFrame)
            transition.setCornerRadius(
                view: selectedContentView,
                radius: cornerRadius
            )

            transition.setFrame(
                view: restingBackgroundView,
                frame: contentFrame
            )
        }

        if mainGlassChanged {
            mainSurface.applyGeometry(
                params: mainGlassParams,
                transition: transition
            )
        }

        restingBackgroundView.apply(
            isDark: params.isDark,
            reduceTransparency: params.reduceTransparency
        )
        transition.setAlpha(
            view: restingBackgroundView,
            alpha: params.isLifted || params.isCollapsed ? 0 : 1
        )
    }

    private func applyNativeLensGeometry(
        params: NagiLensParams,
        transition: NagiTabTransition,
        privateLiftChanged: Bool
    ) {
        guard let nativeLensView else { return }

        let baseFrame = CGRect(
            origin: params.selectionOrigin,
            size: params.selectionSize
        )
        let newCenter = CGPoint(x: baseFrame.midX, y: baseFrame.midY)
        let targetBounds = nativeLensTargetBounds(for: params)
        let previousBounds = nativeLensView.bounds

        if !privateLiftChanged {
            transition.animateView {
                nativeLensView.bounds = targetBounds
            }

            // Nagram's intentional iOS LiquidLens workaround: start UIKit's
            // bounds animation, immediately discard its layer animations, set
            // final model bounds, then compensate position additively.
            nativeLensView.layer.removeAllAnimations()
            nativeLensView.bounds = targetBounds

            transition.setPosition(
                view: nativeLensView,
                position: newCenter
            )
            transition.animatePosition(
                layer: nativeLensView.layer,
                from: CGPoint(
                    x: (targetBounds.width - previousBounds.width) * 0.5,
                    y: 0
                ),
                to: .zero,
                additive: true
            )
        }

        transition.setAlpha(view: nativeLensView, alpha: 1)
    }

    private func nativeLensTargetBounds(for params: NagiLensParams) -> CGRect {
        let effectiveInset: CGFloat = params.isLifted
            ? params.liftedInset
            : -params.inset

        return CGRect(
            origin: .zero,
            size: CGSize(
                width: max(
                    0,
                    params.selectionSize.width + effectiveInset * 2
                ),
                height: max(
                    0,
                    params.selectionSize.height + effectiveInset * 2
                )
            )
        )
    }

    private func setResizeClipping(_ clipped: Bool) {
        contentView.clipsToBounds = clipped
        selectedContentView.clipsToBounds = clipped
    }

    private func updateLiftedDisplayLink(isLifted: Bool) {
        if isLifted {
            guard interactiveDisplayLink == nil,
                  nativeLensView != nil else {
                return
            }

            let displayLink = CADisplayLink(
                target: self,
                selector: #selector(updateLiftedLensPresentation(_:))
            )
            if #available(iOS 15.0, *) {
                let maximumFPS = Float(UIScreen.main.maximumFramesPerSecond)
                if maximumFPS > 61.0 {
                    displayLink.preferredFrameRateRange = CAFrameRateRange(
                        minimum: 30.0,
                        maximum: 120.0,
                        preferred: 120.0
                    )
                }
            }
            displayLink.add(to: .main, forMode: .common)
            interactiveDisplayLink = displayLink
        } else {
            interactiveDisplayLink?.invalidate()
            interactiveDisplayLink = nil
        }
    }

    @objc private func updateLiftedLensPresentation(_ displayLink: CADisplayLink) {
        guard !isApplyingParams,
              let params = currentParams,
              params.isLifted,
              let nativeLensView else {
            return
        }

        nativeLensView.center = CGPoint(
            x: params.selectionOrigin.x + params.selectionSize.width * 0.5,
            y: params.selectionOrigin.y + params.selectionSize.height * 0.5
        )
    }

    private func invokeLifted(
        params: NagiLensParams,
        transition: NagiTabTransition,
        alongsideAnimations: @escaping () -> Void
    ) {
        guard let nativeLensView,
              let method = nativeLensView.method(for: PrivateSelector.setLifted) else {
            transition.perform(alongsideAnimations) { [weak self] completed in
                guard let self else { return }
                self.isApplyingParams = false
                if completed, self.currentParams == params {
                    self.setResizeClipping(false)
                }
                self.applyPendingLensParams(
                    using: transition,
                    reapplyCurrentParams: false
                )
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

        var didProcessUpdate = false
        var shouldScheduleUpdate = false
        let newCenter = CGPoint(
            x: params.selectionOrigin.x + params.selectionSize.width * 0.5,
            y: params.selectionOrigin.y + params.selectionSize.height * 0.5
        )

        function(
            nativeLensView,
            PrivateSelector.setLifted,
            params.isLifted,
            !transition.isImmediate,
            { [weak self] in
                guard let self else { return }

                alongsideAnimations()
                didProcessUpdate = true

                if shouldScheduleUpdate {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.isApplyingParams = false
                        self.applyPendingLensParams(
                            using: transition,
                            reapplyCurrentParams: true
                        )
                    }
                }
            },
            { [weak self] in
                guard let self else { return }
                if self.currentParams == params {
                    self.setResizeClipping(false)
                }
            }
        )

        if didProcessUpdate {
            transition.animateView {
                nativeLensView.center = newCenter
            }
            pendingParams = nil
            isApplyingParams = false
            applyPendingLensParams(
                using: transition,
                reapplyCurrentParams: false
            )
        } else {
            shouldScheduleUpdate = true
        }
    }

    private func applyPendingLensParams(
        using transition: NagiTabTransition,
        reapplyCurrentParams: Bool
    ) {
        guard let pendingParams else {
            self.pendingParams = nil
            return
        }

        self.pendingParams = nil
        if pendingParams == appliedLensParams {
            if reapplyCurrentParams {
                applyNativeLensGeometry(
                    params: pendingParams,
                    transition: transition,
                    privateLiftChanged: false
                )
            }
            if currentParams == pendingParams {
                setResizeClipping(false)
            }
        } else {
            apply(params: pendingParams, transition: transition)
        }
    }

    private static func makePrivateLensView() -> UIView? {
        guard #available(iOS 26.0, *),
              let viewClass = NSClassFromString("_UILiquidLensView") as AnyObject? as? NSObjectProtocol else {
            return nil
        }

        let allocSelector = NSSelectorFromString("alloc")
        guard viewClass.responds(to: allocSelector) else { return nil }
        let allocated = viewClass.perform(allocSelector).takeUnretainedValue()
        guard allocated.responds(to: PrivateSelector.initWithRestingBackground) else {
            return nil
        }

        let instance = allocated
            .perform(
                PrivateSelector.initWithRestingBackground,
                with: UIView()
            )
            .takeUnretainedValue()
        guard let lensView = instance as? UIView else { return nil }

        let requiredSelectors = [
            PrivateSelector.setLiftedContainerView,
            PrivateSelector.setLiftedContentView,
            PrivateSelector.setOverridePunchoutView,
            PrivateSelector.setLiftedContentMode,
            PrivateSelector.setStyle,
            PrivateSelector.setWarpsContentBelow,
            PrivateSelector.setLifted
        ]
        guard requiredSelectors.allSatisfy({ lensView.responds(to: $0) }) else {
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
        typealias ObjCMethod = @convention(c) (
            AnyObject,
            Selector,
            Int32
        ) -> Void
        let function = unsafeBitCast(method, to: ObjCMethod.self)
        function(object, selector, integer)
    }

    private func invoke(
        _ selector: Selector,
        on object: AnyObject,
        boolean: Bool
    ) {
        guard let method = object.method(for: selector) else { return }
        typealias ObjCMethod = @convention(c) (
            AnyObject,
            Selector,
            Bool
        ) -> Void
        let function = unsafeBitCast(method, to: ObjCMethod.self)
        function(object, selector, boolean)
    }
}
