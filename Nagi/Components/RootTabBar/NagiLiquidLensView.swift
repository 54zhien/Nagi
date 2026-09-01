//
//  NagiLiquidLensView.swift
//  Nagi
//
//  持久化的选中态 Lens。Main Glass、normal/selected content、resting
//  background 和 private _UILiquidLensView 都由这里统一管理。
//

import QuartzCore
import UIKit

struct NagiLensParams: Equatable {
    var size: CGSize
    var containerOrigin: CGPoint
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
        layer.cornerCurve = .continuous

        // Match Nagram's resting lens: the visual-effect subview is hidden and
        // the surface is recolored by a CA color-matrix filter instead of a
        // synthetic blue overlay.
        for subview in subviews {
            if subview.description.contains("VisualEffectSubview") {
                subview.isHidden = true
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(cornerRadius: CGFloat, isDark: Bool, reduceTransparency: Bool) {
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        backgroundColor = reduceTransparency ? .secondarySystemBackground : .clear
        update(isDark: isDark)
        setNeedsLayout()
    }

    func update(isDark: Bool) {
        guard self.isDark != isDark else {
            return
        }
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
        guard let filter else {
            return
        }

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
        static let setCollapsed = NSSelectorFromString("setCollapsed:")
        static let setRestingBackgroundColor = NSSelectorFromString("setRestingBackgroundColor:")
    }

    let contentView: UIView
    let selectedContentView: UIView
    let dedicatedMainGlassContainer: UIView

    private let mainSurface: NagiGlassBackgroundView
    private let lensContentContainer: UIView
    private let restingBackgroundView: NagiLensRestingBackgroundView
    private let nativeLensView: UIView?
    private var currentParams: NagiLensParams?
    private var isApplyingParams = false
    private var pendingParams: NagiLensParams?
    private var pendingCompletion: ((Bool) -> Void)?
    private var interactiveDisplayLink: CADisplayLink?
    private var interactiveTargetCenter: CGPoint?

    var usesPrivateLens: Bool {
        nativeLensView != nil
    }

    static var supportsNativeLiquidLens: Bool {
        guard #available(iOS 26.0, *) else {
            return false
        }
        return makePrivateLensView() != nil
    }

    override init(frame: CGRect) {
        self.contentView = UIView(frame: .zero)
        self.selectedContentView = UIView(frame: .zero)
        self.dedicatedMainGlassContainer = UIView(frame: .zero)
        self.mainSurface = NagiGlassBackgroundView(frame: .zero)
        self.lensContentContainer = UIView(frame: .zero)
        let restingBackgroundView = NagiLensRestingBackgroundView()
        self.restingBackgroundView = restingBackgroundView
        self.nativeLensView = Self.makePrivateLensView()
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

        selectedContentView.backgroundColor = .clear
        selectedContentView.isOpaque = false
        selectedContentView.isUserInteractionEnabled = false
        selectedContentView.clipsToBounds = false
        selectedContentView.insertSubview(restingBackgroundView, at: 0)
        lensContentContainer.addSubview(selectedContentView)

        contentView.backgroundColor = .clear
        contentView.isOpaque = false
        contentView.isUserInteractionEnabled = true
        contentView.clipsToBounds = false

        if let nativeLensView {
            nativeLensView.isUserInteractionEnabled = false
            nativeLensView.layer.zPosition = 10
            lensContentContainer.addSubview(nativeLensView)
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

        lensContentContainer.addSubview(contentView)
    }

    deinit {
        interactiveDisplayLink?.invalidate()
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

    func beginInteractiveSelection() {
        guard var params = currentParams, !params.isCollapsed else {
            return
        }

        params.isLifted = true
        currentParams = params
        restingBackgroundView.alpha = 0
        let liftedSize = nativeSize(for: params)
        if let nativeLensView {
            nativeLensView.bounds = CGRect(origin: .zero, size: liftedSize)
            nativeLensView.center = CGPoint(
                x: params.selectionOrigin.x + params.selectionSize.width * 0.5,
                y: params.selectionOrigin.y + params.selectionSize.height * 0.5
            )
            nativeLensView.alpha = 1
        }
        setNativeLifted(true, animated: true)
        startInteractiveDisplayLink()
    }

    func updateInteractiveSelection(originX: CGFloat, hoveredIndex _: Int) {
        guard var params = currentParams, !params.isCollapsed else {
            return
        }

        params.selectionOrigin.x = originX
        params.isLifted = true
        currentParams = params

        let targetCenter = CGPoint(
            x: originX + params.selectionSize.width * 0.5,
            y: params.selectionOrigin.y + params.selectionSize.height * 0.5
        )
        interactiveTargetCenter = targetCenter
    }

    func endInteractiveSelection() {
        interactiveDisplayLink?.invalidate()
        interactiveDisplayLink = nil
        interactiveTargetCenter = nil
    }

    func apply(
        params: NagiLensParams,
        transition: NagiTabTransition,
        completion: ((Bool) -> Void)? = nil
    ) {
        if isApplyingParams {
            pendingParams = params
            pendingCompletion = completion
            return
        }
        guard params != currentParams else {
            completion?(true)
            return
        }

        let previousParams = currentParams
        currentParams = params
        let oldLifted = previousParams?.isLifted ?? false
        let containerSizeChanged = previousParams.map { $0.size != params.size } ?? false
        let shouldClip = !transition.isImmediate && previousParams != nil && containerSizeChanged
        setResizeClipping(shouldClip)

        let mainCornerRadius = min(params.size.width, params.size.height) * 0.5
        let mainGlassParams = NagiGlassParams(
            size: params.size,
            cornerRadius: mainCornerRadius,
            isDark: params.isDark,
            tintColor: params.isDark
                ? UIColor.white.withAlphaComponent(0.025)
                : UIColor.white.withAlphaComponent(0.1),
            isInteractive: true,
            isVisible: true,
            reduceTransparency: params.reduceTransparency
        )
        mainSurface.prepare(params: mainGlassParams)

        isApplyingParams = true
        let alongsideAnimations = { [weak self] in
            guard let self else { return }
            self.applyPresentationGeometry(
                params: params,
                mainGlassParams: mainGlassParams,
                transition: transition
            )
        }

        if let nativeLensView {
            invoke(setCollapsed: params.isCollapsed, on: nativeLensView)
        }

        guard let nativeLensView,
              oldLifted != params.isLifted,
              nativeLensView.responds(to: PrivateSelector.setLifted) else {
            transition.perform(alongsideAnimations) { [weak self] completed in
                self?.finishApplyingPendingParams(
                    transition: transition,
                    completed: completed,
                    completion: completion
                )
            }
            return
        }

        invokeLifted(
            params: params,
            transition: transition,
            alongsideAnimations: alongsideAnimations,
            completion: completion
        )
    }

    private func applyPresentationGeometry(
        params: NagiLensParams,
        mainGlassParams: NagiGlassParams,
        transition: NagiTabTransition
    ) {
        let containerFrame = CGRect(origin: params.containerOrigin, size: params.size)
        transition.setFrame(view: dedicatedMainGlassContainer, frame: containerFrame)
        transition.setFrame(
            view: mainSurface,
            frame: dedicatedMainGlassContainer.bounds
        )
        mainSurface.applyGeometry(params: mainGlassParams)
        transition.setCornerRadius(view: mainSurface, radius: mainGlassParams.cornerRadius)
        let contentFrame = CGRect(origin: .zero, size: params.size)
        transition.setFrame(view: lensContentContainer, frame: contentFrame)
        transition.setFrame(
            view: selectedContentView,
            frame: CGRect(origin: .zero, size: contentFrame.size)
        )
        transition.setFrame(
            view: contentView,
            frame: CGRect(origin: .zero, size: contentFrame.size)
        )

        let effectiveInset: CGFloat
        if params.isCollapsed {
            effectiveInset = 0
        } else {
            effectiveInset = params.isLifted ? params.liftedInset : -params.inset
        }
        restingBackgroundView.apply(
            cornerRadius: min(selectedContentView.bounds.width, selectedContentView.bounds.height) * 0.5,
            isDark: params.isDark,
            reduceTransparency: params.reduceTransparency
        )
        transition.setFrame(
            view: restingBackgroundView,
            frame: selectedContentView.bounds
        )
        transition.setCornerRadius(
            view: restingBackgroundView,
            radius: min(selectedContentView.bounds.width, selectedContentView.bounds.height) * 0.5
        )
        transition.setAlpha(
            view: restingBackgroundView,
            alpha: params.isLifted || params.isCollapsed ? 0 : 1
        )

        let newNativeSize = CGSize(
            width: max(0, params.selectionSize.width + effectiveInset * 2),
            height: max(0, params.selectionSize.height + effectiveInset * 2)
        )
        if let nativeLensView {
            let newCenter = CGPoint(
                x: params.selectionOrigin.x + params.selectionSize.width * 0.5,
                y: params.selectionOrigin.y + params.selectionSize.height * 0.5
            )
            transition.setBounds(
                view: nativeLensView,
                bounds: CGRect(origin: .zero, size: newNativeSize)
            )
            transition.setPosition(view: nativeLensView, position: newCenter)
            transition.setAlpha(view: nativeLensView, alpha: 1)
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
        contentView.clipsToBounds = clipped
        selectedContentView.clipsToBounds = clipped
    }

    private func startInteractiveDisplayLink() {
        guard interactiveDisplayLink == nil, nativeLensView != nil else {
            return
        }

        let displayLink = CADisplayLink(
            target: self,
            selector: #selector(updateInteractivePresentation(_:))
        )
        if #available(iOS 15.0, *) {
            displayLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: 60,
                maximum: 120,
                preferred: 120
            )
        }
        displayLink.add(to: .main, forMode: .common)
        interactiveDisplayLink = displayLink
    }

    @objc private func updateInteractivePresentation(_ displayLink: CADisplayLink) {
        guard let interactiveTargetCenter,
              let nativeLensView else {
            return
        }
        nativeLensView.center = interactiveTargetCenter
    }

    private func setNativeLifted(_ lifted: Bool, animated: Bool) {
        guard let nativeLensView,
              let method = nativeLensView.method(for: PrivateSelector.setLifted) else {
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
            lifted,
            animated,
            {},
            nil
        )
    }

    private func invokeLifted(
        params: NagiLensParams,
        transition: NagiTabTransition,
        alongsideAnimations: @escaping () -> Void,
        completion: ((Bool) -> Void)?
    ) {
        guard let nativeLensView,
              let method = nativeLensView.method(for: PrivateSelector.setLifted) else {
            transition.perform(alongsideAnimations) { [weak self] completed in
                self?.finishApplyingPendingParams(
                    transition: transition,
                    completed: completed,
                    completion: completion
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
        function(
            nativeLensView,
            PrivateSelector.setLifted,
            params.isLifted,
            !transition.isImmediate,
            alongsideAnimations,
            { [weak self] in
                self?.finishApplyingPendingParams(
                    transition: transition,
                    completed: true,
                    completion: completion
                )
            }
        )
    }

    private func finishApplyingPendingParams(
        transition: NagiTabTransition,
        completed: Bool,
        completion: ((Bool) -> Void)?
    ) {
        guard let pendingParams else {
            isApplyingParams = false
            setResizeClipping(false)
            completion?(completed)
            return
        }
        let pendingCompletion = self.pendingCompletion
        self.pendingParams = nil
        self.pendingCompletion = nil
        isApplyingParams = false
        apply(
            params: pendingParams,
            transition: transition,
            completion: pendingCompletion
        )
    }

    private static func makePrivateLensView() -> UIView? {
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
            .perform(PrivateSelector.initWithRestingBackground, with: UIView())
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
