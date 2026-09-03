
import UIKit

@MainActor
protocol GlassRenderer: AnyObject {
    func makeEffectView() -> UIVisualEffectView
    func update(
        state: GlassState,
        previousState: GlassState?,
        effectView: UIVisualEffectView
    )
}
