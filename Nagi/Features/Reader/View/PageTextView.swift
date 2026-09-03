
import SwiftUI
import UIKit

struct PageTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    let insets: UIEdgeInsets

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isScrollEnabled = false
        textView.isEditable = false
        textView.isSelectable = false
        textView.backgroundColor = .clear
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = insets
        textView.contentInsetAdjustmentBehavior = .never
        textView.attributedText = attributedText
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.textContainerInset = insets
        textView.attributedText = attributedText
    }
}

struct ScrollableTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    let insets: UIEdgeInsets
    let background: Color
    let revision: Int
    let positionID: String
    let initialCharacterOffset: Int?
    let initialProgress: Double
    let onSwipeStart: (() -> Void)?
    let onCharacterOffset: ((Int) -> Void)?
    let onProgress: ((Double) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSwipeStart: onSwipeStart,
            onCharacterOffset: onCharacterOffset,
            onProgress: onProgress
        )
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: true)
        textView.isScrollEnabled = true
        textView.isEditable = false
        textView.isSelectable = false
        textView.backgroundColor = UIColor(background)
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = insets
        textView.contentInsetAdjustmentBehavior = .never
        textView.showsVerticalScrollIndicator = false
        textView.alwaysBounceVertical = false
        textView.delegate = context.coordinator
        context.coordinator.revision = revision
        context.coordinator.positionID = positionID
        context.coordinator.isApplyingPosition = true
        textView.attributedText = attributedText
        textView.layoutIfNeeded()
        context.coordinator.applyPosition(
            in: textView,
            characterOffset: initialCharacterOffset,
            progress: initialProgress
        )
        context.coordinator.isApplyingPosition = false
        context.coordinator.notifyPosition(in: textView)
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak textView, weak coordinator] in
            guard let textView, let coordinator else { return }
            coordinator.applyPendingPositionIfPossible(in: textView)
        }
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.backgroundColor = UIColor(background)
        context.coordinator.onSwipeStart = onSwipeStart
        context.coordinator.onCharacterOffset = onCharacterOffset
        context.coordinator.onProgress = onProgress

        let revisionChanged = context.coordinator.revision != revision
        let positionChanged = context.coordinator.positionID != positionID
        guard revisionChanged || positionChanged else { return }

        let preservePosition = !positionChanged
        let previousCharacterOffset = preservePosition
            ? context.coordinator.characterOffset(in: textView)
            : nil
        let previousProgress = preservePosition ? context.coordinator.progress(in: textView) : initialProgress

        context.coordinator.revision = revision
        context.coordinator.positionID = positionID
        context.coordinator.isApplyingPosition = true
        textView.textContainerInset = insets
        textView.attributedText = attributedText
        textView.layoutIfNeeded()
        context.coordinator.applyPosition(
            in: textView,
            characterOffset: previousCharacterOffset ?? initialCharacterOffset,
            progress: previousProgress
        )
        context.coordinator.isApplyingPosition = false
        context.coordinator.notifyPosition(in: textView)
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak textView, weak coordinator] in
            guard let textView, let coordinator else { return }
            coordinator.applyPendingPositionIfPossible(in: textView)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var revision = -1
        var positionID = ""
        var onSwipeStart: (() -> Void)?
        var onCharacterOffset: ((Int) -> Void)?
        var onProgress: ((Double) -> Void)?
        var isApplyingPosition = false
        private var pendingCharacterOffset: Int?
        private var pendingProgress = 0.0
        private var positionNeedsLayout = false

        init(
            onSwipeStart: (() -> Void)?,
            onCharacterOffset: ((Int) -> Void)?,
            onProgress: ((Double) -> Void)?
        ) {
            self.onSwipeStart = onSwipeStart
            self.onCharacterOffset = onCharacterOffset
            self.onProgress = onProgress
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            onSwipeStart?()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isApplyingPosition else { return }
            onCharacterOffset?(characterOffset(in: scrollView))
            let progress = progress(in: scrollView)
            onProgress?(Double(progress))
        }

        func notifyPosition(in textView: UITextView) {
            guard textView.bounds.width > 0, textView.bounds.height > 0 else { return }
            onCharacterOffset?(characterOffset(in: textView))
            onProgress?(Double(progress(in: textView)))
        }

        func applyPosition(
            in textView: UITextView,
            characterOffset: Int?,
            progress: Double
        ) {
            guard textView.bounds.width > 0, textView.bounds.height > 0 else {
                pendingCharacterOffset = characterOffset
                pendingProgress = progress
                positionNeedsLayout = true
                return
            }

            if let textLayoutManager = textView.textLayoutManager {
                textLayoutManager.ensureLayout(for: textView.bounds)
            } else {
                textView.layoutManager.ensureLayout(for: textView.textContainer)
            }
            let visibleHeight = textView.bounds.height - textView.adjustedContentInset.top
                - textView.adjustedContentInset.bottom
            let maximumOffset = max(textView.contentSize.height - visibleHeight, 0)
            let minimumY = -textView.adjustedContentInset.top
            let maximumY = max(minimumY, maximumOffset - textView.adjustedContentInset.top)

            let desiredY: CGFloat
            if let characterOffset,
               let position = textView.position(
                   from: textView.beginningOfDocument,
                   offset: min(max(characterOffset, 0), textView.textStorage.length)
               ) {
                let caretRect = textView.caretRect(for: position)
                desiredY = caretRect.minY - textView.textContainerInset.top
            } else {
                desiredY = CGFloat(min(max(progress, 0), 1)) * maximumOffset
                    - textView.adjustedContentInset.top
            }

            textView.setContentOffset(
                CGPoint(
                    x: -textView.adjustedContentInset.left,
                    y: min(max(desiredY, minimumY), maximumY)
                ),
                animated: false
            )
            pendingCharacterOffset = nil
            positionNeedsLayout = false
        }

        func applyPendingPositionIfPossible(in textView: UITextView) {
            guard positionNeedsLayout,
                  textView.bounds.width > 0,
                  textView.bounds.height > 0 else { return }
            isApplyingPosition = true
            applyPosition(
                in: textView,
                characterOffset: pendingCharacterOffset,
                progress: pendingProgress
            )
            isApplyingPosition = false
            notifyPosition(in: textView)
        }

        func characterOffset(in scrollView: UIScrollView) -> Int {
            guard let textView = scrollView as? UITextView,
                  textView.textStorage.length > 0 else { return 0 }
            let point = CGPoint(
                x: textView.bounds.midX,
                y: textView.bounds.minY + textView.textContainerInset.top + 1
            )
            guard let position = textView.closestPosition(to: point) else { return 0 }
            return textView.offset(from: textView.beginningOfDocument, to: position)
        }

        func progress(in scrollView: UIScrollView) -> CGFloat {
            let visibleHeight = scrollView.bounds.height - scrollView.adjustedContentInset.top
                - scrollView.adjustedContentInset.bottom
            let denominator = max(scrollView.contentSize.height - visibleHeight, 1)
            let offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
            return min(max(offset / denominator, 0), 1)
        }
    }
}
