//
//  NativeGlassRenderer.swift
//  Nagi
//
//  Public iOS 26 Liquid Glass backend.  The effect view is created once;
//  replacing its effect is reserved for an actual tint change.
//

import UIKit

@MainActor
final class NativeGlassRenderer: GlassRenderer {
    private var glassEffect: UIGlassEffect

    init() {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        glassEffect = effect
    }

    func makeEffectView() -> UIVisualEffectView {
        UIVisualEffectView(effect: glassEffect)
    }

    func update(
        state: GlassState,
        previousState: GlassState?,
        effectView: UIVisualEffectView
    ) {
        _ = effectView
        let tintChanged = previousState?.tint != state.tint

        if tintChanged, previousState != nil {
            let tintColor = state.tint?.uiColor
            UIView.animate(
                withDuration: 0.18,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]
            ) {
                self.glassEffect.tintColor = tintColor
            }
        } else {
            glassEffect.tintColor = state.tint?.uiColor
        }

        glassEffect.isInteractive = state.isInteractive
    }
}
