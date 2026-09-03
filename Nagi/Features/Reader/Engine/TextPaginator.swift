
import UIKit

enum TextPaginator {
    struct Page: @unchecked Sendable {
        let attributedText: NSAttributedString
        let characterRange: NSRange
    }

    struct PageBatch: @unchecked Sendable {
        let pages: [Page]
        let nextCharacterOffset: Int
        let isComplete: Bool
    }

    static func paginateBatch(
        _ text: NSAttributedString,
        pageSize: CGSize,
        insets: UIEdgeInsets,
        range requestedRange: NSRange,
        maximumPages: Int
    ) throws -> PageBatch {
        try Task.checkCancellation()
        guard text.length > 0, maximumPages > 0 else {
            return PageBatch(
                pages: [],
                nextCharacterOffset: requestedRange.location,
                isComplete: true
            )
        }

        let documentLength = text.length
        let start = min(max(requestedRange.location, 0), documentLength)
        let requestedEnd = min(max(NSMaxRange(requestedRange), start), documentLength)
        guard start < requestedEnd else {
            return PageBatch(
                pages: [],
                nextCharacterOffset: start,
                isComplete: start >= documentLength
            )
        }

        let sourceRange = NSRange(location: start, length: requestedEnd - start)
        let textStorage = NSTextStorage(
            attributedString: text.attributedSubstring(from: sourceRange)
        )
        let contentSize = CGSize(
            width: max(pageSize.width - insets.left - insets.right, 1),
            height: max(pageSize.height - insets.top - insets.bottom, 1)
        )

        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        var pages: [Page] = []
        pages.reserveCapacity(min(maximumPages, 8))
        var localLocation = 0

        while localLocation < textStorage.length, pages.count < maximumPages {
            try Task.checkCancellation()

            let textContainer = NSTextContainer(size: contentSize)
            textContainer.lineFragmentPadding = 0
            textContainer.maximumNumberOfLines = 0
            layoutManager.addTextContainer(textContainer)

            let glyphRange = layoutManager.glyphRange(for: textContainer)
            let charRange = layoutManager.characterRange(
                forGlyphRange: glyphRange,
                actualGlyphRange: nil
            )

            guard charRange.length > 0,
                  charRange.location >= localLocation,
                  NSMaxRange(charRange) <= textStorage.length else {
                let remaining = NSRange(
                    location: localLocation,
                    length: textStorage.length - localLocation
                )
                let globalRange = NSRange(
                    location: start + remaining.location,
                    length: remaining.length
                )
                pages.append(Page(
                    attributedText: pageText(
                        from: textStorage,
                        range: remaining,
                        isContinuation: start > 0 && pages.isEmpty
                    ),
                    characterRange: globalRange
                ))
                localLocation = textStorage.length
                break
            }

            let globalRange = NSRange(
                location: start + charRange.location,
                length: charRange.length
            )
            pages.append(Page(
                attributedText: pageText(
                    from: textStorage,
                    range: charRange,
                    isContinuation: start > 0 && pages.isEmpty
                ),
                characterRange: globalRange
            ))
            localLocation = NSMaxRange(charRange)
        }

        try Task.checkCancellation()
        let nextOffset = start + localLocation
        return PageBatch(
            pages: pages,
            nextCharacterOffset: nextOffset,
            isComplete: nextOffset >= documentLength
        )
    }

    private static func pageText(
        from textStorage: NSTextStorage,
        range: NSRange,
        isContinuation: Bool
    ) -> NSAttributedString {
        let page = NSMutableAttributedString(
            attributedString: textStorage.attributedSubstring(from: range)
        )
        guard range.length > 0 else { return page }

        if isContinuation {
            removeFirstLineIndent(from: page)
            return page
        }

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

    private static func removeFirstLineIndent(from page: NSMutableAttributedString) {
        guard let style = page.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                as? NSParagraphStyle,
              let continuationStyle = style.mutableCopy() as? NSMutableParagraphStyle else {
            return
        }

        let string = page.string as NSString
        var paragraphStart = 0
        var paragraphEnd = 0
        var contentsEnd = 0
        string.getParagraphStart(
            &paragraphStart,
            end: &paragraphEnd,
            contentsEnd: &contentsEnd,
            for: NSRange(location: 0, length: 0)
        )
        continuationStyle.firstLineHeadIndent = 0
        page.addAttribute(
            .paragraphStyle,
            value: continuationStyle,
            range: NSRange(location: 0, length: max(paragraphEnd, 1))
        )
    }
}
