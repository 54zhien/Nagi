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
        guard candidate.scope == document.scope(for: bookID) else {
            return .unavailable(.scopeMismatch)
        }
        let position = candidate.position
        guard let unit = document.units.first(where: {
            DocumentUnitID(rawValue: $0.unitID) == position.unitID
        }) else {
            return .unavailable(.unknownUnit)
        }
        guard NodeID(rawValue: unit.nodeID) == position.nodeID else {
            return .unavailable(.unknownNode)
        }
        let segment = PrimaryTextSegment(unitID: position.unitID, string: unit.chapter.content)
        guard segment.isStorageBoundary(at: position.utf16Offset) else {
            return .unavailable(.invalidStorageBoundary)
        }
        return .validCoordinate(candidate)
    }
}
