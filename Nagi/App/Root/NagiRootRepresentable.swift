
import SwiftUI

struct NagiRootRepresentable: UIViewControllerRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(NagiAppearanceSettings.showTabBarLabelsKey)
    private var showTabBarLabels = true
    @AppStorage(NagiAppearanceSettings.liquidGlassEnabledKey)
    private var liquidGlassEnabled = true

    func makeUIViewController(context: Context) -> NagiRootViewController {
        NagiGlassEffectRuntime.installIfNeeded()
        return NagiRootViewController(
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            showTabBarLabels: showTabBarLabels,
            liquidGlassEnabled: liquidGlassEnabled
        )
    }

    func updateUIViewController(_ viewController: NagiRootViewController, context: Context) {
        viewController.updatePreferences(
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            showTabBarLabels: showTabBarLabels,
            liquidGlassEnabled: liquidGlassEnabled
        )
    }

    static func dismantleUIViewController(_ viewController: NagiRootViewController, coordinator: ()) {
        viewController.stopKeyboardObservation()
    }
}
