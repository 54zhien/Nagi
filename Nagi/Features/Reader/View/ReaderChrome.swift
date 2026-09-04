
import SwiftUI
import UIKit

@MainActor
final class ReaderTransitionCoordinator {
    private static let settleNanoseconds: UInt64 = 40_000_000
    private static let maximumTransitionNanoseconds: UInt64 = 500_000_000
    private static let fadeDuration: TimeInterval = 0.15

    private weak var captureAnchor: UIView?
    private weak var snapshotHost: ReaderSnapshotHostView?
    private var activeCover: UIView?

    private var finishTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?
    private var transitionToken = 0
    private var isTransitionActive = false
    private var activeMutationKind: ReaderVisualMutationKind = .full
    private var reduceMotion = false

    func register(captureAnchor: UIView) {
        self.captureAnchor = captureAnchor
    }

    func register(snapshotHost: ReaderSnapshotHostView) {
        self.snapshotHost = snapshotHost
    }

    func begin(kind: ReaderVisualMutationKind, reduceMotion: Bool) {
        transitionToken &+= 1
        cancelTasks()
        removeSnapshot()

        activeMutationKind = kind
        self.reduceMotion = reduceMotion
        isTransitionActive = false

        guard kind == .theme || kind == .font || kind == .full else { return }
        guard let host = snapshotHost else { return }

        host.layoutIfNeeded()
        guard host.bounds.width > 0, host.bounds.height > 0 else { return }

        let cover = UIView(frame: host.bounds)
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.backgroundColor = host.fallbackBackgroundColor
        cover.isOpaque = true
        cover.clipsToBounds = true
        cover.isUserInteractionEnabled = false
        cover.accessibilityElementsHidden = true
        cover.isAccessibilityElement = false

        if let source = captureSurface,
           source.bounds.width > 0,
           source.bounds.height > 0 {
            source.layoutIfNeeded()
            if let snapshot = source.snapshotView(afterScreenUpdates: false) {
                snapshot.frame = host.convert(source.bounds, from: source)
                snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                snapshot.isUserInteractionEnabled = false
                snapshot.accessibilityElementsHidden = true
                snapshot.isAccessibilityElement = false
                snapshot.alpha = 1
                cover.addSubview(snapshot)
            }
        }

        host.addSubview(cover)

        activeCover = cover
        isTransitionActive = true

        let token = transitionToken
        fallbackTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.maximumTransitionNanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            self?.finish(token: token)
        }
    }

    func readerStateDidUpdate(
        waitForContent: @escaping @MainActor (ReaderVisualMutationKind) async -> Void
    ) {
        let kind = activeMutationKind
        let shouldWait = isTransitionActive || kind == .typography || kind == .geometry
        guard shouldWait else { return }

        finishTask?.cancel()
        let token = transitionToken
        finishTask = Task { @MainActor [weak self] in
            await waitForContent(kind)

            guard !Task.isCancelled else { return }

            guard self?.isTransitionActive == true else {
                self?.activeMutationKind = .full
                return
            }

            do {
                try await Task.sleep(nanoseconds: Self.settleNanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            self?.finish(token: token)
        }
    }

    func cancel() {
        transitionToken &+= 1
        cancelTasks()
        isTransitionActive = false
        activeMutationKind = .full
        removeSnapshot()
    }

    private var captureSurface: UIView? {
        guard let captureAnchor else { return nil }

        var fallback: UIView?
        var current = captureAnchor.superview
        let windowSize = captureAnchor.window?.bounds.size

        while let view = current, !(view is UIWindow) {
            let size = view.bounds.size
            guard size.width > 40, size.height > 40 else {
                current = view.superview
                continue
            }

            fallback = view

            if let windowSize,
               size.width >= windowSize.width * 0.75,
               size.height >= windowSize.height * 0.75 {
                return view
            }

            current = view.superview
        }

        return fallback
    }

    private func finish(token: Int) {
        guard token == transitionToken, isTransitionActive else { return }

        finishTask?.cancel()
        finishTask = nil
        fallbackTask?.cancel()
        fallbackTask = nil
        isTransitionActive = false

        guard let cover = activeCover else { return }

        if reduceMotion {
            removeSnapshot()
            activeMutationKind = .full
            return
        }

        UIView.animate(
            withDuration: Self.fadeDuration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]
        ) {
            cover.alpha = 0
        } completion: { [weak self, weak cover] _ in
            guard let self, self.transitionToken == token else { return }
            cover?.removeFromSuperview()
            self.activeCover = nil
            self.activeMutationKind = .full
        }
    }

    private func cancelTasks() {
        finishTask?.cancel()
        finishTask = nil
        fallbackTask?.cancel()
        fallbackTask = nil
    }

    private func removeSnapshot() {
        activeCover?.removeFromSuperview()
        activeCover = nil
    }
}

final class ReaderSnapshotHostView: UIView {
    weak var coordinator: ReaderTransitionCoordinator?
    var fallbackBackgroundColor: UIColor = .clear

    override func didMoveToWindow() {
        super.didMoveToWindow()
        coordinator?.register(snapshotHost: self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        coordinator?.register(snapshotHost: self)
    }
}

struct ReaderTOCItem: Identifiable, Hashable {
    let id: String
    let title: String
    let depth: Int
}

struct ReaderTableOfContentsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let entries: [ReaderTOCItem]
    let currentID: String?
    let onSelect: (ReaderTOCItem) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView("没有目录", systemImage: "list.bullet")
                } else {
                    ScrollViewReader { proxy in
                        List(entries) { entry in
                            tocRow(entry)
                                .id(entry.id)
                        }
                        .task(id: currentID) {
                            guard let currentID else { return }
                            await Task.yield()
                            proxy.scrollTo(currentID, anchor: .center)
                        }
                    }
                }
            }
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func tocRow(_ entry: ReaderTOCItem) -> some View {
        let isCurrent = entry.id == currentID

        return Button {
            onSelect(entry)
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bookmark.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    .opacity(isCurrent ? 1 : 0)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)

                Text(entry.title)
                    .foregroundStyle(.primary)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(entry.depth) * 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCurrent ? "\(entry.title)，当前阅读章节" : entry.title)
    }
}
