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

        var pages: [Page] = []
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
                    attributedText: pageText(from: textStorage, range: remaining),
                    characterRange: remaining
                ))
                break
            }

            pages.append(Page(
                attributedText: pageText(from: textStorage, range: charRange),
                characterRange: charRange
            ))
            location = NSMaxRange(charRange)
        }

        return pages
    }

    /// A page is rendered in its own text view, so a page that starts in the
    /// middle of a paragraph would otherwise be treated as that paragraph's
    /// first line again.  Remove only the first-line indent for that leading
    /// continuation; all other typography stays identical to the full layout
    /// used for pagination.
    private static func pageText(
        from textStorage: NSTextStorage,
        range: NSRange
    ) -> NSAttributedString {
        let page = NSMutableAttributedString(
            attributedString: textStorage.attributedSubstring(from: range)
        )
        guard range.length > 0 else { return page }

        let source = textStorage.string as NSString
        var paragraphStart = 0
        var paragraphEnd = 0
        var contentsEnd = 0
        source.getParagraphStart(
            &paragraphStart,
            end: &paragraphEnd,
            contentsEnd: &contentsEnd,
            for: NSRange(location: range.location, length: 0)
        )

        guard paragraphStart < range.location else { return page }
        let firstParagraphLength = min(NSMaxRange(range), paragraphEnd) - range.location
        guard firstParagraphLength > 0,
              let style = page.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                  as? NSParagraphStyle,
              let continuationStyle = style.mutableCopy() as? NSMutableParagraphStyle else {
            return page
        }

        continuationStyle.firstLineHeadIndent = 0
        page.addAttribute(
            .paragraphStyle,
            value: continuationStyle,
            range: NSRange(location: 0, length: firstParagraphLength)
        )
        return page
    }
}
