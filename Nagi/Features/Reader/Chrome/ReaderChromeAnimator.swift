//
//  ReaderChromeAnimator.swift
//  Nagi
//
//  Interruptible visibility animation for the persistent Reader Chrome.
//

import UIKit

@MainActor
final class ReaderChromeAnimator {
    private let targets: [UIView]
    private var activeAnimator: UIViewPropertyAnimator?

    private(set) var isVisible = true

    init(targets: [UIView]) {
        self.targets = targets
    }

    func setVisible(
        _ visible: Bool,
        animated: Bool,
        reduceMotion: Bool,
        completion: (() -> Void)? = nil
    ) {
        activeAnimator?.stopAnimation(true)
        activeAnimator = nil
        isVisible = visible

        let targetTransform = visible
            ? CGAffineTransform.identity
            : CGAffineTransform(scaleX: 0.94, y: 0.94)

        guard animated, !reduceMotion else {
            apply(transform: targetTransform)
            completion?()
            return
        }

        let animator = UIViewPropertyAnimator(
            duration: 0.18,
            timingParameters: UISpringTimingParameters(dampingRatio: 0.92)
        )
        animator.addAnimations { [targets] in
            for target in targets {
                target.transform = targetTransform
            }
        }
        animator.addCompletion { [weak self] position in
            guard position == .end else { return }
            self?.activeAnimator = nil
            completion?()
        }
        activeAnimator = animator
        animator.startAnimation()
    }

    private func apply(transform: CGAffineTransform) {
        for target in targets {
            target.transform = transform
        }
    }
}
