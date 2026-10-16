import CoreGraphics
import Foundation

/// Session-scoped identity for a navigator position.
public struct PagePositionIdentity: Hashable {
    private let namespace: UUID
    private let payloadType: ObjectIdentifier
    private let payload: AnyHashable

    public init<Key: Hashable>(namespace: UUID, value: Key) {
        self.namespace = namespace
        payloadType = ObjectIdentifier(Key.self)
        payload = AnyHashable(value)
    }
}

/// Session-scoped identity for a detached page surface.
public struct PageSurfaceIdentity: Hashable {
    private let namespace: UUID
    private let payloadType: ObjectIdentifier
    private let payload: AnyHashable

    public init<Key: Hashable>(namespace: UUID, value: Key) {
        self.namespace = namespace
        payloadType = ObjectIdentifier(Key.self)
        payload = AnyHashable(value)
    }
}

/// Geometry already measured for a detached page image.
public struct PageSurfaceGeometry: Equatable {
    public let pointSize: CGSize
    public let pixelSize: CGSize
    public let scale: CGFloat
    public let contentRect: CGRect

    public init(
        pointSize: CGSize,
        pixelSize: CGSize,
        scale: CGFloat,
        contentRect: CGRect
    ) {
        self.pointSize = pointSize
        self.pixelSize = pixelSize
        self.scale = scale
        self.contentRect = contentRect
    }
}

public enum PageSurfaceReadiness: Equatable {
    case unknown
    case unavailable
    case preparing
    case ready
    case failed
}
