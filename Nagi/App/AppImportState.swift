
import Foundation
import Observation

@MainActor
@Observable
final class AppImportState {
    static let shared = AppImportState()

    var message: String?

    private init() {}
}
