import UIKit

@MainActor
final class GlassSurfaceView: UIView {
    private let glassEffect: UIGlassEffect
    let effectView: UIVisualEffectView
    private var currentState: GlassState?
    private var currentLiquidGlassEnabled: Bool?

    override init(frame: CGRect) {
        let glassEffect = UIGlassEffect(style: .regular)
        glassEffect.isInteractive = true
        self.glassEffect = glassEffect
        effectView = UIVisualEffectView(effect: glassEffect)
        super.init(frame: frame)

        isOpaque = false
        backgroundColor = .clear
        effectView.isUserInteractionEnabled = false
        effectView.clipsToBounds = true
        effectView.layer.cornerCurve = .continuous
        effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(effectView)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ newState: GlassState) {
        let liquidGlassEnabled = NagiGlassStyleStore.liquidGlassEnabled
        guard newState != currentState
            || liquidGlassEnabled != currentLiquidGlassEnabled else {
            return
        }

        glassEffect.tintColor = newState.tint?.uiColor
        glassEffect.isInteractive = newState.isInteractive
        effectView.overrideUserInterfaceStyle = traitCollection.userInterfaceStyle
            == .dark ? .dark : .light
        effectView.effect = liquidGlassEnabled ? glassEffect : nil
        effectView.backgroundColor = liquidGlassEnabled
            ? .clear
            : .secondarySystemBackground
        effectView.layer.cornerRadius = newState.cornerRadius

        currentState = newState
        currentLiquidGlassEnabled = liquidGlassEnabled
    }

    func setCornerRadius(_ radius: CGFloat) {
        effectView.layer.cornerRadius = radius
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        effectView.frame = bounds
    }
}
