import Foundation
import OSLog
import SwiftData

/// Records persistence failures instead of letting `try?` discard them.
///
/// Saving or querying the store used to swallow its error, so a failed write
/// and a failed read were indistinguishable from an empty result.  Callers
/// keep the exact same behaviour — a failed save still returns `false` and a
/// failed fetch still yields an empty array — but the failure is now written
/// to the log together with the operation that caused it.
enum PersistenceLog {
    private static let logger = Logger(
        subsystem: "com.imzhien.Nagi",
        category: "persistence"
    )

    static func record(_ error: any Error, operation: String) {
        logger.error(
            "\(operation, privacy: .public) 失败：\(error.localizedDescription, privacy: .public)"
        )
    }
}

extension ModelContext {
    /// Saves the context, logging instead of discarding a failure.
    @discardableResult
    func saveLogged(operation: String) -> Bool {
        do {
            try save()
            return true
        } catch {
            PersistenceLog.record(error, operation: operation)
            return false
        }
    }

    /// Fetches models, logging instead of discarding a failure.
    ///
    /// A failed fetch still returns an empty array, matching the previous
    /// `(try? fetch(...)) ?? []` behaviour.
    func fetchLogged<Model: PersistentModel>(
        _ descriptor: FetchDescriptor<Model>,
        operation: String
    ) -> [Model] {
        do {
            return try fetch(descriptor)
        } catch {
            PersistenceLog.record(error, operation: operation)
            return []
        }
    }
}
