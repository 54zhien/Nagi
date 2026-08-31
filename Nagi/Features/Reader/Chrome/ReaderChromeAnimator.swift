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
        reduceMotion: Bool
    ) {
        activeAnimator?.stopAnimation(true)
        activeAnimator = nil
        isVisible = visible

        let targetAlpha: CGFloat = visible ? 1 : 0
        let targetTransform = visible
            ? CGAffineTransform.identity
            : CGAffineTransform(scaleX: 0.94, y: 0.94)

        guard animated, !reduceMotion else {
            apply(alpha: targetAlpha, transform: targetTransform)
            return
        }

        let animator = UIViewPropertyAnimator(
            duration: 0.18,
            timingParameters: UISpringTimingParameters(dampingRatio: 0.92)
        )
        animator.addAnimations { [targets] in
            for target in targets {
                target.alpha = targetAlpha
                target.transform = targetTransform
            }
        }
        animator.addCompletion { [weak self] _ in
            self?.activeAnimator = nil
        }
        activeAnimator = animator
        animator.startAnimation()
    }

    private func apply(alpha: CGFloat, transform: CGAffineTransform) {
        for target in targets {
            target.alpha = alpha
            target.transform = transform
        }
    }
}
