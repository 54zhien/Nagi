import CoreGraphics
import Foundation
import UIKit

/// The logical direction of a page turn. The physical direction is derived
/// from the book's reading direction by `PageTurnMetrics`.
public enum PageDirection: String, CaseIterable, Sendable {
    case forward
    case backward
}

public enum PageTurnReadingDirection: String, Sendable {
    case leftToRight
    case rightToLeft
}

public enum PageTurnEdge: String, Sendable {
    case left
    case right
}

public enum PageTurnState: String, Sendable {
    case idle
    case preparing
    case interactive
    case completing
    case cancelling
    case committing
    case fallback
}

public enum PageTurnDecision: String, Sendable {
    case complete
    case cancel
}

public enum PageTurnFallbackReason: String, Sendable {
    case surfaceUnavailable
    case snapshotFailed
    case memoryPressure
    case layoutInvalidated
    case unsupportedContent
}

/// Values which affect gesture hit testing and the interactive decision.
/// Keeping them in one value makes the policy easy to unit test and tune on
/// device without coupling it to UIKit, Readium, or a renderer.
public struct PageTurnConfiguration: Equatable, Sendable {
    public var edgeHitFraction: CGFloat
    public var minimumEdgeHitWidth: CGFloat
    public var maximumEdgeHitWidth: CGFloat
    public var completionProgress: CGFloat
    public var flingVelocity: CGFloat

    public init(
        edgeHitFraction: CGFloat = 0.16,
        minimumEdgeHitWidth: CGFloat = 52,
        maximumEdgeHitWidth: CGFloat = 72,
        completionProgress: CGFloat = 0.26,
        flingVelocity: CGFloat = 700
    ) {
        self.edgeHitFraction = edgeHitFraction
        self.minimumEdgeHitWidth = minimumEdgeHitWidth
        self.maximumEdgeHitWidth = maximumEdgeHitWidth
        self.completionProgress = completionProgress
        self.flingVelocity = flingVelocity
    }
}

/// Pure geometry and gesture-policy helpers for the page-turn engine.
public enum PageTurnMetrics {
    public static let defaultConfiguration = PageTurnConfiguration()

    /// Returns the width of either edge tap zone, clamped to 52...72pt.
    public static func edgeHitWidth(
        for screenWidth: CGFloat,
        configuration: PageTurnConfiguration = defaultConfiguration
    ) -> CGFloat {
        guard screenWidth.isFinite, screenWidth > 0 else { return 0 }

        let lowerBound = max(0, min(configuration.minimumEdgeHitWidth, configuration.maximumEdgeHitWidth))
        let upperBound = max(lowerBound, configuration.maximumEdgeHitWidth)
        let proportionalWidth = screenWidth * max(0, configuration.edgeHitFraction)
        return min(max(proportionalWidth, lowerBound), upperBound)
    }

    public static func edgeHit(
        atX x: CGFloat,
        screenWidth: CGFloat,
        configuration: PageTurnConfiguration = defaultConfiguration
    ) -> PageTurnEdge? {
        guard x.isFinite, screenWidth.isFinite, screenWidth > 0,
              x >= 0, x <= screenWidth else { return nil }

        let width = edgeHitWidth(for: screenWidth, configuration: configuration)
        if x <= width { return .left }
        if x >= screenWidth - width { return .right }
        return nil
    }

    public static func pageDirection(
        for edge: PageTurnEdge,
        readingDirection: PageTurnReadingDirection = .leftToRight
    ) -> PageDirection {
        switch (edge, readingDirection) {
        case (.right, .leftToRight), (.left, .rightToLeft):
            return .forward
        case (.left, .leftToRight), (.right, .rightToLeft):
            return .backward
        }
    }

    /// Converts a raw horizontal translation into a 0...1 logical progress.
    public static func progress(
        forTranslationX translationX: CGFloat,
        containerWidth: CGFloat,
        direction: PageDirection,
        readingDirection: PageTurnReadingDirection = .leftToRight
    ) -> CGFloat {
        guard translationX.isFinite, containerWidth.isFinite, containerWidth > 0 else { return 0 }
        let travelSign = physicalTravelSign(for: direction, readingDirection: readingDirection)
        return clamp((translationX * travelSign) / containerWidth)
    }

    /// Decides whether release should complete or cancel the current turn.
    /// `velocityX` is the raw UIKit-style horizontal velocity in points/sec.
    public static func decision(
        progress: CGFloat,
        velocityX: CGFloat,
        direction: PageDirection,
        readingDirection: PageTurnReadingDirection = .leftToRight,
        configuration: PageTurnConfiguration = defaultConfiguration
    ) -> PageTurnDecision {
        let normalizedProgress = clamp(progress)
        let normalizedVelocity = velocityX.isFinite
            ? velocityX * physicalTravelSign(for: direction, readingDirection: readingDirection)
            : 0

        if normalizedProgress >= configuration.completionProgress || normalizedVelocity >= configuration.flingVelocity {
            return .complete
        }
        return .cancel
    }

    /// Horizontal destination for the outgoing page in container coordinates.
    public static func completionTranslationX(
        containerWidth: CGFloat,
        direction: PageDirection,
        readingDirection: PageTurnReadingDirection = .leftToRight
    ) -> CGFloat {
        guard containerWidth.isFinite, containerWidth > 0 else { return 0 }
        return containerWidth * physicalTravelSign(for: direction, readingDirection: readingDirection)
    }

    private static func physicalTravelSign(
        for direction: PageDirection,
        readingDirection: PageTurnReadingDirection
    ) -> CGFloat {
        switch (direction, readingDirection) {
        case (.forward, .leftToRight), (.backward, .rightToLeft):
            return -1
        case (.backward, .leftToRight), (.forward, .rightToLeft):
            return 1
        }
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value.isFinite ? value : 0, 0), 1)
    }
}

/// A detached, single-use visual page owned by a renderer-specific provider.
@MainActor
public final class PageSurface {
    public let id: UUID
    public let direction: PageDirection
    public let view: UIView

    public init(id: UUID = UUID(), direction: PageDirection, view: UIView) {
        self.id = id
        self.direction = direction
        self.view = view
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.isAccessibilityElement = false
    }
}

/// Renderer seam used by page animations without exposing Readium types.
@MainActor
public protocol PageSurfaceProvider: AnyObject {
    var readingDirection: PageTurnReadingDirection { get }

    func prepareAdjacentSurface(direction: PageDirection) async -> PageSurface?
    func commit(surface: PageSurface) async -> Bool
    func cancel(surface: PageSurface)
    func navigateWithoutCustomTransition(direction: PageDirection) async -> Bool
    func setBuiltInPageTurnInteractionEnabled(_ enabled: Bool)
    func invalidatePreparedSurfaces()
}

/// Main-thread state machine for coordinating surfaces, animation, and the
/// eventual Readium locator commit. All asynchronous renderer callbacks carry
/// the generation returned by `prepare`; stale callbacks are rejected after
/// `invalidate()` or a newer turn.
@MainActor
public final class PageTurnStateMachine {
    public private(set) var state: PageTurnState = .idle
    public private(set) var generation: UInt = 0
    public private(set) var direction: PageDirection?
    public private(set) var progress: CGFloat = 0

    public init() {}

    /// Starts preparing a turn and returns its callback generation.
    @discardableResult
    public func prepare(direction: PageDirection) -> UInt? {
        guard state == .idle else { return nil }

        generation &+= 1
        self.direction = direction
        progress = 0
        state = .preparing
        return generation
    }

    @discardableResult
    public func beginInteractive(generation: UInt) -> Bool {
        guard accepts(generation), state == .preparing else { return false }
        state = .interactive
        return true
    }

    @discardableResult
    public func updateInteractive(progress: CGFloat, generation: UInt) -> Bool {
        guard accepts(generation), state == .interactive else { return false }
        self.progress = min(max(progress.isFinite ? progress : 0, 0), 1)
        return true
    }

    @discardableResult
    public func finish(
        with decision: PageTurnDecision,
        generation: UInt
    ) -> Bool {
        guard accepts(generation), state == .interactive else { return false }
        state = decision == .complete ? .completing : .cancelling
        return true
    }

    @discardableResult
    public func beginCommitting(generation: UInt) -> Bool {
        guard accepts(generation), state == .completing else { return false }
        state = .committing
        return true
    }

    @discardableResult
    public func enterFallback(
        _ reason: PageTurnFallbackReason,
        generation: UInt
    ) -> Bool {
        guard accepts(generation), state != .idle else { return false }
        state = .fallback
        return true
    }

    /// Ends a successful locator commit or fallback animation.
    @discardableResult
    public func finish(generation: UInt) -> Bool {
        guard accepts(generation), state == .committing || state == .fallback else { return false }
        resetToIdle()
        return true
    }

    /// Ends a cancellation animation without changing the committed locator.
    @discardableResult
    public func finishCancellation(generation: UInt) -> Bool {
        guard accepts(generation), state == .cancelling else { return false }
        resetToIdle()
        return true
    }

    /// Invalidates every in-flight callback and returns to a stable state.
    /// Used for rotation, theme/layout changes, backgrounding, and teardown.
    public func invalidate() {
        generation &+= 1
        resetToIdle()
    }

    public func accepts(_ callbackGeneration: UInt) -> Bool {
        callbackGeneration == generation
    }

    private func resetToIdle() {
        state = .idle
        direction = nil
        progress = 0
    }
}
