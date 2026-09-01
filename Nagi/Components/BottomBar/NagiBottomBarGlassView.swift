//
//  NagiBottomBarGlassView.swift
//  Nagi
//
//  Persistent native Liquid Glass surface used by the root bar and search.
//

import UIKit

@MainActor
final class NagiBottomBarGlassView: UIView {
    private let fallbackView = UIView()
    private let effectView: UIVisualEffectView
    private let glassEffect: UIGlassEffect

    override init(frame: CGRect) {
        glassEffect = UIGlassEffect(style: .regular)
        glassEffect.isInteractive = false
        effectView = UIVisualEffectView(effect: glassEffect)
        super.init(frame: frame)

        isOpaque = false
        clipsToBounds = true
        fallbackView.backgroundColor = .secondarySystemBackground
        fallbackView.alpha = 0.94
        fallbackView.isHidden = false
        fallbackView.isUserInteractionEnabled = false
        effectView.isUserInteractionEnabled = false
        effectView.clipsToBounds = true

        addSubview(fallbackView)
        addSubview(effectView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setReduceTransparency(_ reduceTransparency: Bool) {
        effectView.isHidden = reduceTransparency
        fallbackView.isHidden = !reduceTransparency
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fallbackView.frame = bounds
        effectView.frame = bounds
        let radius = bounds.height / 2
        layer.cornerRadius = radius
        effectView.layer.cornerRadius = radius
    }
}
