import UIKit

@MainActor
final class GlassContainerView: UIView {
    private let effectView: GlassContainerEffectView

    init(spacing: CGFloat = 0) {
        let containerEffect = UIGlassContainerEffect()
        containerEffect.spacing = spacing
        effectView = GlassContainerEffectView(effect: containerEffect)
        super.init(frame: .zero)

        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = false

        effectView.backgroundColor = .clear
        effectView.isOpaque = false
        effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        effectView.clipsToBounds = false
        addSubview(effectView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func addItemView(_ view: UIView) {
        guard view.superview !== effectView.contentView else { return }
        view.removeFromSuperview()
        effectView.contentView.addSubview(view)
    }

    func removeItemView(_ view: UIView) {
        guard view.superview === effectView.contentView else { return }
        view.removeFromSuperview()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, alpha > 0.01 else { return nil }
        let hitView = super.hitTest(point, with: event)
        return hitView === self ? nil : hitView
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        effectView.frame = bounds
    }
}

/// Keeps the material transparent to hit testing while controls receive events.
@MainActor
private final class GlassContainerEffectView: UIVisualEffectView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hitView = super.hitTest(point, with: event)
        if hitView === self || hitView === contentView {
            return nil
        }
        return hitView
    }
}
