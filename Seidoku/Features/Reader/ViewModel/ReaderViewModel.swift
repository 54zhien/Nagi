//
//  ReaderViewModel.swift
//  Seidoku
//
//  TXT 阅读状态：文档加载、布局重建、页面导航和稳定位置保存。
//

import Foundation
import Observation
import UIKit

struct TXTReadingAnchor: Codable, Hashable, Sendable {
    let chapterID: String
    let utf16Offset: Int
    let prefix: String
    let suffix: String
}

private enum TXTPageTarget {
    case first
    case last
    case offset(Int)
}

@MainActor
@Observable
final class TXTReaderModel {
    let book: Book

    var document: TXTDocument?
    var chapters: [TXTChapter] = []
    var currentChapterIndex = 0
    var currentPageIndex = 0

    var fontSize: Double = 17 { didSet { persistSettings(); requestRelayout() } }
    var lineSpacing: Double = 6 { didSet { persistSettings(); requestRelayout() } }
    var paragraphSpacing: Double = 10 { didSet { persistSettings(); requestRelayout() } }
    var horizontalInset: Double = 16 { didSet { persistSettings(); requestRelayout() } }
    var theme: ReaderTheme = .white { didSet { persistSettings(); requestRelayout() } }
    var transition: PageTransitionMode = .horizontal {
        didSet {
            persistSettings()
            modeDidChange(from: oldValue)
        }
    }

    var viewportSize: CGSize = .zero
    var safeAreaInsets: UIEdgeInsets = .zero
    var displayScale: CGFloat = 1

    /// 上下滚动模式独立保存的内容偏移和文本位置。
    var verticalOffset: CGFloat = 0
    private(set) var verticalTextOffset = 0

    var layout: TXTLayoutSnapshot?
    var isLoading = false
    var errorMessage: String?

    private var hasLoaded = false
    private var layoutGeneration = 0
    private var layoutTask: Task<TXTLayoutSnapshot, Never>?

    private enum PreferenceKey {
        static let fontSize = "reader.txt.fontSize"
        static let lineSpacing = "reader.txt.lineSpacing"
        static let paragraphSpacing = "reader.txt.paragraphSpacing"
        static let horizontalInset = "reader.txt.horizontalInset"
        static let theme = "reader.txt.theme"
        static let transition = "reader.txt.transition"
    }

    init(book: Book) {
        self.book = book
        currentChapterIndex = max(0, book.currentChapterIndex)

        let defaults = UserDefaults.standard
        fontSize = defaults.object(forKey: PreferenceKey.fontSize) as? Double ?? 17
        lineSpacing = defaults.object(forKey: PreferenceKey.lineSpacing) as? Double ?? 6
        paragraphSpacing = defaults.object(forKey: PreferenceKey.paragraphSpacing) as? Double ?? 10
        horizontalInset = defaults.object(forKey: PreferenceKey.horizontalInset) as? Double ?? 16
        theme = defaults.string(forKey: PreferenceKey.theme).flatMap(ReaderTheme.init) ?? .white
        transition = defaults.string(forKey: PreferenceKey.transition)
            .flatMap(PageTransitionMode.init) ?? .horizontal
    }

    var currentChapter: TXTChapter? {
        guard chapters.indices.contains(currentChapterIndex) else { return nil }
        return chapters[currentChapterIndex]
    }

    var pages: [TXTPage] {
        layout?.pages ?? []
    }

    var fullText: NSAttributedString {
        layout?.attributedText ?? NSAttributedString()
    }

    var hasContent: Bool {
        !(layout?.pages.isEmpty ?? true)
    }

    var canGoNext: Bool {
        transition != .vertical &&
            (currentPageIndex < pages.count - 1 || currentChapterIndex < chapters.count - 1)
    }

    var canGoPrevious: Bool {
        transition != .vertical && (currentPageIndex > 0 || currentChapterIndex > 0)
    }

    var readerInsets: UIEdgeInsets {
        UIEdgeInsets(
            top: max(24, safeAreaInsets.top + 56),
            left: max(8, safeAreaInsets.left + CGFloat(horizontalInset)),
            bottom: max(24, safeAreaInsets.bottom + 72),
            right: max(8, safeAreaInsets.right + CGFloat(horizontalInset))
        )
    }

    var currentTextOffset: Int {
        if transition == .vertical {
            return verticalTextOffset
        }
        guard let page = pages[safe: currentPageIndex] else { return verticalTextOffset }
        return page.range.location
    }

    var progress: Double {
        guard let document, let chapter = currentChapter else { return 0 }
        let chapterLength = document.text(for: chapter).utf16.count
        let localOffset = min(max(currentTextOffset, 0), chapterLength)
        let absoluteOffset = min(document.text.utf16.count, chapter.startUTF16 + localOffset)
        guard document.text.utf16.count > 0 else { return 0 }
        return Double(absoluteOffset) / Double(document.text.utf16.count)
    }

    func updateViewport(size: CGSize, safeAreaInsets: UIEdgeInsets, displayScale: CGFloat) {
        guard size.width > 0, size.height > 0 else { return }
        let newSize = size
        let changed = newSize != viewportSize ||
            !Self.sameInsets(self.safeAreaInsets, safeAreaInsets) ||
            abs(self.displayScale - displayScale) > 0.001

        guard changed else { return }
        viewportSize = newSize
        self.safeAreaInsets = safeAreaInsets
        self.displayScale = max(displayScale, 1)
        requestRelayout()
    }

    func loadIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let url = URL(fileURLWithPath: book.sourceURL)
            let loadedDocument = try await Task.detached(priority: .userInitiated) {
                try TXTParser().parseDocument(url: url)
            }.value

            guard !Task.isCancelled else { return }
            document = loadedDocument
            chapters = loadedDocument.chapters
            restoreSavedLocation(in: loadedDocument)
            hasLoaded = true
            await rebuildLayout(preserving: nil, target: .offset(currentTextOffset), showLoading: false)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setCurrentPage(_ index: Int) {
        guard let layout, !layout.pages.isEmpty else { return }
        let clamped = min(max(index, 0), layout.pages.count - 1)
        guard clamped != currentPageIndex else { return }
        currentPageIndex = clamped
        verticalTextOffset = layout.pages[clamped].range.location
        persistLocation()
    }

    func updateVerticalLocation(contentOffset: CGFloat, textOffset: Int) {
        verticalOffset = max(0, contentOffset)
        verticalTextOffset = max(0, textOffset)
    }

    func goNext() {
        guard !pages.isEmpty else { return }
        if currentPageIndex < pages.count - 1 {
            setCurrentPage(currentPageIndex + 1)
        } else if currentChapterIndex < chapters.count - 1 {
            selectChapter(currentChapterIndex + 1, target: .first)
        }
    }

    func goPrevious() {
        guard !pages.isEmpty else { return }
        if currentPageIndex > 0 {
            setCurrentPage(currentPageIndex - 1)
        } else if currentChapterIndex > 0 {
            selectChapter(currentChapterIndex - 1, target: .last)
        }
    }

    func selectChapter(_ index: Int) {
        selectChapter(index, target: .first)
    }

    func saveProgress() {
        persistLocation()
    }

    private func selectChapter(_ index: Int, target: TXTPageTarget) {
        guard chapters.indices.contains(index), index != currentChapterIndex else { return }

        layoutTask?.cancel()
        layoutGeneration &+= 1
        currentChapterIndex = index
        currentPageIndex = 0
        switch target {
        case .last:
            verticalTextOffset = document.map { $0.text(for: chapters[index]).utf16.count } ?? 0
        case .first, .offset(_):
            verticalTextOffset = 0
        }
        verticalOffset = 0
        layout = nil
        isLoading = true

        Task { [weak self] in
            guard let self else { return }
            await rebuildLayout(preserving: nil, target: target, showLoading: true)
        }
    }

    private func requestRelayout() {
        guard document != nil, viewportSize != .zero else { return }
        let anchor = currentReadingAnchor()
        Task { [weak self] in
            guard let self else { return }
            await rebuildLayout(preserving: anchor, target: nil, showLoading: false)
        }
    }

    private func rebuildLayout(
        preserving anchor: TXTReadingAnchor?,
        target: TXTPageTarget?,
        showLoading: Bool
    ) async {
        guard let document, let chapter = currentChapter, viewportSize != .zero else { return }
        if showLoading { isLoading = true }

        layoutGeneration &+= 1
        let generation = layoutGeneration
        layoutTask?.cancel()

        let chapterText = document.text(for: chapter)
        let style = TXTLayoutStyle(
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            paragraphSpacing: paragraphSpacing,
            horizontalInset: horizontalInset,
            themeRawValue: theme.rawValue
        )
        let viewport = viewportSize
        let insets = readerInsets
        let scale = displayScale
        let contentID = "\(book.id.uuidString)-\(chapter.id)"
        let task = Task.detached(priority: .userInitiated) {
            TXTLayoutEngine.makeSnapshot(
                text: chapterText,
                style: style,
                viewportSize: viewport,
                insets: insets,
                displayScale: scale,
                contentID: contentID
            )
        }
        layoutTask = task
        let snapshot = await task.value

        guard generation == layoutGeneration, !Task.isCancelled else { return }
        layout = snapshot

        if let target {
            currentPageIndex = pageIndex(for: target, in: snapshot)
        } else if let anchor, anchor.chapterID == chapter.id {
            let offset = min(max(anchor.utf16Offset, 0), chapterText.utf16.count)
            if transition == .vertical {
                verticalTextOffset = offset
            } else {
                currentPageIndex = snapshot.pageIndex(containing: offset)
            }
        } else {
            currentPageIndex = min(max(currentPageIndex, 0), max(0, snapshot.pages.count - 1))
        }

        if transition != .vertical, let page = snapshot.pages[safe: currentPageIndex] {
            verticalTextOffset = page.range.location
        }
        persistLocation()
        isLoading = false
    }

    private func pageIndex(for target: TXTPageTarget, in snapshot: TXTLayoutSnapshot) -> Int {
        guard !snapshot.pages.isEmpty else { return 0 }
        switch target {
        case .first: return 0
        case .last: return snapshot.pages.count - 1
        case .offset(let offset): return snapshot.pageIndex(containing: offset)
        }
    }

    private func modeDidChange(from oldMode: PageTransitionMode) {
        guard oldMode != transition else { return }
        if transition == .vertical {
            verticalTextOffset = currentPageTextOffset()
            verticalOffset = 0
        } else if oldMode == .vertical, let layout {
            currentPageIndex = layout.pageIndex(containing: verticalTextOffset)
        }
        persistLocation()
    }

    private func currentPageTextOffset() -> Int {
        pages[safe: currentPageIndex]?.range.location ?? verticalTextOffset
    }

    private func currentReadingAnchor() -> TXTReadingAnchor? {
        guard let chapter = currentChapter, let document else { return nil }
        let maxOffset = document.text(for: chapter).utf16.count
        let offset = min(max(currentTextOffset, 0), maxOffset)
        let chapterText = document.text(for: chapter) as NSString
        let contextLength = 32
        let prefixStart = max(0, offset - contextLength)
        let prefix = chapterText.substring(with: NSRange(location: prefixStart, length: offset - prefixStart))
        let suffixLength = min(contextLength, max(0, chapterText.length - offset))
        let suffix = chapterText.substring(with: NSRange(location: offset, length: suffixLength))
        return TXTReadingAnchor(
            chapterID: chapter.id,
            utf16Offset: offset,
            prefix: prefix,
            suffix: suffix
        )
    }

    private func restoreSavedLocation(in document: TXTDocument) {
        if let json = book.txtReadingLocationJSON,
           let data = json.data(using: .utf8),
           let anchor = try? JSONDecoder().decode(TXTReadingAnchor.self, from: data),
           let index = document.chapters.firstIndex(where: { $0.id == anchor.chapterID }) {
            currentChapterIndex = index
            verticalTextOffset = anchor.utf16Offset
            return
        }

        let savedProgress = min(max(book.progressPercent, 0), 1)
        let totalLength = document.text.utf16.count
        if totalLength > 0, savedProgress > 0 {
            let absoluteOffset = min(
                totalLength,
                max(0, Int((Double(totalLength) * savedProgress).rounded()))
            )
            let index = document.chapters.firstIndex {
                absoluteOffset < $0.endUTF16
            } ?? max(0, document.chapters.count - 1)
            currentChapterIndex = index
            verticalTextOffset = max(0, absoluteOffset - document.chapters[index].startUTF16)
            return
        }

        currentChapterIndex = min(max(book.currentChapterIndex, 0), max(0, document.chapters.count - 1))
    }

    private func persistLocation() {
        guard let anchor = currentReadingAnchor() else { return }
        book.currentChapterIndex = currentChapterIndex
        book.progressPercent = progress
        book.lastReadAt = .now
        if let data = try? JSONEncoder().encode(anchor) {
            book.txtReadingLocationJSON = String(data: data, encoding: .utf8)
        }
    }

    private func persistSettings() {
        let defaults = UserDefaults.standard
        defaults.set(fontSize, forKey: PreferenceKey.fontSize)
        defaults.set(lineSpacing, forKey: PreferenceKey.lineSpacing)
        defaults.set(paragraphSpacing, forKey: PreferenceKey.paragraphSpacing)
        defaults.set(horizontalInset, forKey: PreferenceKey.horizontalInset)
        defaults.set(theme.rawValue, forKey: PreferenceKey.theme)
        defaults.set(transition.rawValue, forKey: PreferenceKey.transition)
    }

    private static func sameInsets(_ lhs: UIEdgeInsets, _ rhs: UIEdgeInsets) -> Bool {
        lhs.top == rhs.top && lhs.left == rhs.left && lhs.bottom == rhs.bottom && lhs.right == rhs.right
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
