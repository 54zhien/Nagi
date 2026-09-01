//
//  NagiLiquidLensView.swift
//  Nagi
//
//  单一选中态 Lens。所有私有 UIKit runtime 访问都集中在本文件，且
//  经过 class/selector/instance 三层 capability check；不可用时退回
//  到同一容器中的持久化 NagiGlassBackgroundView。
//

import UIKit

struct NagiLensParams: Equatable {
    var baseFrame: CGRect
    var isLifted: Bool
    var reduceTransparency: Bool
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
    }

    let selectionSurface: NagiGlassBackgroundView
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
        return makePrivateLensView() != nil
    }

    override init(frame: CGRect) {
        self.selectionSurface = NagiGlassBackgroundView(frame: .zero)
        self.nativeLensView = Self.makePrivateLensView()
        super.init(frame: frame)

        isUserInteractionEnabled = false
        selectionSurface.isUserInteractionEnabled = false
        selectionSurface.alpha = 0
        addSubview(selectionSurface)

        if let nativeLensView {
            nativeLensView.isUserInteractionEnabled = false
            nativeLensView.layer.zPosition = 10
            addSubview(nativeLensView)
            nativeLensView.isHidden = false
            invoke(PrivateSelector.setLiftedContentMode, on: nativeLensView, integer: 1)
            invoke(PrivateSelector.setStyle, on: nativeLensView, integer: 1)
            invoke(PrivateSelector.setWarpsContentBelow, on: nativeLensView, boolean: true)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let params = currentParams {
            applyGeometry(params, animated: false)
        }
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

    func setTarget(_ view: UIView) {
        guard let nativeLensView else {
            return
        }
        invoke(PrivateSelector.setLiftedContentView, on: nativeLensView, object: view)
    }

    func apply(params: NagiLensParams, transition: NagiTabTransition) {
        if isApplyingParams {
            pendingParams = params
            return
        }
        guard params != currentParams else {
            return
        }
        let oldLifted = currentParams?.isLifted ?? false
        currentParams = params

        let selectionVisible = !usesPrivateLens && params.isLifted && !params.baseFrame.isEmpty
        let selectionGlassParams = NagiGlassParams(
            size: params.baseFrame.size,
            cornerRadius: min(params.baseFrame.width, params.baseFrame.height) * 0.5,
            isDark: traitCollection.userInterfaceStyle == .dark,
            tintColor: UIColor.systemBlue.withAlphaComponent(0.18),
            tintKey: "selection",
            isInteractive: false,
            isVisible: selectionVisible,
            reduceTransparency: params.reduceTransparency
        )
        selectionSurface.prepare(params: selectionGlassParams)
        transition.animate { [weak self] in
            guard let self else { return }
            self.selectionSurface.frame = params.baseFrame
            self.selectionSurface.applyGeometry(params: selectionGlassParams)
            self.selectionSurface.alpha = selectionVisible ? 1 : 0
        }

        guard let nativeLensView else {
            return
        }
        isApplyingParams = true
        if oldLifted != params.isLifted,
           nativeLensView.responds(to: PrivateSelector.setLifted) {
            invokeLifted(params: params, transition: transition)
        } else {
            transition.animate { [weak self] in
                self?.applyGeometry(params, animated: false)
            } completion: { [weak self] _ in
                self?.finishApplyingPendingParams(transition: transition)
            }
        }
    }

    private func applyGeometry(_ params: NagiLensParams, animated: Bool) {
        guard let nativeLensView else { return }
        let inset: CGFloat = params.isLifted ? 4 : -4
        nativeLensView.bounds = CGRect(
            origin: .zero,
            size: CGSize(
                width: max(0, params.baseFrame.width + inset * 2),
                height: max(0, params.baseFrame.height + inset * 2)
            )
        )
        nativeLensView.center = CGPoint(x: params.baseFrame.midX, y: params.baseFrame.midY)
        nativeLensView.alpha = params.isLifted ? 1 : 0
    }

    private func invokeLifted(params: NagiLensParams, transition: NagiTabTransition) {
        guard let nativeLensView,
              let method = nativeLensView.method(for: PrivateSelector.setLifted) else {
            applyGeometry(params, animated: false)
            finishApplyingPendingParams(transition: transition)
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
            { [weak self] in
                guard let self else { return }
                self.applyGeometry(params, animated: true)
            },
            { [weak self] in
                self?.finishApplyingPendingParams(transition: transition)
            }
        )
    }

    private func finishApplyingPendingParams(transition: NagiTabTransition) {
        isApplyingParams = false
        guard let pendingParams else {
            return
        }
        self.pendingParams = nil
        apply(params: pendingParams, transition: transition)
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
        let instance = allocated.perform(PrivateSelector.initWithRestingBackground, with: UIView()).takeUnretainedValue()
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

    private func invoke(_ selector: Selector, on object: AnyObject, object argument: AnyObject?) {
        guard object.responds(to: selector) else { return }
        _ = object.perform(selector, with: argument)
    }

    private func invoke(_ selector: Selector, on object: AnyObject, integer: Int32) {
        guard let method = object.method(for: selector) else { return }
        typealias ObjCMethod = @convention(c) (AnyObject, Selector, Int32) -> Void
        let function = unsafeBitCast(method, to: ObjCMethod.self)
        function(object, selector, integer)
    }

    private func invoke(_ selector: Selector, on object: AnyObject, boolean: Bool) {
        guard let method = object.method(for: selector) else { return }
        typealias ObjCMethod = @convention(c) (AnyObject, Selector, Bool) -> Void
        let function = unsafeBitCast(method, to: ObjCMethod.self)
        function(object, selector, boolean)
    }
}
