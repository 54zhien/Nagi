//
//  TextPaginator.swift
//  Nagi
//
//  TextKit 分页引擎：把章节正文按页面尺寸精确分成一页页。
//

import UIKit

enum TextPaginator {
    /// 把带排版属性的文本按页面尺寸分页，返回每页的 AttributedString。
    static func paginate(
        _ text: NSAttributedString,
        pageSize: CGSize,
        insets: UIEdgeInsets
    ) -> [NSAttributedString] {
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

            guard charRange.length > 0 else { break }

            pages.append(textStorage.attributedSubstring(from: charRange))
            location = NSMaxRange(charRange)
        }

        return pages
    }
}
