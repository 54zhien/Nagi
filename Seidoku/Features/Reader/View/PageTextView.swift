//
//  PageTextView.swift
//  Seidoku
//
//  TXT 页面单元格中的原生文本视图。
//

import UIKit

final class TXTPageCell: UICollectionViewCell {
    static let reuseIdentifier = "TXTPageCell"

    private let textView = UITextView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .clear
        contentView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.isUserInteractionEnabled = false
        textView.backgroundColor = .clear
        textView.contentInsetAdjustmentBehavior = .never
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.lineBreakMode = .byCharWrapping
        textView.textContainer.widthTracksTextView = true
        textView.textContainer.heightTracksTextView = false

        contentView.addSubview(textView)
        textView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            textView.topAnchor.constraint(equalTo: contentView.topAnchor),
            textView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        attributedText: NSAttributedString,
        insets: UIEdgeInsets,
        background: UIColor
    ) {
        backgroundColor = background
        contentView.backgroundColor = background
        textView.backgroundColor = background
        textView.textContainerInset = insets
        textView.attributedText = attributedText
        textView.setContentOffset(.zero, animated: false)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        textView.attributedText = nil
    }
}

final class TXTPageController: UIViewController {
    let pageIndex: Int
    private let textView = UITextView()

    init(
        pageIndex: Int,
        attributedText: NSAttributedString,
        insets: UIEdgeInsets,
        background: UIColor
    ) {
        self.pageIndex = pageIndex
        super.init(nibName: nil, bundle: nil)
        view.backgroundColor = background
        textView.backgroundColor = background
        textView.attributedText = attributedText
        textView.textContainerInset = insets
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.isUserInteractionEnabled = false
        textView.contentInsetAdjustmentBehavior = .never
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.lineBreakMode = .byCharWrapping
        textView.textContainer.widthTracksTextView = true
        textView.textContainer.heightTracksTextView = false

        view.addSubview(textView)
        textView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

struct TXTScrollableTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    let layoutKey: TXTLayoutKey
    let insets: UIEdgeInsets
    let background: UIColor
    let restoreTextOffset: Int
    let initialContentOffset: CGFloat
    let onLocationChanged: (CGFloat, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = true
        textView.backgroundColor = background
        textView.contentInsetAdjustmentBehavior = .never
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.lineBreakMode = .byCharWrapping
        textView.textContainer.widthTracksTextView = true
        textView.textContainer.heightTracksTextView = false
        textView.textContainerInset = insets
        textView.attributedText = attributedText
        textView.layoutIfNeeded()

        context.coordinator.lastLayoutKey = layoutKey
        context.coordinator.restorePosition(
            textOffset: restoreTextOffset,
            contentOffset: initialContentOffset,
            in: textView
        )
        DispatchQueue.main.async { [weak textView, weak coordinator = context.coordinator] in
            guard let textView, let coordinator else { return }
            coordinator.restorePosition(
                textOffset: restoreTextOffset,
                contentOffset: initialContentOffset,
                in: textView
            )
        }
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        textView.backgroundColor = background

        guard context.coordinator.lastLayoutKey != layoutKey else { return }
        context.coordinator.lastLayoutKey = layoutKey
        textView.textContainerInset = insets
        textView.attributedText = attributedText
        textView.layoutIfNeeded()
        context.coordinator.restorePosition(
            textOffset: restoreTextOffset,
            contentOffset: initialContentOffset,
            in: textView
        )
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: TXTScrollableTextView
        var lastLayoutKey: TXTLayoutKey?
        private var lastReportedOffset = CGFloat.nan
        private var lastReportedTextOffset = -1

        init(_ parent: TXTScrollableTextView) {
            self.parent = parent
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let textView = scrollView as? UITextView else { return }
            let contentOffset = max(0, textView.contentOffset.y)
            let textOffset = visibleTextOffset(in: textView)
            guard abs(contentOffset - lastReportedOffset) > 0.5 ||
                    textOffset != lastReportedTextOffset else { return }
            lastReportedOffset = contentOffset
            lastReportedTextOffset = textOffset
            parent.onLocationChanged(contentOffset, textOffset)
        }

        func restorePosition(textOffset: Int, contentOffset: CGFloat, in textView: UITextView) {
            guard let text = textView.attributedText, text.length > 0 else {
                textView.setContentOffset(.zero, animated: false)
                return
            }

            let characterIndex = min(max(textOffset, 0), text.length - 1)
            let glyphRange = textView.layoutManager.glyphRange(
                forCharacterRange: NSRange(location: characterIndex, length: 1),
                actualCharacterRange: nil
            )
            guard glyphRange.location != NSNotFound, glyphRange.length > 0 else {
                textView.setContentOffset(.zero, animated: false)
                return
            }

            let rect = textView.layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textView.textContainer
            )
            let y = max(
                -textView.adjustedContentInset.top,
                rect.minY + textView.textContainerInset.top - 12
            )
            textView.setContentOffset(
                CGPoint(x: -textView.adjustedContentInset.left, y: y),
                animated: false
            )

            if textOffset == 0, contentOffset > 0 {
                textView.setContentOffset(
                    CGPoint(x: -textView.adjustedContentInset.left, y: contentOffset),
                    animated: false
                )
            }
        }

        private func visibleTextOffset(in textView: UITextView) -> Int {
            guard let text = textView.attributedText, text.length > 0 else { return 0 }

            let point = CGPoint(
                x: max(0, textView.textContainerInset.left + 1),
                y: max(0, textView.contentOffset.y - textView.textContainerInset.top + 8)
            )
            let glyphIndex = min(
                max(textView.layoutManager.glyphIndex(for: point, in: textView.textContainer), 0),
                max(0, textView.layoutManager.numberOfGlyphs - 1)
            )
            let characterRange = textView.layoutManager.characterRange(
                forGlyphRange: NSRange(location: glyphIndex, length: 1),
                actualGlyphRange: nil
            )
            return min(max(characterRange.location, 0), text.length)
        }
    }
}
