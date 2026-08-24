//
//  PageTextView.swift
//  Seidoku
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
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.textContainerInset = insets
        textView.attributedText = attributedText
    }
}
