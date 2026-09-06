import UIKit

@MainActor
enum PageTurnVisualStyle {
    case cover
    case fade
}

/// Animates detached page surfaces only. Live WebKit content is never changed
/// while an animation is running.
@MainActor
final class PageTurnVisualAnimator {
    private let style: PageTurnVisualStyle
    private let hostView: UIView
    private let rootView = UIView()
    private let targetView: UIView
    private let shadowContainer = UIView()
    private let clipView = UIView()
    private let currentView: UIView
    private let targetShadeView = UIView()
    private let currentTintView = UIView()
    private let completionTranslationX: CGFloat
    private let isDark: Bool

    private var animationRevision = 0
    private(set) var progress: CGFloat = 0

    init(
        style: PageTurnVisualStyle,
        hostView: UIView,
        currentView: UIView,
        targetView: UIView,
        completionTranslationX: CGFloat,
        isDark: Bool
    ) {
        self.style = style
        self.hostView = hostView
        self.currentView = currentView
        self.targetView = targetView
        self.completionTranslationX = completionTranslationX
        self.isDark = isDark
    }

    func install() {
        animationRevision &+= 1
        rootView.removeFromSuperview()

        let bounds = hostView.bounds
        rootView.frame = bounds
        rootView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        rootView.backgroundColor = .clear
        rootView.isUserInteractionEnabled = false
        rootView.accessibilityElementsHidden = true
        rootView.isAccessibilityElement = false
        hostView.addSubview(rootView)

        [targetView, shadowContainer, clipView, currentView].forEach {
            $0.isUserInteractionEnabled = false
            $0.accessibilityElementsHidden = true
            $0.isAccessibilityElement = false
        }

        targetView.frame = bounds
        targetView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        rootView.addSubview(targetView)

        targetShadeView.frame = targetView.bounds
        targetShadeView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        targetShadeView.backgroundColor = .black
        targetShadeView.isUserInteractionEnabled = false
        targetView.addSubview(targetShadeView)

        shadowContainer.frame = bounds
        shadowContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        shadowContainer.backgroundColor = .clear
        rootView.addSubview(shadowContainer)

        clipView.frame = shadowContainer.bounds
        clipView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        clipView.backgroundColor = .clear
        clipView.clipsToBounds = true
        shadowContainer.addSubview(clipView)

        currentView.frame = clipView.bounds
        currentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        clipView.addSubview(currentView)

        currentTintView.frame = clipView.bounds
        currentTintView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        currentTintView.backgroundColor = .white
        currentTintView.isUserInteractionEnabled = false
        clipView.addSubview(currentTintView)

        update(progress: 0)
    }

    func update(progress rawProgress: CGFloat) {
        progress = min(max(rawProgress.isFinite ? rawProgress : 0, 0), 1)

        switch style {
        case .cover:
            let targetStart = completionTranslationX < 0 ? 18.0 : -18.0
            shadowContainer.transform = CGAffineTransform(
                translationX: completionTranslationX * progress,
                y: 0
            )
            targetView.transform = CGAffineTransform(
                translationX: targetStart * (1 - progress),
                y: 0
            )
            clipView.layer.cornerCurve = .continuous
            clipView.layer.cornerRadius = 30 * progress
            shadowContainer.layer.shadowColor = UIColor.black.cgColor
            shadowContainer.layer.shadowOpacity = Float(0.14 * (1 - progress))
            shadowContainer.layer.shadowRadius = 14
            shadowContainer.layer.shadowOffset = CGSize(
                width: completionTranslationX < 0 ? 6 : -6,
                height: 0
            )
            shadowContainer.layer.shadowPath = UIBezierPath(
                roundedRect: shadowContainer.bounds,
                cornerRadius: 30 * progress
            ).cgPath
            targetShadeView.alpha = 0.07 * (1 - progress)
            currentTintView.alpha = isDark ? 0.10 * pow(progress, 1.7) : 0

        case .fade:
            shadowContainer.transform = .identity
            targetView.transform = .identity
            clipView.layer.cornerRadius = 0
            shadowContainer.layer.shadowOpacity = 0
            targetShadeView.alpha = 0
            currentTintView.alpha = 0
            targetView.alpha = interpolated(
                progress,
                points: [(0, 0.10), (0.257, 0.55), (0.514, 0.85), (0.771, 0.98), (1, 1)]
            )
            shadowContainer.alpha = interpolated(
                progress,
                points: [(0, 1), (0.257, 1), (0.514, 0.70), (0.771, 0.25), (1, 0)]
            )
        }
    }

    func animateCompletion(completion: @escaping (Bool) -> Void) {
        animationRevision &+= 1
        let revision = animationRevision
        let remaining = max(0.001, 1 - progress)
        let duration: TimeInterval = style == .fade ? 0.175 * remaining : 0.22 * remaining

        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
        ) { [weak self] in
            self?.update(progress: 1)
        } completion: { [weak self] finished in
            guard let self, revision == self.animationRevision else { return }
            completion(finished)
        }
    }

    func animateCancellation(completion: @escaping () -> Void) {
        animationRevision &+= 1
        let revision = animationRevision
        UIView.animate(
            withDuration: 0.18,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
        ) { [weak self] in
            self?.update(progress: 0)
        } completion: { [weak self] _ in
            guard let self, revision == self.animationRevision else { return }
            completion()
        }
    }

    func remove() {
        animationRevision &+= 1
        rootView.removeFromSuperview()
    }

    private func interpolated(
        _ x: CGFloat,
        points: [(x: CGFloat, y: CGFloat)]
    ) -> CGFloat {
        guard let first = points.first, let last = points.last else { return x }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }

        for index in 1 ..< points.count {
            let upper = points[index]
            let lower = points[index - 1]
            guard x <= upper.x else { continue }
            let span = max(upper.x - lower.x, .leastNonzeroMagnitude)
            let local = (x - lower.x) / span
            return lower.y + (upper.y - lower.y) * local
        }
        return last.y
    }
}
