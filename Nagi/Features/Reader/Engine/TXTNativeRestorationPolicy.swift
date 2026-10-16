import Foundation
import NagiEngineCore

/// In-memory only: the coordinate is meaningful inside this exact input scope.
struct ScopedNativePosition: Equatable, Sendable {
    let scope: TXTInputScope
    let position: NativePosition
}

enum NativeCoordinateRejection: Equatable, Sendable {
    case scopeMismatch
    case unknownUnit
    case unknownNode
    case invalidStorageBoundary
}

/// Coordinate validity only, not native admission, a restored page or an exact bridge.
enum NativeCoordinateValidation: Equatable, Sendable {
    case validCoordinate(ScopedNativePosition)
    case unavailable(NativeCoordinateRejection)
}

enum TXTNativeRestorationPolicy {
    static func validate(_ candidate: ScopedNativePosition, in document: TXTIngestDocument,
                         bookID: UUID) -> NativeCoordinateValidation {
        // Compilable RED seam. The test commit must execute before implementation.
        .unavailable(.scopeMismatch)
    }
}
