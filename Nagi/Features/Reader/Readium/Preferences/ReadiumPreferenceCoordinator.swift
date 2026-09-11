import ReadiumNavigator
import UIKit

/// Owns the coalescing of Readium preference submissions.
///
/// Preference changes arrive faster than Readium can relayout, so they are
/// queued as immutable payloads, coalesced, and committed together. The
/// coordinator also tracks which visual mutation the last commit represents,
/// so a caller can wait for exactly the part of the document it changed.
@MainActor
final class ReadiumPreferenceCoordinator {
    private weak var navigator: EPUBNavigatorViewController?
    private var pendingMutationKind: ReaderVisualMutationKind?

    /// The visual mutation the most recent commit represents.
    private(set) var latestCommittedMutationKind: ReaderVisualMutationKind = .full
    /// The generation of the most recent commit.
    private(set) var latestGeneration: UInt64 = 0

    /// Called once a payload has reached Readium.
    var didCommit: ((UInt64) -> Void)?

    private lazy var scheduler = ReaderMutationScheduler<EPUBPreferences>(
        delayNanoseconds: 16_000_000
    ) { [weak self] preferences, generation in
        self?.commit(preferences, generation: generation)
    }

    func attach(_ navigator: EPUBNavigatorViewController?) {
        self.navigator = navigator
    }

    /// Queues a payload. Does nothing when no navigator is attached yet.
    func enqueue(_ preferences: EPUBPreferences, kind: ReaderVisualMutationKind? = nil) {
        guard navigator != nil else { return }
        if let kind {
            pendingMutationKind = pendingMutationKind?.merged(with: kind) ?? kind
        }
        scheduler.enqueue(preferences)
    }

    func flush() {
        scheduler.flush()
    }

    func cancel() {
        scheduler.cancel()
    }

    func waitForPendingCommit() async {
        _ = await scheduler.waitForPendingCommit()
    }

    private func commit(_ preferences: EPUBPreferences, generation: UInt64) {
        guard let navigator else { return }
        let mutationKind = pendingMutationKind ?? .full
        pendingMutationKind = nil
        latestCommittedMutationKind = mutationKind
        latestGeneration = generation
        navigator.submitPreferences(preferences)
        didCommit?(generation)
    }
}
