//
//  TextPaginator.swift
//  Seidoku
//
//  TXT 布局引擎：先生成整章布局，再按真实行范围切成页面。
//

import UIKit

struct TXTLayoutStyle: Hashable, Sendable {
    var fontSize: Double = 17
    var lineSpacing: Double = 6
    var paragraphSpacing: Double = 10
    var horizontalInset: Double = 16
    var themeRawValue: String = ReaderTheme.white.rawValue

    var theme: ReaderTheme {
        ReaderTheme(rawValue: themeRawValue) ?? .white
    }
}

/// 任何会改变换行结果的条件都必须进入 key。
struct TXTLayoutKey: Hashable, Sendable {
    let contentID: String
    let viewportWidth: Int
    let viewportHeight: Int
    let topInset: Int
    let leftInset: Int
    let bottomInset: Int
    let rightInset: Int
    let displayScale: Int
    let style: TXTLayoutStyle

    var identifier: String {
        let geometry = [
            viewportWidth, viewportHeight,
            topInset, leftInset, bottomInset, rightInset,
            displayScale,
        ].map(String.init).joined(separator: ":")
        return contentID + ":" + geometry + ":" + style.themeRawValue +
            ":\(style.fontSize):\(style.lineSpacing):\(style.paragraphSpacing):\(style.horizontalInset)"
    }

    static func make(
        viewportSize: CGSize,
        insets: UIEdgeInsets,
        displayScale: CGFloat,
        style: TXTLayoutStyle,
        contentID: String
    ) -> TXTLayoutKey {
        func pixelValue(_ value: CGFloat) -> Int {
            Int((value * max(displayScale, 1)).rounded())
        }

        return TXTLayoutKey(
            contentID: contentID,
            viewportWidth: pixelValue(viewportSize.width),
            viewportHeight: pixelValue(viewportSize.height),
            topInset: pixelValue(insets.top),
            leftInset: pixelValue(insets.left),
            bottomInset: pixelValue(insets.bottom),
            rightInset: pixelValue(insets.right),
            displayScale: pixelValue(displayScale),
            style: style
        )
    }
}

struct TXTPage: Identifiable, Hashable, Sendable {
    let index: Int
    let range: NSRange

    var id: String {
        "page-\(index)-\(range.location)-\(range.length)"
    }
}

struct TXTLayoutSnapshot: @unchecked Sendable {
    let key: TXTLayoutKey
    let attributedText: NSAttributedString
    let pages: [TXTPage]
    let viewportSize: CGSize
    let contentSize: CGSize
    let insets: UIEdgeInsets

    func attributedText(for page: TXTPage) -> NSAttributedString {
        attributedText.attributedSubstring(from: page.range)
    }

    func pageIndex(containing offset: Int) -> Int {
        guard !pages.isEmpty else { return 0 }
        let clamped = max(0, min(offset, attributedText.length))
        if let index = pages.firstIndex(where: {
            clamped >= $0.range.location && clamped < NSMaxRange($0.range)
        }) {
            return index
        }
        return clamped >= NSMaxRange(pages[pages.count - 1].range) ? pages.count - 1 : 0
    }
}

enum TXTLayoutEngine {
    private struct Line {
        let range: NSRange
        let frame: CGRect
    }

    static func makeSnapshot(
        text: String,
        style: TXTLayoutStyle,
        viewportSize: CGSize,
        insets: UIEdgeInsets,
        displayScale: CGFloat,
        contentID: String
    ) -> TXTLayoutSnapshot {
        let safeViewport = CGSize(
            width: max(viewportSize.width, 1),
            height: max(viewportSize.height, 1)
        )
        let contentSize = CGSize(
            width: max(safeViewport.width - insets.left - insets.right, 1),
            height: max(safeViewport.height - insets.top - insets.bottom, 1)
        )
        let attributedText = makeAttributedText(text, style: style)
        let ranges = paginate(attributedText, contentSize: contentSize)
        let pages = ranges.enumerated().map { index, range in
            TXTPage(index: index, range: range)
        }

        return TXTLayoutSnapshot(
            key: TXTLayoutKey.make(
                viewportSize: safeViewport,
                insets: insets,
                displayScale: displayScale,
                style: style,
                contentID: contentID
            ),
            attributedText: attributedText,
            pages: pages,
            viewportSize: safeViewport,
            contentSize: contentSize,
            insets: insets
        )
    }

    private static func makeAttributedText(_ text: String, style: TXTLayoutStyle) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = style.lineSpacing
        paragraphStyle.paragraphSpacing = style.paragraphSpacing
        paragraphStyle.lineBreakMode = .byCharWrapping
        paragraphStyle.alignment = .natural

        return NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: max(style.fontSize, 8)),
                .paragraphStyle: paragraphStyle,
                .foregroundColor: style.theme.foregroundUIColor,
            ]
        )
    }

    private static func paginate(_ text: NSAttributedString, contentSize: CGSize) -> [NSRange] {
        guard text.length > 0 else { return [] }

        if #available(iOS 15.0, *) {
            let ranges = paginateWithTextKit2(text, contentSize: contentSize)
            if !ranges.isEmpty {
                return ranges
            }
        }

        return paginateWithTextKit1(text, contentSize: contentSize)
    }

    @available(iOS 15.0, *)
    private static func paginateWithTextKit2(
        _ text: NSAttributedString,
        contentSize: CGSize
    ) -> [NSRange] {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        let textContainer = NSTextContainer(
            size: CGSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.lineFragmentPadding = 0

        contentStorage.textStorage = NSTextStorage(attributedString: text)
        contentStorage.addTextLayoutManager(layoutManager)
        layoutManager.textContainer = textContainer

        let documentRange = contentStorage.documentRange
        layoutManager.ensureLayout(for: documentRange)

        var lines: [Line] = []
        layoutManager.enumerateTextLayoutFragments(
            from: documentRange.location,
            options: []
        ) { fragment in
            for lineFragment in fragment.textLineFragments {
                let range = lineFragment.characterRange
                guard range.length > 0 else { continue }

                let frame = lineFragment.typographicBounds.offsetBy(
                    dx: fragment.layoutFragmentFrame.minX,
                    dy: fragment.layoutFragmentFrame.minY
                )
                lines.append(Line(range: range, frame: frame))
            }
            return true
        }

        return makeContiguousPages(
            lines: lines,
            textLength: text.length,
            pageHeight: contentSize.height
        )
    }

    private static func paginateWithTextKit1(
        _ text: NSAttributedString,
        contentSize: CGSize
    ) -> [NSRange] {
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)

        var ranges: [NSRange] = []
        var location = 0

        while location < storage.length {
            let container = NSTextContainer(size: contentSize)
            container.lineFragmentPadding = 0
            container.lineBreakMode = .byCharWrapping
            layoutManager.addTextContainer(container)
            layoutManager.ensureLayout(for: container)

            let glyphRange = layoutManager.glyphRange(for: container)
            guard glyphRange.location != NSNotFound, glyphRange.length > 0 else { break }

            let characterRange = layoutManager.characterRange(
                forGlyphRange: glyphRange,
                actualGlyphRange: nil
            )
            guard characterRange.length > 0 else { break }

            let start = max(location, characterRange.location)
            let end = max(start, NSMaxRange(characterRange))
            guard end > start else { break }
            ranges.append(NSRange(location: start, length: end - start))
            location = end
        }

        if location < text.length {
            ranges.append(NSRange(location: location, length: text.length - location))
        }
        return normalizeRanges(ranges, textLength: text.length)
    }

    private static func makeContiguousPages(
        lines: [Line],
        textLength: Int,
        pageHeight: CGFloat
    ) -> [NSRange] {
        guard textLength > 0, let first = lines.first else {
            return textLength > 0 ? [NSRange(location: 0, length: textLength)] : []
        }

        var ranges: [NSRange] = []
        var pageStart = 0
        var pageEnd = 0
        var pageTop = first.frame.minY

        for line in lines {
            let lineEnd = min(textLength, NSMaxRange(line.range))
            guard lineEnd > 0 else { continue }

            let fits = line.frame.maxY - pageTop <= pageHeight + 0.5
            if fits || pageEnd == pageStart {
                pageEnd = max(pageEnd, lineEnd)
            } else {
                if pageEnd > pageStart {
                    ranges.append(NSRange(location: pageStart, length: pageEnd - pageStart))
                }
                pageStart = pageEnd
                pageEnd = max(pageStart, lineEnd)
                pageTop = line.frame.minY
            }
        }

        if pageEnd > pageStart {
            ranges.append(NSRange(location: pageStart, length: pageEnd - pageStart))
        }
        if pageStart < textLength {
            let lastEnd = ranges.last.map(NSMaxRange) ?? pageStart
            if lastEnd < textLength {
                ranges.append(NSRange(location: lastEnd, length: textLength - lastEnd))
            }
        }

        return normalizeRanges(ranges, textLength: textLength)
    }

    private static func normalizeRanges(_ ranges: [NSRange], textLength: Int) -> [NSRange] {
        var normalized: [NSRange] = []
        var cursor = 0

        for range in ranges {
            let start = max(cursor, min(textLength, range.location))
            let end = min(textLength, NSMaxRange(range))

            guard end > start else { continue }

            if normalized.isEmpty {
                normalized.append(NSRange(location: 0, length: end))
            } else {
                // TextKit 可能把段落换行符放在相邻行范围之外。
                // 空隙归入前一页，避免下一页从换行符/空白行开始。
                if start > cursor {
                    let lastIndex = normalized.count - 1
                    let last = normalized[lastIndex]
                    normalized[lastIndex] = NSRange(
                        location: last.location,
                        length: start - last.location
                    )
                }
                normalized.append(NSRange(location: start, length: end - start))
            }
            cursor = end
        }

        if cursor < textLength {
            normalized.append(NSRange(location: cursor, length: textLength - cursor))
        }
        return normalized
    }
}
