
import QuartzCore
import UIKit

@MainActor
final class GlassTouchDriver {
    weak var control: GlassControlView?

    private var startPoint = CGPoint.zero
    private var isTracking = false
    private var reduceMotion = false

    func update(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
    }

    func begin(at point: CGPoint) {
        guard let control, control.isEnabled else { return }
        startPoint = point
        isTracking = true
        ReaderPerformanceSignposts.glassTouchBegan()
        control.applyTouchBegan(at: point, reduceMotion: reduceMotion)
    }

    func move(to point: CGPoint) {
        guard isTracking, let control else { return }

        let width = max(control.bounds.width, 1)
        let height = max(control.bounds.height, 1)
        let dx = point.x - startPoint.x
        let dy = point.y - startPoint.y

        let normalizedX = max(-0.32, min(0.32, dx / width))
        let normalizedY = max(-0.32, min(0.32, dy / height))
        let magnitudeX = min(abs(normalizedX), 0.22)
        let magnitudeY = min(abs(normalizedY), 0.22)
        let baseScale: CGFloat = reduceMotion ? 1.02 : 1.045

        var transform = CATransform3DIdentity
        if reduceMotion {
            transform.m11 = baseScale
            transform.m22 = baseScale
        } else {
            let stretchX = 1 + magnitudeX * 0.72
            let stretchY = 1 + magnitudeY * 0.72
            let compressX = 1 - magnitudeY * 0.22
            let compressY = 1 - magnitudeX * 0.22
            transform.m11 = baseScale * stretchX * compressY
            transform.m22 = baseScale * stretchY * compressX
            transform.m41 = dx * 0.08
            transform.m42 = dy * 0.08
        }

        control.applyTouchTransform(transform, at: point)
    }

    func end(at point: CGPoint, cancelled: Bool) {
        guard isTracking, let control else { return }
        isTracking = false
        ReaderPerformanceSignposts.glassTouchEnded()

        let currentTransform = control.layer.presentation()?.transform ?? control.layer.transform
        control.applyTouchEnded(
            from: currentTransform,
            at: point,
            cancelled: cancelled,
            reduceMotion: reduceMotion
        )
    }
}
