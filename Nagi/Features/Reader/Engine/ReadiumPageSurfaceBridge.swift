import Foundation
import ReadiumNavigator
import UIKit

/// Adapts Readium's prepared page values to the App-owned surface contract.
enum ReadiumPageSurfaceBridge {
    static func positionIdentity(
        _ identity: NavigatorPagePositionIdentity,
        namespace: UUID
    ) -> PagePositionIdentity {
        PagePositionIdentity(namespace: namespace, value: identity)
    }

    static func surfaceIdentity(
        _ identity: NavigatorPageSurfaceIdentity,
        namespace: UUID
    ) -> PageSurfaceIdentity {
        PageSurfaceIdentity(namespace: namespace, value: identity)
    }

    static func geometry(_ geometry: NavigatorPageSurfaceGeometry) -> PageSurfaceGeometry {
        PageSurfaceGeometry(
            pointSize: geometry.pointSize,
            pixelSize: geometry.pixelSize,
            scale: geometry.scale,
            contentRect: geometry.contentRect
        )
    }

    static func readiness(
        _ readiness: NavigatorPageSurfaceReadiness
    ) -> PageSurfaceReadiness {
        switch readiness {
        case .unknown:
            return .unknown
        case .unavailable:
            return .unavailable
        case .preparing:
            return .preparing
        case .ready:
            return .ready
        case .failed:
            return .failed
        }
    }

    @MainActor
    static func currentSurface(
        _ surface: NavigatorCurrentPageSurface,
        namespace: UUID
    ) -> CurrentPageSurface {
        CurrentPageSurface(
            image: surface.image,
            geometry: geometry(surface.geometry),
            identity: positionIdentity(surface.identity, namespace: namespace),
            generation: surface.generation
        )
    }
}
