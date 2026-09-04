import UIKit

@MainActor
final class GlassSurfaceView: UIView {
    private let effectView: UIVisualEffectView
    private let glassEffect: UIGlassEffect
    private var currentState: GlassState?

    override init(frame: CGRect) {
        let glassEffect = UIGlassEffect(style: .regular)
        glassEffect.isInteractive = true
        self.glassEffect = glassEffect
        effectView = UIVisualEffectView(effect: glassEffect)
        super.init(frame: frame)

        isOpaque = false
        effectView.isUserInteractionEnabled = false
        effectView.clipsToBounds = true
        effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(effectView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ newState: GlassState) {
        guard newState != currentState else { return }

        let tintColor = newState.tint?.uiColor
        if currentState != nil, currentState?.tint != newState.tint {
            UIView.animate(
                withDuration: 0.18,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]
            ) {
                self.glassEffect.tintColor = tintColor
            }
        } else {
            glassEffect.tintColor = tintColor
        }
        glassEffect.isInteractive = newState.isInteractive
        currentState = newState
        effectView.layer.cornerRadius = newState.cornerRadius
    }

    func setCornerRadius(_ radius: CGFloat) {
        effectView.layer.cornerRadius = radius
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        effectView.frame = bounds
    }
}
