import UIKit

@MainActor
protocol PageTurnAnimating: AnyObject {
    func install()
    func update(progress: CGFloat)
    func animateCompletion(completion: @escaping (Bool) -> Void)
    func animateCancellation(completion: @escaping () -> Void)
    func remove()
}

@MainActor
enum PageTurnVisualStyle {
    case cover
    case fade
}

/// Presents already-rendered page surfaces during a page turn.
///
/// This type deliberately does not create snapshots, trigger layout, decode
/// content, or touch the live reader. The caller owns surface preparation;
/// this object only changes composited UIKit properties while the gesture is
/// running. That keeps interactive updates on the Core Animation path and
/// leaves the main thread free for a 120 Hz display.
@MainActor
final class PageTurnVisualAnimator: PageTurnAnimating {
    private let style: PageTurnVisualStyle
    private let hostView: UIView
    private let rootView = UIView()
    private let targetContainer = UIView()
    private let currentContainer = UIView()
    private let targetView: UIView
    private let currentView: UIView
    private let targetShadeView = UIView()
    private let currentTintView = UIView()
    private let direction: PageDirection
    private let completionTranslationX: CGFloat
    private let isDark: Bool

    private var animationRevision = 0
    private var propertyAnimator: UIViewPropertyAnimator?
    private var cornerRadius: CGFloat = 0
    private(set) var progress: CGFloat = 0

    init(
        style: PageTurnVisualStyle,
        hostView: UIView,
        currentView: UIView,
        targetView: UIView,
        direction: PageDirection,
        completionTranslationX: CGFloat,
        isDark: Bool
    ) {
        self.style = style
        self.hostView = hostView
        self.currentView = currentView
        self.targetView = targetView
        self.direction = direction
        self.completionTranslationX = completionTranslationX
        self.isDark = isDark
    }

    func install() {
        invalidateAnimation()
        rootView.removeFromSuperview()

        let bounds = hostView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        rootView.frame = bounds
        rootView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        rootView.backgroundColor = .clear
        rootView.isUserInteractionEnabled = false
        rootView.accessibilityElementsHidden = true
        rootView.isAccessibilityElement = false
        rootView.layer.cornerCurve = .continuous
        rootView.layer.masksToBounds = true

        // UIKit does not expose the physical display's corner radius. Use the
        // radius already supplied by the reader container (or an ancestor)
        // instead of inventing a device-specific 30 pt value. The radius is
        // fixed for the complete turn, including interactive and settling
        // phases.
        cornerRadius = Self.containerCornerRadius(for: hostView, bounds: bounds)
        applyCornerGeometry()
        hostView.addSubview(rootView)

        [targetContainer, currentContainer, targetView, currentView].forEach {
            $0.isUserInteractionEnabled = false
            $0.accessibilityElementsHidden = true
            $0.isAccessibilityElement = false
        }

        targetContainer.frame = bounds
        targetContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        targetContainer.backgroundColor = .clear
        targetContainer.layer.cornerCurve = .continuous
        targetContainer.layer.masksToBounds = false
        rootView.addSubview(targetContainer)

        currentContainer.frame = bounds
        currentContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        currentContainer.backgroundColor = .clear
        currentContainer.layer.cornerCurve = .continuous
        currentContainer.layer.masksToBounds = false
        rootView.addSubview(currentContainer)

        // The moving page is the top page in both directions: current page
        // for a forward turn, previous/target page for a backward turn.
        // Without this explicit ordering the backward page would remain below
        // the current page and could never cover it.
        if direction == .forward {
            targetContainer.layer.zPosition = 0
            currentContainer.layer.zPosition = 1
        } else {
            currentContainer.layer.zPosition = 0
            targetContainer.layer.zPosition = 1
        }

        targetView.frame = targetContainer.bounds
        targetView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        targetView.layer.cornerCurve = .continuous
        targetView.layer.masksToBounds = true
        targetContainer.addSubview(targetView)

        currentView.frame = currentContainer.bounds
        currentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        currentView.layer.cornerCurve = .continuous
        currentView.layer.masksToBounds = true
        currentContainer.addSubview(currentView)

        targetShadeView.frame = targetContainer.bounds
        targetShadeView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        targetShadeView.backgroundColor = .black
        targetShadeView.alpha = 0
        targetShadeView.isUserInteractionEnabled = false
        targetShadeView.layer.cornerCurve = .continuous
        targetShadeView.layer.masksToBounds = true
        targetContainer.addSubview(targetShadeView)

        currentTintView.frame = currentContainer.bounds
        currentTintView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        currentTintView.backgroundColor = .black
        currentTintView.alpha = 0
        currentTintView.isUserInteractionEnabled = false
        currentTintView.layer.cornerCurve = .continuous
        currentTintView.layer.masksToBounds = true
        currentContainer.addSubview(currentTintView)

        applyCornerGeometry()
        UIView.performWithoutAnimation {
            self.update(progress: 0)
        }
    }

    func update(progress rawProgress: CGFloat) {
        progress = min(max(rawProgress.isFinite ? rawProgress : 0, 0), 1)
        guard rootView.superview != nil else { return }

        applyCornerGeometry()

        switch style {
        case .cover:
            updateCover()
        case .fade:
            updateFade()
        }
    }

    func animateCompletion(completion: @escaping (Bool) -> Void) {
        animate(to: 1, duration: 0.22 * max(0.001, 1 - progress)) { position in
            completion(position == .end)
        }
    }

    func animateCancellation(completion: @escaping () -> Void) {
        animate(to: 0, duration: 0.18) { [weak self] position in
            guard position == .end else { return }
            self?.progress = 0
            completion()
        }
    }

    func remove() {
        invalidateAnimation()
        rootView.removeFromSuperview()
    }

    private func updateCover() {
        let isForward = direction == .forward

        // Forward: the current page is the moving page and reveals the next
        // page underneath. Backward: the previous page enters from the left
        // and covers the current page; the current page never slides right.
        if isForward {
            targetContainer.transform = .identity
            currentContainer.transform = CGAffineTransform(
                translationX: completionTranslationX * progress,
                y: 0
            )
            targetShadeView.alpha = 0
            currentTintView.alpha = isDark ? 0.06 * pow(progress, 1.6) : 0
            setShadow(
                on: currentContainer,
                opacity: 0.18 * (1 - progress),
                leading: completionTranslationX > 0
            )
            targetContainer.layer.shadowOpacity = 0
        } else {
            currentContainer.transform = .identity
            targetContainer.transform = CGAffineTransform(
                translationX: -completionTranslationX * (1 - progress),
                y: 0
            )
            currentTintView.alpha = 0
            // A restrained shade gives the incoming page physical separation
            // without the opaque red/black block caused by the old overlay.
            targetShadeView.alpha = isDark ? 0.035 * (1 - progress) : 0.025 * (1 - progress)
            setShadow(
                on: targetContainer,
                opacity: 0.16 * (1 - progress),
                leading: completionTranslationX < 0
            )
            currentContainer.layer.shadowOpacity = 0
        }
    }

    private func updateFade() {
        targetContainer.transform = .identity
        currentContainer.transform = .identity
        targetContainer.layer.shadowOpacity = 0
        currentContainer.layer.shadowOpacity = 0
        targetShadeView.alpha = 0
        currentTintView.alpha = 0

        // Both surfaces remain present for the entire transition. Animating
        // alpha through the compositor avoids the intermittent blank frame
        // produced when the old implementation changed hierarchy/visibility.
        targetView.alpha = progress
        currentView.alpha = 1 - progress
    }

    private func setShadow(on container: UIView, opacity: CGFloat, leading: Bool) {
        container.layer.shadowColor = UIColor.black.cgColor
        container.layer.shadowOpacity = Float(max(0, opacity))
        container.layer.shadowRadius = 12
        container.layer.shadowOffset = CGSize(width: leading ? -4 : 4, height: 0)
        container.layer.shadowPath = UIBezierPath(
            roundedRect: container.bounds,
            cornerRadius: cornerRadius
        ).cgPath
    }

    private func animate(
        to targetProgress: CGFloat,
        duration: TimeInterval,
        completion: @escaping (UIViewAnimatingPosition) -> Void
    ) {
        invalidateAnimation()
        animationRevision &+= 1
        let revision = animationRevision
        let timing = UICubicTimingParameters(animationCurve: .easeOut)
        let animator = UIViewPropertyAnimator(
            duration: max(0.001, duration),
            timingParameters: timing
        )
        animator.isInterruptible = true
        animator.addAnimations { [weak self] in
            self?.update(progress: targetProgress)
        }
        animator.addCompletion { [weak self] position in
            guard let self, revision == self.animationRevision else { return }
            self.propertyAnimator = nil
            completion(position)
        }
        propertyAnimator = animator
        animator.startAnimation()
    }

    private func invalidateAnimation() {
        animationRevision &+= 1
        propertyAnimator?.stopAnimation(true)
        propertyAnimator = nil
    }

    private func applyCornerGeometry() {
        let radius = min(cornerRadius, min(rootView.bounds.width, rootView.bounds.height) / 2)
        rootView.layer.cornerRadius = radius
        targetContainer.layer.cornerRadius = radius
        currentContainer.layer.cornerRadius = radius
        targetView.layer.cornerRadius = radius
        currentView.layer.cornerRadius = radius
        targetShadeView.layer.cornerRadius = radius
        currentTintView.layer.cornerRadius = radius
    }

    private static func containerCornerRadius(for view: UIView, bounds: CGRect) -> CGFloat {
        var candidate: CGFloat = 0
        var current: UIView? = view
        while let node = current {
            candidate = max(candidate, node.layer.cornerRadius)
            current = node.superview
        }
        return min(candidate, min(bounds.width, bounds.height) / 2)
    }
}

/// A deliberately small overscroll used when there is no prepared page (most
/// commonly at the beginning or end of a publication). It never touches the
/// live navigator and always settles to the exact identity transform.
@MainActor
final class PageTurnBoundaryAnimator: PageTurnAnimating {
    private let hostView: UIView
    private let currentView: UIView
    private let completionTranslationX: CGFloat
    private var animator: UIViewPropertyAnimator?
    private(set) var progress: CGFloat = 0

    init(hostView: UIView, currentView: UIView, completionTranslationX: CGFloat) {
        self.hostView = hostView
        self.currentView = currentView
        self.completionTranslationX = completionTranslationX
    }

    func install() {
        currentView.frame = hostView.bounds
        currentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        currentView.layer.cornerCurve = .continuous
        currentView.layer.cornerRadius = hostView.layer.cornerRadius
        currentView.layer.masksToBounds = true
        hostView.addSubview(currentView)
        update(progress: 0)
    }

    func update(progress rawProgress: CGFloat) {
        progress = min(max(rawProgress.isFinite ? rawProgress : 0, 0), 1)
        let sign: CGFloat = completionTranslationX < 0 ? -1 : 1
        let resistedDistance = 10 * progress / (0.35 + progress)
        currentView.transform = CGAffineTransform(translationX: sign * resistedDistance, y: 0)
    }

    func animateCompletion(completion: @escaping (Bool) -> Void) {
        animateCancellation { completion(false) }
    }

    func animateCancellation(completion: @escaping () -> Void) {
        animator?.stopAnimation(true)
        let animator = UIViewPropertyAnimator(duration: 0.18, dampingRatio: 0.82) { [weak self] in
            self?.currentView.transform = .identity
        }
        animator.addCompletion { [weak self] _ in
            self?.progress = 0
            completion()
        }
        self.animator = animator
        animator.startAnimation()
    }

    func remove() {
        animator?.stopAnimation(true)
        animator = nil
        currentView.transform = .identity
        currentView.removeFromSuperview()
    }
}
