//
//  PageTextView.swift
//  Nagi
//
//  单页文本渲染（用 UITextView 展示一页 AttributedString）。
//

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
    let onSwipeStart: (() -> Void)?
    let onProgress: ((Double) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onSwipeStart: onSwipeStart, onProgress: onProgress)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isScrollEnabled = true
        textView.isEditable = false
        textView.isSelectable = false
        textView.backgroundColor = UIColor(background)
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = insets
        textView.contentInsetAdjustmentBehavior = .never
        textView.showsVerticalScrollIndicator = false
        textView.alwaysBounceVertical = true
        textView.delegate = context.coordinator
        context.coordinator.revision = revision
        context.coordinator.positionID = positionID
        textView.attributedText = attributedText
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.backgroundColor = UIColor(background)
        context.coordinator.onSwipeStart = onSwipeStart
        context.coordinator.onProgress = onProgress

        guard context.coordinator.revision != revision else { return }
        let preservePosition = context.coordinator.positionID == positionID
        let previousProgress = preservePosition
            ? context.coordinator.progress(in: textView)
            : 0

        context.coordinator.revision = revision
        context.coordinator.positionID = positionID
        textView.textContainerInset = insets
        textView.attributedText = attributedText
        textView.layoutIfNeeded()

        let visibleHeight = textView.bounds.height - textView.adjustedContentInset.top
            - textView.adjustedContentInset.bottom
        let maximumOffset = max(textView.contentSize.height - visibleHeight, 0)
        let offsetY = previousProgress * maximumOffset - textView.adjustedContentInset.top
        textView.setContentOffset(
            CGPoint(x: -textView.adjustedContentInset.left, y: offsetY),
            animated: false
        )
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var revision = -1
        var positionID = ""
        var onSwipeStart: (() -> Void)?
        var onProgress: ((Double) -> Void)?

        init(onSwipeStart: (() -> Void)?, onProgress: ((Double) -> Void)?) {
            self.onSwipeStart = onSwipeStart
            self.onProgress = onProgress
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            onSwipeStart?()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let progress = progress(in: scrollView)
            onProgress?(Double(progress))
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
