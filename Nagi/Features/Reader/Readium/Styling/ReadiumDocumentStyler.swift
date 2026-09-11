import ReadiumNavigator
import UIKit

/// Owns the document-level appearance of Readium's web view: the base colours
/// applied to every native layer, and the injected override script together
/// with its retry, generation guard and preload pass.
///
/// The visible spread is always updated first; preloaded spreads follow so a
/// newly visible page is never held behind off-screen work.
@MainActor
final class ReadiumDocumentStyler {
    /// Delays between attempts to reach a visible web view: Readium creates
    /// and replaces its web views asynchronously.
    private static let retryDelays: [UInt64] = [
        0,
        16_000_000,
        50_000_000,
        100_000_000,
        200_000_000,
        400_000_000
    ]

    private weak var navigator: EPUBNavigatorViewController?
    private var visibleUpdateTask: Task<Void, Never>?
    private var preloadedUpdateTask: Task<Void, Never>?
    private var requestGeneration: UInt64 = 0

    /// The generation stamped into the most recent override request.
    var currentGeneration: UInt64 { requestGeneration }

    func attach(_ navigator: EPUBNavigatorViewController?) {
        self.navigator = navigator
    }

    /// Seeds the generation so an early user script carries a stable stamp.
    func startGenerationIfNeeded() {
        if requestGeneration == 0 {
            requestGeneration = 1
        }
    }

    /// Keeps every native layer on the resolved reader colour. A transparent
    /// hierarchy can expose WebKit's white backing store between paints.
    func applyBaseAppearance(
        snapshot: ReadiumStyleSnapshot,
        isReflowable: Bool
    ) {
        guard let navigator else { return }
        navigator.applyNagiReaderBaseAppearance(
            isReflowable: isReflowable,
            fallbackBackground: snapshot.backgroundColor
        )
    }

    /// Applies the document override to the visible spread, retrying until
    /// Readium has produced one, then updates the preloaded spreads.
    ///
    /// `isStillCurrent` lets the caller abandon the work once a newer
    /// preference generation has superseded this request.
    func refreshOverrides(
        snapshot: ReadiumStyleSnapshot,
        isReflowable: Bool,
        isStillCurrent: @escaping () -> Bool
    ) {
        visibleUpdateTask?.cancel()
        preloadedUpdateTask?.cancel()
        preloadedUpdateTask = nil
        guard let navigator, isReflowable else { return }

        requestGeneration &+= 1
        let generation = requestGeneration
        let script = ReadiumJavaScriptBuilder.override(
            snapshot: snapshot,
            requestGeneration: generation
        )
        let readinessScript = ReadiumJavaScriptBuilder.readiness(snapshot: snapshot, kind: .theme)

        visibleUpdateTask = Task { @MainActor [weak self, weak navigator] in
            guard let self, let navigator else { return }
            guard self.requestGeneration == generation else { return }

            for delay in Self.retryDelays {
                if delay > 0 {
                    do {
                        try await Task.sleep(nanoseconds: delay)
                    } catch {
                        return
                    }
                }

                guard !Task.isCancelled,
                      self.requestGeneration == generation else {
                    return
                }
                guard isStillCurrent() else { return }

                // The navigator can create its visible web view after this
                // task starts. Reapply both UIKit and document appearance so
                // the first spread cannot expose Readium's white fallback.
                self.applyBaseAppearance(snapshot: snapshot, isReflowable: isReflowable)
                await navigator.applyNagiReaderOverridesToVisible(script)

                guard !Task.isCancelled,
                      self.requestGeneration == generation else {
                    return
                }
                guard isStillCurrent() else { return }

                if await navigator.waitForNagiReaderReadiness(readinessScript) {
                    break
                }
            }

            guard !Task.isCancelled,
                  self.requestGeneration == generation else { return }
            guard isStillCurrent() else { return }

            self.preloadedUpdateTask = Task { @MainActor [weak self, weak navigator] in
                // Let the visible document render before touching preloaded pages.
                await Task.yield()
                guard let self, let navigator,
                      !Task.isCancelled,
                      self.requestGeneration == generation else {
                    return
                }
                guard isStillCurrent() else { return }
                await navigator.applyNagiReaderOverridesToPreloaded(script)
            }
        }
    }

    /// Waits for the visible document to report the requested mutation ready.
    func waitForReadiness(
        snapshot: ReadiumStyleSnapshot,
        kind: ReaderVisualMutationKind
    ) async {
        guard let navigator else { return }
        let script = ReadiumJavaScriptBuilder.readiness(snapshot: snapshot, kind: kind)
        await navigator.waitForNagiReaderReadiness(script)
    }

    /// Waits for the in-flight visible update, if any.
    func waitForPendingVisibleUpdate() async {
        if let visibleUpdateTask {
            await visibleUpdateTask.value
        }
    }

    func cancel() {
        visibleUpdateTask?.cancel()
        visibleUpdateTask = nil
        preloadedUpdateTask?.cancel()
        preloadedUpdateTask = nil
    }
}
