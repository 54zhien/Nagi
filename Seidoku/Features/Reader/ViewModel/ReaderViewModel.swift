//
//  ReaderViewModel.swift
//  Seidoku
//
//  阅读器视图模型：加载章节、TextKit 分页、翻页、排版设置。
//

import SwiftUI
import Observation

@MainActor
@Observable
final class ReaderViewModel {
    let book: Book
    private let epubParser = EPUBParser()

    // 章节
    var chapters: [BookChapter] = []
    var currentChapterIndex = 0

    // 当前章节分页
    var pages: [NSAttributedString] = []
    var currentPageIndex = 0
    /// 整章文本（上下滚动模式用）
    var fullText: NSAttributedString = NSAttributedString()

    // 排版设置（didSet 触发重新分页）
    var fontSize: Double = 17 { didSet { scheduleRepaginate() } }
    var lineSpacing: Double = 6 { didSet { scheduleRepaginate() } }
    var paragraphSpacing: Double = 10 { didSet { scheduleRepaginate() } }
    var horizontalInset: Double = 16 { didSet { scheduleRepaginate() } }
    var theme: ReaderTheme = .white { didSet { scheduleRepaginate() } }
    var transition: PageTransitionMode = .pageCurl

    // 页面尺寸（由 View 通过 GeometryReader 注入）
    var pageSize: CGSize = .zero { didSet { if pageSize != oldValue { scheduleRepaginate() } } }

    var isLoading = false
    var errorMessage: String?

    private var currentContent = ""

    init(book: Book) {
        self.book = book
        self.currentChapterIndex = book.currentChapterIndex
    }

    // MARK: - 加载

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            chapters = try epubParser.loadChapters(url: bookURL)
            if currentChapterIndex >= chapters.count {
                currentChapterIndex = 0
            }
            await loadCurrentChapter()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadCurrentChapter() async {
        await loadReadableChapter(searchDirection: 1, showLastPage: false)
    }

    /// 读取目标章节；纯图片封面、空白页等没有文字的 spine 项会自动跳过。
    private func loadReadableChapter(searchDirection: Int, showLastPage: Bool) async {
        guard !chapters.isEmpty else { return }
        var candidate = currentChapterIndex

        do {
            while chapters.indices.contains(candidate) {
                let chapter = chapters[candidate]
                let content = try epubParser.loadChapterContent(url: bookURL, href: chapter.href)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty {
                    currentChapterIndex = candidate
                    currentContent = content
                    errorMessage = nil
                    repaginate()
                    currentPageIndex = showLastPage ? max(0, pages.count - 1) : 0
                    return
                }
                candidate += searchDirection
            }

            currentContent = ""
            pages = []
            fullText = NSAttributedString()
            errorMessage = "此 EPUB 没有找到可阅读的文字内容"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 分页

    private func scheduleRepaginate() {
        guard !currentContent.isEmpty, pageSize != .zero else { return }
        repaginate()
    }

    private func repaginate() {
        let attributed = Self.attributedText(from: currentContent, settings: self)
        fullText = attributed
        let insets = UIEdgeInsets(top: 20, left: horizontalInset, bottom: 20, right: horizontalInset)
        pages = TextPaginator.paginate(attributed, pageSize: pageSize, insets: insets)
        if currentPageIndex >= pages.count {
            currentPageIndex = max(0, pages.count - 1)
        }
    }

    static func attributedText(from text: String, settings: ReaderViewModel) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = settings.lineSpacing
        paragraphStyle.paragraphSpacing = settings.paragraphSpacing
        paragraphStyle.lineBreakMode = .byWordWrapping

        let font = UIFont.systemFont(ofSize: settings.fontSize)

        return NSAttributedString(string: text, attributes: [
            .font: font,
            .paragraphStyle: paragraphStyle,
            .foregroundColor: settings.theme.foregroundUIColor,
        ])
    }

    // MARK: - 翻页

    var canGoNext: Bool {
        currentPageIndex < pages.count - 1 || currentChapterIndex < chapters.count - 1
    }

    var canGoPrevious: Bool {
        currentPageIndex > 0 || currentChapterIndex > 0
    }

    /// 下一页；到章节末自动跳下一章。
    func goNext() {
        if currentPageIndex < pages.count - 1 {
            currentPageIndex += 1
        } else if currentChapterIndex < chapters.count - 1 {
            currentChapterIndex += 1
            Task { await loadReadableChapter(searchDirection: 1, showLastPage: false) }
        }
    }

    /// 上一页；到章节头自动跳上一章（跳到末尾）。
    func goPrevious() {
        if currentPageIndex > 0 {
            currentPageIndex -= 1
        } else if currentChapterIndex > 0 {
            currentChapterIndex -= 1
            Task { await loadReadableChapter(searchDirection: -1, showLastPage: true) }
        }
    }

    // MARK: - 进度（后续接 SwiftData 保存）

    var currentChapter: BookChapter? {
        guard currentChapterIndex < chapters.count else { return nil }
        return chapters[currentChapterIndex]
    }

    private var bookURL: URL {
        URL(fileURLWithPath: book.sourceURL)
    }
}
