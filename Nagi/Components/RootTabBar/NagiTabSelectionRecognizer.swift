
import UIKit

final class NagiTabSelectionRecognizer: UIGestureRecognizer {
    private var initialTouchLocation: CGPoint?
    private var currentTouchLocation: CGPoint?

    var shouldBeginAtLocation: ((CGPoint) -> Bool)?

    var initialLocation: CGPoint {
        initialTouchLocation ?? .zero
    }

    var currentLocation: CGPoint {
        currentTouchLocation ?? initialTouchLocation ?? .zero
    }

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)

        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func reset() {
        super.reset()

        initialTouchLocation = nil
        currentTouchLocation = nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)

        if initialTouchLocation == nil {
            initialTouchLocation = touches.first?.location(in: view)
        }
        guard let initialTouchLocation,
              shouldBeginAtLocation?(initialTouchLocation) ?? true else {
            state = .failed
            return
        }

        currentTouchLocation = initialTouchLocation
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)

        currentTouchLocation = touches.first?.location(in: view)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)

        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)

        state = .cancelled
    }

    func translation() -> CGPoint {
        if let initialTouchLocation, let currentTouchLocation {
            return CGPoint(
                x: currentTouchLocation.x - initialTouchLocation.x,
                y: currentTouchLocation.y - initialTouchLocation.y
            )
        }
        return .zero
    }
}
