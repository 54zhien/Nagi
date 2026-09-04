import SwiftUI

struct NagiRootRepresentable: UIViewControllerRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeUIViewController(context: Context) -> NagiRootViewController {
        NagiGlassEffectRuntime.installIfNeeded()
        return NagiRootViewController(
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency
        )
    }

    func updateUIViewController(_ viewController: NagiRootViewController, context: Context) {
        viewController.updateAccessibility(
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency
        )
    }

    static func dismantleUIViewController(_ viewController: NagiRootViewController, coordinator: ()) {
        viewController.stopKeyboardObservation()
    }
}
