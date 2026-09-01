//
//  NagiTabSelectionRecognizer.swift
//  Nagi
//
//  Continuous one-finger selection tracking for the Main Root Tab surface.
//  The recognizer deliberately leaves the current tab untouched until the
//  touch ends; NagiTabBarView uses the live coordinates only for Lens visual
//  presentation while the finger is moving.
//

import UIKit

final class NagiTabSelectionRecognizer: UIGestureRecognizer {
    private(set) var initialTouchLocation = CGPoint.zero
    private(set) var currentTouchLocation = CGPoint.zero

    var shouldBeginAtLocation: ((CGPoint) -> Bool)?

    var initialLocation: CGPoint {
        initialTouchLocation
    }

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        configureTouchDelivery()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureTouchDelivery()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible,
              touches.count == 1,
              let touch = touches.first,
              let view else {
            state = .failed
            return
        }

        let location = touch.location(in: view)
        guard shouldBeginAtLocation?(location) ?? true else {
            state = .failed
            return
        }

        initialTouchLocation = location
        currentTouchLocation = location
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1,
              let touch = touches.first,
              let view,
              state == .began || state == .changed else {
            state = .cancelled
            return
        }

        currentTouchLocation = touch.location(in: view)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, let view else {
            state = .cancelled
            return
        }

        currentTouchLocation = touch.location(in: view)
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }

    func translation(in targetView: UIView?) -> CGPoint {
        guard let recognizerView = view else {
            return CGPoint(
                x: currentTouchLocation.x - initialTouchLocation.x,
                y: currentTouchLocation.y - initialTouchLocation.y
            )
        }

        let initial = recognizerView.convert(initialTouchLocation, to: targetView)
        let current = recognizerView.convert(currentTouchLocation, to: targetView)
        return CGPoint(x: current.x - initial.x, y: current.y - initial.y)
    }

    override func reset() {
        super.reset()
        initialTouchLocation = .zero
        currentTouchLocation = .zero
    }

    private func configureTouchDelivery() {
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        cancelsTouchesInView = true
    }
}
