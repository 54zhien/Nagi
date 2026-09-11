import UIKit

@MainActor
protocol PageTurnAnimating: AnyObject {
    /// Installs the immutable overlay only when the host has a usable
    /// viewport. A false result must never enter the interactive/commit path.
    @discardableResult
    func install() -> Bool
    func update(progress: CGFloat)
    func animateCompletion(completion: @escaping (Bool) -> Void)
    func animateCancellation(completion: @escaping () -> Void)
    func animateRestoration(completion: @escaping () -> Void)
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
    private let currentTintView = UIView()
    private let completionTranslationX: CGFloat
    private let isDark: Bool
    /// True when the incoming page is the one that moves.
    ///
    /// Going back a page, the previous page slides in *over* the current one:
    /// the incoming sheet is the mover and belongs on top. Going forward the
    /// current sheet moves away and reveals the next one behind it. Playing the
    /// forward animation with a flipped sign gets the direction right but the
    /// roles wrong — the wrong page moves, and it moves on the wrong layer.
    private let isReversed: Bool

    /// The sheet that travels a full width, and the one it uncovers or covers.
    private var movingContainer: UIView { isReversed ? targetContainer : currentContainer }
    private var restingContainer: UIView { isReversed ? currentContainer : targetContainer }

    private var animationRevision = 0
    private var propertyAnimator: UIViewPropertyAnimator?
    private var cornerRadius: CGFloat = 0
    private(set) var progress: CGFloat = 0

    init(
        style: PageTurnVisualStyle,
        direction: PageDirection,
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
        // Only the cover has a moving sheet to reassign; a cross-fade has no
        // direction to speak of.
        isReversed = style == .cover && direction == .backward
    }

    @discardableResult
    func install() -> Bool {
        invalidateAnimation()
        rootView.removeFromSuperview()

        let bounds = hostView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return false }

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
        rootView.layer.cornerRadius = cornerRadius
        applyCornerGeometry()
        hostView.addSubview(rootView)

        [targetContainer, currentContainer, targetView, currentView].forEach {
            $0.isUserInteractionEnabled = false
            $0.accessibilityElementsHidden = true
            $0.isAccessibilityElement = false
            // The fade cross-dissolves these very views, so a cover installed
            // over them afterwards (the completion fallback reuses the same
            // composites) would otherwise animate two translucent pages.
            $0.alpha = 1
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

        switch style {
        case .cover:
            // The moving sheet is the one on top: forward that is the outgoing
            // current page, backward the incoming one.
            currentContainer.layer.zPosition = isReversed ? 0 : 1
            targetContainer.layer.zPosition = isReversed ? 1 : 0
        case .fade:
            // The incoming sheet must composite above the fading current one.
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

        // The tint shades the sheet that moves, so it has to live in whichever
        // container that is. Leaving it on `currentContainer` would have made
        // it shade the *resting* sheet on every backward turn, and `isDark`
        // inert there.
        currentTintView.frame = movingContainer.bounds
        currentTintView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        currentTintView.backgroundColor = isDark ? .white : .black
        currentTintView.alpha = 0
        currentTintView.isUserInteractionEnabled = false
        currentTintView.layer.cornerCurve = .continuous
        currentTintView.layer.masksToBounds = true
        movingContainer.addSubview(currentTintView)

        applyCornerGeometry()
        UIView.performWithoutAnimation {
            self.update(progress: 0)
        }
        return true
    }

    func update(progress rawProgress: CGFloat) {
        progress = min(max(rawProgress.isFinite ? rawProgress : 0, 0), 1)
        guard rootView.superview != nil else { return }

        switch style {
        case .cover:
            applyCornerGeometry()
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

    func animateRestoration(completion: @escaping () -> Void) {
        animate(to: 0, duration: 0.16) { [weak self] position in
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
        let separation = CGFloat(sin(Double.pi * Double(progress)))
        let moving = movingContainer
        let resting = restingContainer

        // The moving sheet travels a full width; the sheet it uncovers or covers
        // only gives up a little ground, which keeps the two pages spatially
        // continuous without dragging the stationary text across the screen.
        //
        // Forward the mover starts on screen and leaves; backward it starts off
        // the far edge and arrives. The same two tracks read in opposite
        // directions, so the roles are resolved once and everything else is
        // shared rather than duplicated per direction.
        moving.transform = CGAffineTransform(
            translationX: isReversed
                ? -completionTranslationX * (1 - progress)
                : completionTranslationX * progress,
            y: 0
        )
        resting.transform = CGAffineTransform(
            translationX: isReversed
                ? completionTranslationX * 0.08 * progress
                : -completionTranslationX * 0.08 * (1 - progress),
            y: 0
        )

        currentTintView.alpha = (isDark ? 0.035 : 0.012) * separation

        // Keep the overlay nearly neutral in light mode. The page shadow is the
        // separation cue; a broad opaque shade is what previously made the
        // transition look like a red or black rectangle.
        //
        // The shadow follows the mover and keeps the expression the forward
        // branch has always used. That expression keys off the travel sign, and
        // a mover that leaves travels opposite to one that arrives, so the two
        // directions are not literal mirrors of each other here — changing it
        // would alter forward, which this is not meant to touch.
        resting.layer.shadowOpacity = 0
        setShadow(
            on: moving,
            opacity: 0.20 * separation,
            leading: completionTranslationX < 0
        )
    }

    private func updateFade() {
        // Fade is deliberately a two-layer opacity-only transition. Geometry,
        // shadows, and tint layers are configured once in `install`; touching
        // them on every display-link tick used to make this mode compete with
        // the cover animator and could expose a transient blank/black frame.
        // Both immutable composites stay mounted for the complete turn.
        // `UIView.alpha` is a compositor property and does not implicitly
        // animate when assigned outside an animation block. When this method
        // is called from `UIViewPropertyAnimator`, the same assignments are
        // captured as the completion animation's endpoints.
        let easedProgress = progress * progress * (3 - 2 * progress)
        targetView.alpha = easedProgress
        currentView.alpha = 1 - easedProgress
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
        currentTintView.layer.cornerRadius = radius
    }

    private static func containerCornerRadius(for view: UIView, bounds: CGRect) -> CGFloat {
        let configured = view.effectiveRadius(corner: .allCorners)
        let fallback = view.layer.cornerRadius
        let radius = configured > 0 ? configured : fallback
        return min(max(radius, 0), min(bounds.width, bounds.height) / 2)
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
    private var animationRevision: UInt = 0
    private(set) var progress: CGFloat = 0

    init(hostView: UIView, currentView: UIView, completionTranslationX: CGFloat) {
        self.hostView = hostView
        self.currentView = currentView
        self.completionTranslationX = completionTranslationX
    }

    @discardableResult
    func install() -> Bool {
        let bounds = hostView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return false }
        currentView.frame = bounds
        currentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        currentView.layer.cornerCurve = .continuous
        currentView.layer.cornerRadius = hostView.layer.cornerRadius
        currentView.layer.masksToBounds = true
        hostView.addSubview(currentView)
        update(progress: 0)
        return true
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
        animationRevision &+= 1
        let revision = animationRevision
        animator?.stopAnimation(true)
        let duration = 0.18 * max(0.2, Double(progress))
        let animator = UIViewPropertyAnimator(duration: duration, dampingRatio: 0.82) { [weak self] in
            self?.currentView.transform = .identity
        }
        animator.addCompletion { [weak self] _ in
            guard let self, revision == self.animationRevision else { return }
            self.animator = nil
            self.progress = 0
            completion()
        }
        self.animator = animator
        animator.startAnimation()
    }

    func animateRestoration(completion: @escaping () -> Void) {
        animateCancellation(completion: completion)
    }

    func remove() {
        animationRevision &+= 1
        animator?.stopAnimation(true)
        animator = nil
        currentView.transform = .identity
        currentView.removeFromSuperview()
    }
}
