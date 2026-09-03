
import Foundation

@MainActor
final class ReaderMutationScheduler<Value> {
    typealias Commit = (Value, UInt64) -> Void

    private let delayNanoseconds: UInt64
    private let commit: Commit
    private var pendingValue: Value?
    private var pendingGeneration: UInt64 = 0
    private var committedGeneration: UInt64 = 0
    private var commitTask: Task<Void, Never>?
    private var commitWaiters: [CommitWaiter] = []

    private struct CommitWaiter {
        let generation: UInt64
        let continuation: CheckedContinuation<UInt64, Never>
    }

    init(
        delayNanoseconds: UInt64 = 16_000_000,
        commit: @escaping Commit
    ) {
        self.delayNanoseconds = delayNanoseconds
        self.commit = commit
    }

    var hasPendingValue: Bool {
        pendingValue != nil
    }

    func waitForPendingCommit() async -> UInt64 {
        let targetGeneration = pendingValue == nil
            ? committedGeneration
            : pendingGeneration
        guard targetGeneration > committedGeneration else {
            return committedGeneration
        }

        return await withCheckedContinuation { continuation in
            if targetGeneration <= committedGeneration || pendingValue == nil {
                continuation.resume(returning: committedGeneration)
            } else {
                commitWaiters.append(
                    CommitWaiter(
                        generation: targetGeneration,
                        continuation: continuation
                    )
                )
            }
        }
    }

    func enqueue(_ value: Value) {
        pendingValue = value
        pendingGeneration &+= 1
        scheduleCommit()
    }

    func flush() {
        commitTask?.cancel()
        commitTask = nil
        commitPendingValue()
    }

    func cancel() {
        commitTask?.cancel()
        commitTask = nil
        pendingValue = nil
        resumeWaiters(with: committedGeneration)
    }

    private func scheduleCommit() {
        commitTask?.cancel()
        let delay = delayNanoseconds
        commitTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }

            guard let self, !Task.isCancelled else { return }
            self.commitPendingValue()
        }
    }

    private func commitPendingValue() {
        guard let pendingValue else { return }
        let generation = pendingGeneration
        self.pendingValue = nil
        commitTask = nil
        commit(pendingValue, generation)
        ReaderPerformanceSignposts.readerMutationCommitted()
        committedGeneration = generation
        resumeWaiters(with: generation)
    }

    private func resumeWaiters(with generation: UInt64) {
        let readyWaiters = commitWaiters.filter { $0.generation <= generation }
        commitWaiters.removeAll { $0.generation <= generation }
        for waiter in readyWaiters {
            waiter.continuation.resume(returning: generation)
        }
    }
}
