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
        let tintChanged = previousState?.tint != state.tint

        if tintChanged, previousState != nil {
            let nextEffect = UIGlassEffect(style: .regular)
            nextEffect.isInteractive = state.isInteractive
            nextEffect.tintColor = state.tint?.uiColor
            glassEffect = nextEffect

            // Apple’s UIKit guidance recommends animating the effect property
            // for material changes so the glass materializes/dematerializes as
            // a system effect instead of behaving like a fading bitmap.
            UIView.animate(
                withDuration: 0.18,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]
            ) {
                effectView.effect = nextEffect
            }
            return
        }

        glassEffect.isInteractive = state.isInteractive
        glassEffect.tintColor = state.tint?.uiColor
    }
}
