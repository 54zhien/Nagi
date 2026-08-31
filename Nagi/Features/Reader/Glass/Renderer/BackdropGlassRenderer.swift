//
//  BackdropGlassRenderer.swift
//  Nagi
//
//  Public-API backdrop-style comparison backend.  It deliberately uses only
//  UIVisualEffectView and UIBlurEffect; private compositor experiments remain
//  outside the shipped target.
//

import UIKit

@MainActor
final class BackdropGlassRenderer: GlassRenderer {
    private let blurEffect = UIBlurEffect(style: .systemMaterial)

    func makeEffectView() -> UIVisualEffectView {
        let effectView = UIVisualEffectView(effect: blurEffect)
        effectView.contentView.isOpaque = false
        return effectView
    }

    func update(
        state: GlassState,
        previousState: GlassState?,
        effectView: UIVisualEffectView
    ) {
        let tintColor = state.tint?.uiColor.withAlphaComponent(0.24)
        guard previousState?.tint != state.tint
            || previousState?.isEnabled != state.isEnabled else {
            return
        }

        if previousState == nil {
            effectView.contentView.backgroundColor = tintColor
        } else {
            UIView.animate(
                withDuration: 0.18,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]
            ) {
                effectView.contentView.backgroundColor = tintColor
            }
        }
    }
}
