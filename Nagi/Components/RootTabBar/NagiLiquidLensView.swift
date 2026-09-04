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
    private var isDarkValue: Bool?

    init() {
        super.init(effect: UIBlurEffect(style: .light))
        for subview in subviews {
            if subview.description.contains("VisualEffectSubview") {
                subview.isHidden = true
            }
        }
        clipsToBounds = true
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(isDark: Bool, reduceTransparency: Bool) {
        backgroundColor = reduceTransparency ? .secondarySystemBackground : .clear
        guard isDarkValue != isDark else { return }
        isDarkValue = isDark

        guard let sublayer = layer.sublayers?.first,
              sublayer.filters != nil,
              let classValue = NSClassFromString("CAFilter") as AnyObject? as? NSObjectProtocol,
              classValue.responds(to: NSSelectorFromString("filterWithName:")) else {
            return
        }

        sublayer.backgroundColor = nil
        sublayer.isOpaque = false
        guard let filter = classValue
            .perform(NSSelectorFromString("filterWithName:"), with: "colorMatrix")
            .takeUnretainedValue() as? NSObject else {
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
    }

    private struct LensParams: Equatable {
        var baseFrame: CGRect
        var inset: CGFloat
        var liftedInset: CGFloat
        var isLifted: Bool
    }

    // Keep the lens in its own glass container so it can move independently.
    private let containerView: UIView
    let dedicatedMainGlassContainer: UIView
    private let backgroundView: NagiGlassBackgroundView
    private let liftedContainerView: UIView
    let contentView: UIView
    private let restingBackgroundView: NagiLensRestingBackgroundView
    private let nativeLensView: UIView?

    var selectedContentView: UIView {
        liftedContainerView
    }

    private var params: NagiLensParams?
    private var appliedLensParams: LensParams?
    private var isApplyingLensParams = false
    private var pendingLensParams: LensParams?
    private var liftedDisplayLink: CADisplayLink?

    private(set) var isAnimating = false

    var usesPrivateLens: Bool {
        nativeLensView != nil
    }

    override init(frame: CGRect) {
        containerView = UIView(frame: .zero)
        dedicatedMainGlassContainer = UIView(frame: .zero)
        backgroundView = NagiGlassBackgroundView(frame: .zero)
        liftedContainerView = UIView(frame: .zero)
        contentView = UIView(frame: .zero)
        restingBackgroundView = NagiLensRestingBackgroundView()
        nativeLensView = Self.makePrivateLensView()
        super.init(frame: frame)

        clipsToBounds = false
        isUserInteractionEnabled = true

        dedicatedMainGlassContainer.backgroundColor = .clear
        dedicatedMainGlassContainer.isOpaque = false
        dedicatedMainGlassContainer.clipsToBounds = false
        addSubview(dedicatedMainGlassContainer)

        dedicatedMainGlassContainer.addSubview(backgroundView)
        backgroundView.contentView.clipsToBounds = false
        backgroundView.contentView.addSubview(containerView)
        containerView.isUserInteractionEnabled = false
        containerView.clipsToBounds = false

        contentView.backgroundColor = .clear
        contentView.isOpaque = false
        contentView.clipsToBounds = false
        contentView.layer.cornerCurve = .continuous

        liftedContainerView.backgroundColor = .clear
        liftedContainerView.isOpaque = false
        liftedContainerView.isUserInteractionEnabled = false
        liftedContainerView.clipsToBounds = false
        liftedContainerView.layer.cornerCurve = .continuous

        if let nativeLensView {
            dedicatedMainGlassContainer.layer.zPosition = 1
            nativeLensView.layer.zPosition = 10
            nativeLensView.isUserInteractionEnabled = false

            liftedContainerView.addSubview(restingBackgroundView)
            containerView.addSubview(liftedContainerView)
            containerView.addSubview(nativeLensView)
            containerView.addSubview(contentView)

            invoke(
                PrivateSelector.setLiftedContainerView,
                on: nativeLensView,
                object: dedicatedMainGlassContainer
            )
            invoke(
                PrivateSelector.setLiftedContentView,
                on: nativeLensView,
                object: liftedContainerView
            )
            invoke(
                PrivateSelector.setOverridePunchoutView,
                on: nativeLensView,
                object: contentView
            )
            invoke(PrivateSelector.setLiftedContentMode, on: nativeLensView, integer: 1)
            invoke(PrivateSelector.setStyle, on: nativeLensView, integer: 1)
            invoke(PrivateSelector.setWarpsContentBelow, on: nativeLensView, boolean: true)
            nativeLensView.setValue(
                UIColor(white: 0.0, alpha: 0.1),
                forKey: "restingBackgroundColor"
            )
        } else {
            // Keep the content path usable when the private class is absent.
            containerView.addSubview(liftedContainerView)
            containerView.addSubview(contentView)
        }
    }

    deinit {
        liftedDisplayLink?.invalidate()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Reassert the native Lens view connections after initialization.
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

    func apply(params: NagiLensParams, transition: NagiTabTransition) {
        guard self.params != params else { return }

        let isFirstTime = self.params == nil
        let effectiveTransition: NagiTabTransition = isFirstTime ? .immediate : transition
        self.params = params

        let contentOrigin = params.containerOrigin
        let contentFrame = CGRect(origin: contentOrigin, size: params.size)
        let innerFrame = CGRect(origin: .zero, size: params.size)

        effectiveTransition.setFrame(view: containerView, frame: innerFrame)
        effectiveTransition.setFrame(
            view: dedicatedMainGlassContainer,
            frame: contentFrame
        )
        effectiveTransition.setFrame(view: backgroundView, frame: innerFrame)

        let cornerRadius = params.size.height * 0.5
        backgroundView.update(
            params: NagiGlassParams(
                size: params.size,
                cornerRadius: cornerRadius,
                isDark: params.isDark,
                tintColor: params.isDark
                    ? UIColor.white.withAlphaComponent(0.025)
                    : UIColor.white.withAlphaComponent(0.1),
                isInteractive: true,
                isVisible: true,
                reduceTransparency: params.reduceTransparency
            ),
            transition: effectiveTransition
        )

        if contentView.bounds.size != params.size {
            contentView.clipsToBounds = true
            effectiveTransition.setFrame(
                view: contentView,
                frame: innerFrame,
                completion: { [weak self] completed in
                    guard completed else { return }
                    self?.contentView.clipsToBounds = false
                }
            )
            effectiveTransition.setCornerRadius(
                layer: contentView.layer,
                radius: cornerRadius
            )

            liftedContainerView.clipsToBounds = true
            effectiveTransition.setFrame(
                view: liftedContainerView,
                frame: innerFrame,
                completion: { [weak self] completed in
                    guard completed else { return }
                    self?.liftedContainerView.clipsToBounds = false
                }
            )
            effectiveTransition.setCornerRadius(
                layer: liftedContainerView.layer,
                radius: cornerRadius
            )
        }

        let baseLensFrame = CGRect(
            origin: params.selectionOrigin,
            size: params.selectionSize
        )
        updateLens(
            params: LensParams(
                baseFrame: baseLensFrame,
                inset: params.inset,
                liftedInset: params.liftedInset,
                isLifted: params.isLifted
            ),
            transition: effectiveTransition
        )

        effectiveTransition.setFrame(
            view: restingBackgroundView,
            frame: innerFrame
        )
        restingBackgroundView.update(
            isDark: params.isDark,
            reduceTransparency: params.reduceTransparency
        )
        effectiveTransition.setAlpha(
            view: restingBackgroundView,
            alpha: (params.isLifted || params.isCollapsed) ? 0 : 1
        )

        updateLiftedDisplayLink(isLifted: params.isLifted)
    }

    private func updateLens(
        params: LensParams,
        transition: NagiTabTransition
    ) {
        guard let nativeLensView else { return }

        if isApplyingLensParams {
            pendingLensParams = params
            return
        }

        isApplyingLensParams = true
        let previousParams = appliedLensParams
        appliedLensParams = params

        if previousParams?.isLifted != params.isLifted {
            isAnimating = true
            let selector = PrivateSelector.setLifted
            var shouldScheduleUpdate = false
            var didProcessUpdate = false
            pendingLensParams = params

            if let method = nativeLensView.method(for: selector) {
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
                    selector,
                    params.isLifted,
                    !transition.isImmediate,
                    { [weak self] in
                        guard let self else { return }
                        let liftedInset = params.isLifted
                            ? params.liftedInset
                            : -params.inset
                        nativeLensView.bounds = CGRect(
                            origin: .zero,
                            size: CGSize(
                                width: params.baseFrame.width + liftedInset * 2,
                                height: params.baseFrame.height + liftedInset * 2
                            )
                        )
                        didProcessUpdate = true

                        if shouldScheduleUpdate {
                            DispatchQueue.main.async { [weak self] in
                                guard let self,
                                      let pending = self.pendingLensParams else {
                                    return
                                }
                                self.isApplyingLensParams = false
                                self.pendingLensParams = nil
                                self.updateLens(
                                    params: pending,
                                    transition: transition
                                )
                            }
                        }
                    },
                    { [weak self] in
                        guard let self else { return }
                        if !self.isApplyingLensParams {
                            self.isAnimating = false
                        }
                    }
                )
            }

            if didProcessUpdate {
                transition.animateView {
                    nativeLensView.center = CGPoint(
                        x: params.baseFrame.midX,
                        y: params.baseFrame.midY
                    )
                }
                pendingLensParams = nil
                isApplyingLensParams = false
            } else {
                shouldScheduleUpdate = true
            }
        } else {
            let liftedInset = params.isLifted
                ? params.liftedInset
                : -params.inset
            let lensBounds = CGRect(
                origin: .zero,
                size: CGSize(
                    width: params.baseFrame.width + liftedInset * 2,
                    height: params.baseFrame.height + liftedInset * 2
                )
            )
            let lensCenter = CGPoint(
                x: params.baseFrame.midX,
                y: params.baseFrame.midY
            )

            let previousBounds = nativeLensView.bounds
            transition.animateView {
                nativeLensView.bounds = lensBounds
            }

            // Commit the final bounds before applying the position compensation.
            nativeLensView.layer.removeAllAnimations()
            nativeLensView.bounds = lensBounds

            if !transition.isImmediate {
                isAnimating = true
            }
            transition.setPosition(
                view: nativeLensView,
                position: lensCenter,
                completion: { [weak self] flag in
                    guard let self, flag else { return }
                    if !self.isApplyingLensParams {
                        self.isAnimating = false
                    }
                }
            )

            transition.animatePosition(
                layer: nativeLensView.layer,
                from: CGPoint(
                    x: (lensBounds.width - previousBounds.width) * 0.5,
                    y: 0
                ),
                to: .zero,
                additive: true
            )
            isApplyingLensParams = false
        }
    }

    private func updateLiftedLensPosition() {
        guard !isApplyingLensParams,
              let nativeLensView,
              let params = appliedLensParams else {
            return
        }
        nativeLensView.center = CGPoint(
            x: params.baseFrame.midX,
            y: params.baseFrame.midY
        )
    }

    private func updateLiftedDisplayLink(isLifted: Bool) {
        if isLifted {
            guard liftedDisplayLink == nil, nativeLensView != nil else { return }
            let link = CADisplayLink(
                target: self,
                selector: #selector(onLiftedDisplayLink(_:))
            )
            let maxFPS = Float(UIScreen.main.maximumFramesPerSecond)
            if maxFPS > 61 {
                link.preferredFrameRateRange = CAFrameRateRange(
                    minimum: maxFPS,
                    maximum: maxFPS,
                    preferred: maxFPS
                )
            }
            link.add(to: .main, forMode: .common)
            liftedDisplayLink = link
        } else if let link = liftedDisplayLink {
            liftedDisplayLink = nil
            link.invalidate()
        }
    }

    @objc private func onLiftedDisplayLink(_ link: CADisplayLink) {
        updateLiftedLensPosition()
    }

    private static func makePrivateLensView() -> UIView? {
        guard let viewClass = NSClassFromString("_UILiquidLensView") as AnyObject? as? NSObjectProtocol else {
            return nil
        }
        let allocSelector = NSSelectorFromString("alloc")
        guard viewClass.responds(to: allocSelector) else { return nil }
        let allocated = viewClass.perform(allocSelector).takeUnretainedValue()
        guard allocated.responds(to: PrivateSelector.initWithRestingBackground) else {
            return nil
        }
        let instance = allocated
            .perform(PrivateSelector.initWithRestingBackground, with: UIView())
            .takeUnretainedValue()
        guard let lensView = instance as? UIView else { return nil }

        let required = [
            PrivateSelector.setLiftedContainerView,
            PrivateSelector.setLiftedContentView,
            PrivateSelector.setOverridePunchoutView,
            PrivateSelector.setLiftedContentMode,
            PrivateSelector.setStyle,
            PrivateSelector.setWarpsContentBelow,
            PrivateSelector.setLifted
        ]
        guard required.allSatisfy({ lensView.responds(to: $0) }) else {
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
        unsafeBitCast(method, to: ObjCMethod.self)(object, selector, integer)
    }

    private func invoke(
        _ selector: Selector,
        on object: AnyObject,
        boolean: Bool
    ) {
        guard let method = object.method(for: selector) else { return }
        typealias ObjCMethod = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method, to: ObjCMethod.self)(object, selector, boolean)
    }
}
