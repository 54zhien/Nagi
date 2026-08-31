//
//  GlassSurfaceView.swift
//  Nagi
//

import UIKit

@MainActor
final class GlassSurfaceView: UIView {
    private(set) var effectView: UIVisualEffectView
    private let renderer: any GlassRenderer
    private var currentState: GlassState?

    init(backend: GlassBackend? = nil) {
        let resolvedBackend = backend ?? GlassBackendConfiguration.surfaceBackend
        let resolvedRenderer: any GlassRenderer
        switch resolvedBackend {
        case .native:
            resolvedRenderer = NativeGlassRenderer()
        case .backdrop, .hybrid:
            resolvedRenderer = BackdropGlassRenderer()
        }
        let resolvedEffectView = resolvedRenderer.makeEffectView()
        renderer = resolvedRenderer
        effectView = resolvedEffectView
        super.init(frame: .zero)

        isOpaque = false
        clipsToBounds = true
        effectView.isUserInteractionEnabled = false
        effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(effectView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ newState: GlassState) {
        guard newState != currentState else { return }

        renderer.update(
            state: newState,
            previousState: currentState,
            effectView: effectView
        )
        currentState = newState
        layer.cornerRadius = newState.cornerRadius
    }

    func setCornerRadius(_ radius: CGFloat) {
        layer.cornerRadius = radius
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        effectView.frame = bounds
    }
}
