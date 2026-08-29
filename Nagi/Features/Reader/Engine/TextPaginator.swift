//
//  TextPaginator.swift
//  Nagi
//
//  TextKit 分页引擎：把章节正文按页面尺寸精确分成一页页。
//

import UIKit

enum TextPaginator {
    struct Page {
        let attributedText: NSAttributedString
        let characterRange: NSRange
    }

    /// 把带排版属性的文本按页面尺寸分页，并保留每页对应的字符范围。
    /// 字符范围让排版变化时可以回到同一段文字，而不是只回到旧页码比例。
    static func paginate(
        _ text: NSAttributedString,
        pageSize: CGSize,
        insets: UIEdgeInsets
    ) -> [Page] {
        guard text.length > 0 else { return [] }

        let contentSize = CGSize(
            width: max(pageSize.width - insets.left - insets.right, 1),
            height: max(pageSize.height - insets.top - insets.bottom, 1)
        )

        let textStorage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        var pages: [NSAttributedString] = []
        var location = 0

        while location < textStorage.length {
            let textContainer = NSTextContainer(size: contentSize)
            textContainer.lineFragmentPadding = 0
            textContainer.maximumNumberOfLines = 0
            layoutManager.addTextContainer(textContainer)

            let glyphRange = layoutManager.glyphRange(for: textContainer)
            let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

            // A zero or backwards range means TextKit could not make forward
            // progress (usually because the available container is too small).
            // Preserve the remaining text instead of silently dropping it.
            guard charRange.length > 0,
                  charRange.location >= location,
                  NSMaxRange(charRange) <= textStorage.length else {
                let remaining = NSRange(
                    location: location,
                    length: textStorage.length - location
                )
                pages.append(Page(
                    attributedText: textStorage.attributedSubstring(from: remaining),
                    characterRange: remaining
                ))
                break
            }

            pages.append(Page(
                attributedText: textStorage.attributedSubstring(from: charRange),
                characterRange: charRange
            ))
            location = NSMaxRange(charRange)
        }

        return pages
    }
}
