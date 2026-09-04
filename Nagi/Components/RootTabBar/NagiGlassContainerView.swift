import UIKit

final class NagiGlassContainerView: UIView {
    private let nativeParamsView: NagiEffectSettingsContainerView
    private let spacing: CGFloat
    let effectView: UIVisualEffectView
    private var currentUsesNativeLiquidGlass: Bool?

    var contentView: UIView {
        effectView.contentView
    }

    init(spacing: CGFloat = 7) {
        let effectView = UIVisualEffectView(effect: nil)
        let nativeParamsView = NagiEffectSettingsContainerView(frame: .zero)

        self.effectView = effectView
        self.nativeParamsView = nativeParamsView
        self.spacing = spacing
        super.init(frame: .zero)

        isUserInteractionEnabled = true
        clipsToBounds = false
        backgroundColor = .clear
        isOpaque = false
        layer.cornerCurve = .continuous

        effectView.backgroundColor = .clear
        effectView.isOpaque = false
        effectView.clipsToBounds = false
        effectView.contentView.backgroundColor = .clear
        effectView.contentView.isOpaque = false

        nativeParamsView.addSubview(effectView)
        addSubview(nativeParamsView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard alpha != 0,
              !isHidden,
              isUserInteractionEnabled else {
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

    func update(
        size: CGSize,
        isDark: Bool,
        transition: NagiTabTransition
    ) {
        let usesNativeLiquidGlass = NagiGlassStyleStore.usesNativeLiquidGlass
        if usesNativeLiquidGlass != currentUsesNativeLiquidGlass {
            currentUsesNativeLiquidGlass = usesNativeLiquidGlass
            let effect: UIVisualEffect?
            if usesNativeLiquidGlass {
                let containerEffect = UIGlassContainerEffect()
                containerEffect.spacing = spacing
                effect = containerEffect
            } else {
                effect = nil
            }
            transition.animateView {
                self.effectView.effect = effect
            }
        }

        effectView.overrideUserInterfaceStyle = isDark ? .dark : .light
        overrideUserInterfaceStyle = isDark ? .dark : .light
        backgroundColor = usesNativeLiquidGlass
            ? .clear
            : .secondarySystemBackground
        nativeParamsView.lumaMin = isDark ? 0.0 : 0.8
        nativeParamsView.lumaMax = isDark ? 0.15 : 0.801

        let frame = CGRect(origin: .zero, size: size)
        transition.setFrame(view: nativeParamsView, frame: frame)
        transition.setCornerRadius(
            view: self,
            radius: size.height * 0.5
        )
        transition.animateView {
            self.effectView.frame = frame
        }
    }
}
